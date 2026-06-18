`timescale 1ns / 1ps

// =============================================================================
// SUB-MODULE 1: UNPACKER CORE (FIXED REMNANT PURGE)
// =============================================================================
module unpacker (
    input wire clk,
    input wire reset,
    input wire [15:0] data_in,
    input wire data_in_valid,
    input wire in_last, 
    input wire decompressor_stall,     
    output reg [16:0] data_out,       
    output reg [2:0] data_out_len,
    output reg data_out_valid,
    output wire ready_for_input
);
    reg [63:0] buffer;
    reg [6:0] len;
    reg processing;
    reg last_word_latched;

    wire is_rle   = (buffer[63:62] == 2'b01);
    wire is_delta = (buffer[63]    == 1'b1);
    wire is_raw   = (buffer[63:62] == 2'b00);

    // Calculate token size dynamically based on prefix
    wire [6:0] token_size = is_delta ? 7'd10 :
                            is_rle   ? 7'd5  :
                            is_raw   ? 7'd17 : 7'd0;

    assign ready_for_input = (len <= 48) && !last_word_latched;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            buffer            <= 64'b0;
            len               <= 7'b0;
            data_out          <= 17'b0;
            data_out_len      <= 3'b0;
            data_out_valid    <= 1'b0;
            processing        <= 1'b0;
            last_word_latched <= 1'b0;
        end else begin
            if (!decompressor_stall) begin
                data_out_valid <= 1'b0;
            end

            // 1. Ingest into barrel shifter
            if (data_in_valid && ready_for_input) begin
                buffer            <= buffer | ({{48{1'b0}}, data_in} << (64 - len - 16));
                len               <= len + 16;
                processing        <= 1'b1;
                if (in_last) begin
                    last_word_latched <= 1'b1;
                end
            end

            // 2. Extract tokens safely while guarding length boundary
            if (processing && !decompressor_stall && (len >= token_size) && (token_size > 0) && (len > 0)) begin
                data_out_valid <= 1'b1;
                if (is_delta) begin
                    data_out     <= {8'b0, buffer[62:54]};
                    data_out_len <= 3'd4;
                    buffer       <= buffer << 10;
                    len          <= len - 10;
                end else if (is_rle) begin
                    data_out     <= {14'b0, buffer[61:59]};
                    data_out_len <= 3'd3;
                    buffer       <= buffer << 5;
                    len          <= len - 5;
                end else begin 
                    data_out     <= {2'b00, buffer[61:47]};
                    data_out_len <= 3'd5;
                    buffer       <= buffer << 17;
                    len          <= len - 17;
                end
            end 
            
            // 3. Clear engine completely if buffer drops below minimum usable bits
            if (last_word_latched && (len < token_size || len < 5)) begin
                processing        <= 1'b0;
                len               <= 7'b0;
                buffer            <= 64'b0;
                data_out_valid    <= 1'b0;
                last_word_latched <= 1'b0;
            end
        end
    end
endmodule

// =============================================================================
// SUB-MODULE 2: DECOMPRESSOR TOP CORE
// =============================================================================
module decompressor_top (
    input wire clk,
    input wire reset,
    input wire [16:0] code_in,        
    input wire [4:0] code_size,       
    input wire code_valid,            
    output reg [15:0] decoded_out,    
    output reg out_valid,             
    output reg expansion_done,
    output wire stall_unpacker         
);
    localparam ZERO_CODE_SIZE    = 5'd3;
    localparam COMPRESSED_SIZE   = 5'd9;
    localparam UNCOMPRESSED_SIZE = 5'd15;
    localparam BIAS              = 8'd127;

    reg [2:0] zero_counter;
    reg expanding_zeros;
    reg [16:0] pending_code;          
    reg [4:0] pending_code_size;      
    reg pending_valid;                
    
    wire signed [1:0] delta_ext    = $signed(code_in[8:7]);
    wire [7:0] exponent_comb       = $signed(BIAS) + delta_ext;
    wire [15:0] delta_decoded     = (code_size == COMPRESSED_SIZE) ? 
                                    {1'b0, exponent_comb, code_in[6:0]} : 
                                    {1'b0, code_in[14:0]}; 

    assign stall_unpacker = expanding_zeros || pending_valid;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            decoded_out       <= 16'h0000;
            out_valid         <= 1'b0;
            expansion_done    <= 1'b0;
            zero_counter      <= 3'd0;
            expanding_zeros   <= 1'b0;
            pending_code      <= 17'b0;
            pending_code_size <= 5'b0;
            pending_valid     <= 1'b0;
        end else begin
            out_valid      <= 1'b0;
            expansion_done <= 1'b0;

            if (expanding_zeros) begin
                if (zero_counter > 0) begin
                    zero_counter <= zero_counter - 1;
                    decoded_out  <= 16'h0000;
                    out_valid    <= 1'b1;
                end else begin
                    expanding_zeros <= 1'b0;
                    expansion_done  <= 1'b1;
                    
                    if (pending_valid) begin
                        pending_valid <= 1'b0;
                        case (pending_code_size)
                            COMPRESSED_SIZE: begin
                                decoded_out <= {1'b0, $signed(BIAS) + $signed(pending_code[8:7]), pending_code[6:0]};
                                out_valid   <= 1'b1;
                            end
                            UNCOMPRESSED_SIZE: begin
                                decoded_out <= {1'b0, pending_code[14:0]};
                                out_valid   <= 1'b1;
                            end
                            ZERO_CODE_SIZE: begin
                                zero_counter    <= pending_code[2:0] - 1;
                                expanding_zeros <= 1'b1;
                                decoded_out     <= 16'h0000;
                                out_valid       <= 1'b1;
                            end
                        endcase
                    end
                end
            end
            else if (code_valid && !pending_valid) begin
                case (code_size)
                    ZERO_CODE_SIZE: begin
                        zero_counter    <= code_in[2:0] - 1;  
                        expanding_zeros <= 1'b1;
                        decoded_out     <= 16'h0000;
                        out_valid       <= 1'b1;
                    end
                    COMPRESSED_SIZE, UNCOMPRESSED_SIZE: begin
                        decoded_out   <= delta_decoded;
                        out_valid     <= 1'b1;
                    end
                    default: out_valid <= 1'b0;
                endcase
            end 

            if (code_valid && (expanding_zeros || pending_valid) && !pending_valid) begin
                pending_code      <= code_in;
                pending_code_size <= code_size;
                pending_valid     <= 1'b1;
            end 

            if (!expanding_zeros && pending_valid) begin
                pending_valid <= 1'b0;
                case (pending_code_size)
                    ZERO_CODE_SIZE: begin
                        zero_counter    <= pending_code[2:0] - 1;
                        expanding_zeros <= 1'b1;
                        decoded_out     <= 16'h0000;
                        out_valid       <= 1'b1;
                    end
                    COMPRESSED_SIZE: begin
                        decoded_out   <= {1'b0, $signed(BIAS) + $signed(pending_code[8:7]), pending_code[6:0]};
                        out_valid     <= 1'b1;
                    end
                    UNCOMPRESSED_SIZE: begin
                        decoded_out   <= {1'b0, pending_code[14:0]};
                        out_valid     <= 1'b1;
                    end
                endcase
            end
        end
    end
endmodule

// =============================================================================
// MAIN TOP SYSTEM WRAPPER
// =============================================================================
module combined_unpacker_decompressor (
    input wire clk,
    input wire reset,
    input wire [15:0] data_in,
    input wire data_in_valid,
    input wire in_last, 
    output wire [15:0] decoded_out,    
    output wire out_valid,             
    output wire expansion_done,        
    output wire ready_for_input
);
    wire [16:0] unpacker_data_out;       
    wire [2:0]  unpacker_data_out_len;
    wire        unpacker_data_out_valid;
    wire        unpacker_ready_for_input;
    wire [4:0]  mapped_code_size;
    wire        decompressor_stall_sig;

    unpacker u_unpacker (
        .clk(clk),
        .reset(reset),
        .data_in(data_in),
        .data_in_valid(data_in_valid),
        .in_last(in_last),
        .decompressor_stall(decompressor_stall_sig),
        .data_out(unpacker_data_out),
        .data_out_len(unpacker_data_out_len),
        .data_out_valid(unpacker_data_out_valid),
        .ready_for_input(unpacker_ready_for_input)
    );

    assign mapped_code_size = (unpacker_data_out_len == 3'd3) ? 5'd3  : 
                              (unpacker_data_out_len == 3'd4) ? 5'd9  : 
                              (unpacker_data_out_len == 3'd5) ? 5'd15 : 5'd0;

    decompressor_top u_decompressor (
        .clk(clk),
        .reset(reset),
        .code_in(unpacker_data_out),
        .code_size(mapped_code_size), 
        .code_valid(unpacker_data_out_valid),
        .decoded_out(decoded_out),
        .out_valid(out_valid),
        .expansion_done(expansion_done),
        .stall_unpacker(decompressor_stall_sig)
    );

    assign ready_for_input = unpacker_ready_for_input;
endmodule