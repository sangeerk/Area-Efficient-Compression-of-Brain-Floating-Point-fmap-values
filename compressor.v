`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: compressor
// Description: Fully synchronized compression core with fixed trailing-edge 
//              flush logic and error-free zero-padded packer allocation.
//////////////////////////////////////////////////////////////////////////////////

module compressor (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire        in_last,
    input  wire [15:0] in_data,
    output wire        out_valid,
    output wire [15:0] out_data0,
    output wire [15:0] out_data1
);

    // Zero RLE signals
    wire [4:0]  zrle_code;
    wire        zrle_valid;
    wire        is_zero;
    reg         zrle_last;

    // Delta encoder signals
    wire [16:0] delta_code;
    wire [4:0]  delta_size;
    wire        delta_valid;
    wire        delta_last;
    wire        delta_is_compressed;

    // Packer signals
    reg         packer_in_valid;
    reg  [4:0]  packer_in_len;
    reg  [31:0] packer_in_bits;
    reg         packer_in_last;

    // Data delay registers
    reg [15:0] delayed_data;
    reg        delayed_valid;
    reg        delayed_last;

    // -------------------------------------------------------------------------
    // Zero RLE encoder
    // -------------------------------------------------------------------------
    zero_rle_encoder zrle_inst (
        .clk      (clk),
        .rst      (~rst_n),
        .in_data  (in_data),
        .in_valid (in_valid),
        .in_last  (in_last),
        .out_code (zrle_code),
        .out_valid(zrle_valid),
        .is_zero  (is_zero)
    );

    // Register zrle_last to stay in phase with zrle_valid
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            zrle_last <= 1'b0;
        else if (in_valid)
            zrle_last <= in_last && is_zero;
        else if (zrle_valid) // Clear after consumption
            zrle_last <= 1'b0;
    end

    // -------------------------------------------------------------------------
    // Data delay pipeline
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            delayed_data  <= 16'd0;
            delayed_valid <= 1'b0;
            delayed_last  <= 1'b0;
        end else begin
            delayed_data  <= in_data;
            delayed_valid <= in_valid && !is_zero; 
            delayed_last  <= in_last;
        end
    end

    // -------------------------------------------------------------------------
    // BFP splitter
    // -------------------------------------------------------------------------
    wire [7:0] exponent;
    wire [6:0] fraction;
    wire       splitter_out_valid;
    wire       splitter_out_last;

    bfp_splitter splitter_inst (
        .clk      (clk),
        .reset_n  (rst_n),
        .in_valid (delayed_valid),
        .in_last  (delayed_last),
        .in_data  (delayed_data),
        .out_valid(splitter_out_valid),
        .out_last (splitter_out_last),
        .exponent (exponent),
        .fraction (fraction)
    );

    // -------------------------------------------------------------------------
    // Delta encoder
    // -------------------------------------------------------------------------
    delta_encoder delta_inst (
        .clk          (clk),
        .reset_n      (rst_n),
        .in_valid     (splitter_out_valid),
        .in_last      (splitter_out_last),
        .exponent     (exponent),
        .fraction     (fraction),
        .out_valid    (delta_valid),
        .out_last     (delta_last),
        .out_code     (delta_code),
        .out_size     (delta_size),
        .is_compressed(delta_is_compressed)
    );

    // -------------------------------------------------------------------------
    // One-entry delta FIFO Buffer
    // -------------------------------------------------------------------------
    reg        delta_buf_valid;
    reg [16:0] delta_buf_code;
    reg [4:0]  delta_buf_size;
    reg        delta_buf_last;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            delta_buf_valid <= 1'b0;
            delta_buf_code  <= 17'd0;
            delta_buf_size  <= 5'd0;
            delta_buf_last  <= 1'b0;
        end else begin
            if (delta_buf_valid && !zrle_valid)
                delta_buf_valid <= 1'b0;

            if (delta_valid && zrle_valid) begin
                delta_buf_valid <= 1'b1;
                delta_buf_code  <= delta_code;
                delta_buf_size  <= delta_size;
                delta_buf_last  <= delta_last;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Packer control logic 
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            packer_in_valid <= 1'b0;
            packer_in_len   <= 5'd0;
            packer_in_bits  <= 32'd0;
            packer_in_last  <= 1'b0;
        end else begin
            packer_in_valid <= 1'b0;
            packer_in_last  <= 1'b0;

            if (zrle_valid) begin
                packer_in_valid <= 1'b1;
                packer_in_len   <= 5'd5;
                packer_in_bits  <= {27'b0, zrle_code};
                packer_in_last  <= zrle_last && !delta_valid && !delta_buf_valid;
            end else if (delta_buf_valid) begin
                packer_in_valid <= 1'b1;
                packer_in_len   <= delta_buf_size;
                packer_in_bits  <= {15'b0, delta_buf_code};
                packer_in_last  <= delta_buf_last;
            end else if (delta_valid) begin
                packer_in_valid <= 1'b1;
                packer_in_len   <= delta_size;
                packer_in_bits  <= {15'b0, delta_code};
                packer_in_last  <= delta_last;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Packer
    // -------------------------------------------------------------------------
    simple_packer packer_inst (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (packer_in_valid),
        .in_len   (packer_in_len),
        .in_bits  (packer_in_bits),
        .in_last  (packer_in_last),
        .out_valid(out_valid),
        .out_data0(out_data0),
        .out_data1(out_data1)
    );

endmodule


// =============================================================================
// zero_rle_encoder
// =============================================================================
module zero_rle_encoder (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] in_data,
    input  wire        in_valid,
    input  wire        in_last,
    output reg  [4:0]  out_code,
    output reg         out_valid,
    output wire        is_zero
);
    reg [2:0] zero_count;
    reg        emit_pending;
    reg [4:0] emit_code;
    reg        prev_is_zero;

    assign is_zero = (in_data == 16'h0000);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            zero_count   <= 3'd0;
            out_code     <= 5'd0;
            out_valid    <= 1'b0;
            prev_is_zero <= 1'b0;
            emit_pending <= 1'b0;
            emit_code    <= 5'd0;
        end else begin
            out_valid <= 1'b0;

            if (emit_pending) begin
                out_code     <= emit_code;
                out_valid    <= 1'b1;
                emit_pending <= 1'b0;
            end

            if (in_valid) begin
                prev_is_zero <= is_zero;

                if (is_zero) begin
                    if (zero_count < 3'd7) begin
                        zero_count <= zero_count + 1;
                    end else begin
                        emit_code    <= {2'b01, 3'd7};
                        emit_pending <= 1'b1;
                        zero_count   <= 3'd1;
                    end

                    if (in_last) begin
                        if (zero_count < 3'd7) begin
                            emit_code    <= {2'b01, zero_count + 1'b1};
                            emit_pending <= 1'b1;
                            zero_count   <= 3'd0;
                        end else begin
                            emit_code    <= {2'b01, 3'd1};
                            emit_pending <= 1'b1;
                            zero_count   <= 3'd0;
                        end
                    end

                end else begin
                    if (prev_is_zero && zero_count > 0) begin
                        emit_code    <= {2'b01, zero_count};
                        emit_pending <= 1'b1;
                    end
                    zero_count <= 3'd0;
                end
            end
        end
    end
endmodule


// =============================================================================
// bfp_splitter
// =============================================================================
module bfp_splitter (
    input clk,
    input reset_n,
    input in_valid,
    input in_last,
    input [15:0] in_data,
    output reg out_valid,
    output reg out_last,
    output reg [7:0] exponent,
    output reg [6:0] fraction
);
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            exponent  <= 8'd0;
            fraction  <= 7'd0;
            out_valid <= 1'b0;
            out_last  <= 1'b0;
        end else begin
            out_valid <= 1'b0;
            out_last  <= 1'b0;
            if (in_valid) begin
                exponent  <= in_data[14:7];
                fraction  <= in_data[6:0];
                out_valid <= 1'b1;
                out_last  <= in_last;
            end
        end
    end
endmodule


// =============================================================================
// delta_encoder
// =============================================================================
module delta_encoder (
    input clk,
    input reset_n,
    input in_valid,
    input in_last,
    input [7:0] exponent,
    input [6:0] fraction,
    output reg out_valid,
    output reg out_last,
    output reg [16:0] out_code,
    output reg [4:0]  out_size,
    output reg        is_compressed
);
    localparam BIAS = 8'd127;
    reg signed [8:0] delta_full;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            out_valid     <= 1'b0;
            out_last      <= 1'b0;
            out_code      <= 17'd0;
            out_size      <= 5'd0;
            is_compressed <= 1'b0;
        end else begin
            out_valid <= 1'b0;
            out_last  <= 1'b0;
            if (in_valid) begin
                delta_full = $signed({1'b0, exponent}) - BIAS;
                if ((delta_full >= -2) && (delta_full <= 1)) begin
                    out_code      <= {1'b1, delta_full[1:0], fraction};
                    out_size      <= 5'd10;
                    is_compressed <= 1'b1;
                end else begin
                    out_code      <= {2'b00, exponent, fraction};
                    out_size      <= 5'd17;
                    is_compressed <= 1'b0;
                end
                out_valid <= 1'b1;
                out_last  <= in_last;
            end
        end
    end
endmodule


// =============================================================================
// simple_packer - SYNTAX REVISED LOGICAL SHIFT PACKING
// =============================================================================
module simple_packer (
    input          clk,
    input          rst_n,
    input          in_valid,
    input  [4:0]   in_len,
    input  [31:0] in_bits,
    input          in_last,
    output reg     out_valid,
    output reg [15:0] out_data0,
    output reg [15:0] out_data1
);
    reg [63:0] buffer;
    reg [5:0]  bit_count;
    reg        need_flush;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buffer     <= 64'd0;
            bit_count  <= 6'd0;
            out_valid  <= 1'b0;
            out_data0  <= 16'hxxxx;
            out_data1  <= 16'hxxxx;
            need_flush <= 1'b0;
        end else begin
            out_valid <= 1'b0;
            out_data0 <= 16'hxxxx;
            out_data1 <= 16'hxxxx;

            // 1. Accrue incoming bits into the shift accumulator
            if (in_valid) begin
                buffer    <= (buffer << in_len) | (in_bits & ((1 << in_len) - 1));
                bit_count <= bit_count + in_len;
                if (in_last)
                    need_flush <= 1'b1;
            end

            // 2. Extract regular non-trailing aligned chunks
            if (bit_count >= 32) begin
                out_data0 <= buffer[bit_count-1    -: 16];
                out_data1 <= buffer[bit_count-17   -: 16];
                out_valid <= 1'b1;
                bit_count <= bit_count - 32;
            end else if (bit_count >= 16) begin
                out_data0 <= buffer[bit_count-1    -: 16];
                out_valid <= 1'b1;
                bit_count <= bit_count - 16;
            end

            // 3. Tail-Flush Block: Synthesizable double-shifting for clean padding
            if ((need_flush || (in_valid && in_last)) && !in_valid) begin
                if (bit_count > 16) begin
                    out_data0  <= buffer[bit_count-1 -: 16];
                    // Clears out upper elements, left-aligns remaining content, and zero-pads right side
                    out_data1  <= (buffer << (64 - (bit_count - 16))) >> 48;
                    out_valid  <= 1'b1;
                    bit_count  <= 6'd0;
                end else if (bit_count > 0) begin
                    // Clears out older data chunks, matches remaining bits to top of out_data0, pads bottom with 0s
                    out_data0  <= (buffer << (64 - bit_count)) >> 48;
                    out_data1  <= 16'h0000;
                    out_valid  <= 1'b1;
                    bit_count  <= 6'd0;
                end
                need_flush <= 1'b0;
            end
        end
    end
endmodule