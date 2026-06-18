`timescale 1ns / 1ps

module axi_compressor_wrapper (
    // AXI Stream Slave Interface (Input)
    input  wire        s_axis_aclk,
    input  wire        s_axis_aresetn,
    input  wire        s_axis_tvalid,
    input  wire        s_axis_tlast,
    input  wire [15:0] s_axis_tdata,
    output wire        s_axis_tready,

    // AXI Stream Master Interface (Output)
    input  wire        m_axis_aclk,
    input  wire        m_axis_aresetn,
    output reg         m_axis_tvalid,
    output reg         m_axis_tlast,
    output reg  [15:0] m_axis_tdata,
    input  wire        m_axis_tready
);

    // =========================================================================
    // Compressor interface
    // =========================================================================
    wire        comp_out_valid;
    wire [15:0] comp_out_data0;
    wire [15:0] comp_out_data1;

    // =========================================================================
    // Input pipeline
    // =========================================================================
    reg        s_axis_tvalid_reg;
    reg        s_axis_tlast_reg;
    reg [15:0] s_axis_tdata_reg;

    always @(posedge s_axis_aclk or negedge s_axis_aresetn) begin
        if (!s_axis_aresetn) begin
            s_axis_tvalid_reg <= 1'b0;
            s_axis_tlast_reg  <= 1'b0;
            s_axis_tdata_reg  <= 16'd0;
        end else begin
            s_axis_tvalid_reg <= s_axis_tvalid;
            s_axis_tlast_reg  <= s_axis_tlast;
            s_axis_tdata_reg  <= s_axis_tdata;
        end
    end

    // Input backpressure always ready in this structural layout
    assign s_axis_tready = 1'b1;

    // =========================================================================
    // tlast pipeline
    // =========================================================================
    localparam PIPE_DEPTH = 5;
    reg [PIPE_DEPTH-1:0] last_pipe;

    always @(posedge s_axis_aclk or negedge s_axis_aresetn) begin
        if (!s_axis_aresetn)
            last_pipe <= {PIPE_DEPTH{1'b0}};
        else
            last_pipe <= {last_pipe[PIPE_DEPTH-2:0], s_axis_tlast};
    end

    wire comp_last_out = last_pipe[PIPE_DEPTH-1];

    // =========================================================================
    // Compressor instance
    // =========================================================================
    compressor comp_inst (
        .clk      (s_axis_aclk),
        .rst_n    (s_axis_aresetn),
        .in_valid (s_axis_tvalid_reg),
        .in_last  (s_axis_tlast_reg),
        .in_data  (s_axis_tdata_reg),
        .out_valid(comp_out_valid),
        .out_data0(comp_out_data0),
        .out_data1(comp_out_data1)
    );

    // =========================================================================
    // Explicit 2-Deep Storage Registers & Control Signals
    // =========================================================================
    reg [15:0] cur_data0;
    reg [15:0] cur_data1;
    reg        cur_d1pres;
    reg        cur_last;
    reg        cur_valid;

    reg [15:0] next_data0;
    reg [15:0] next_data1;
    reg        next_d1pres;
    reg        next_last;
    reg        next_valid;

    wire incoming_d1pres = (comp_out_data1 !== 16'hxxxx);
    
    // Explicit handshake lines to decouple memory updates from FSM execution
    wire fifo_push = comp_out_valid;
    reg  fifo_pop;

    // =========================================================================
    // Storage Update Logic (Manages FIFO Registers)
    // =========================================================================
    always @(posedge m_axis_aclk or negedge m_axis_aresetn) begin
        if (!m_axis_aresetn) begin
            cur_data0   <= 16'd0;
            cur_data1   <= 16'd0;
            cur_d1pres  <= 1'b0;
            cur_last    <= 1'b0;
            cur_valid   <= 1'b0;

            next_data0  <= 16'd0;
            next_data1  <= 16'd0;
            next_d1pres <= 1'b0;
            next_last   <= 1'b0;
            next_valid  <= 1'b0;
        end else begin
            if (fifo_push) begin
                // Case 1: Buffer is totally empty or currently clearing out its last item
                if (!cur_valid || (fifo_pop && !next_valid)) begin
                    cur_data0   <= comp_out_data0;
                    cur_data1   <= comp_out_data1;
                    cur_d1pres  <= incoming_d1pres;
                    cur_last    <= comp_last_out;
                    cur_valid   <= 1'b1;
                end 
                // Case 2: Current slot full, next backup slot empty
                else if (!next_valid) begin
                    next_data0  <= comp_out_data0;
                    next_data1  <= comp_out_data1;
                    next_d1pres <= incoming_d1pres;
                    next_last   <= comp_last_out;
                    next_valid  <= 1'b1;
                end
            end 
            // Case 3: No new data arriving, but FSM consumed current item (Shift down)
            else if (fifo_pop) begin
                cur_data0   <= next_data0;
                cur_data1   <= next_data1;
                cur_d1pres  <= next_d1pres;
                cur_last    <= next_last;
                cur_valid   <= next_valid;
                next_valid  <= 1'b0;
            end
        end
    end

    // =========================================================================
    // AXI Output State Machine
    // =========================================================================
    localparam ST_IDLE  = 2'd0;
    localparam ST_SEND0 = 2'd1;
    localparam ST_SEND1 = 2'd2;

    reg [1:0] out_state;

    always @(posedge m_axis_aclk or negedge m_axis_aresetn) begin
        if (!m_axis_aresetn) begin
            out_state     <= ST_IDLE;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tdata  <= 16'd0;
            fifo_pop      <= 1'b0;
        end else begin
            fifo_pop <= 1'b0; // Default pop strobe off

            case (out_state)
                ST_IDLE: begin
                    // Clamping outputs strictly off inside IDLE to prevent leaks
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    m_axis_tdata  <= 16'd0;

                    if (cur_valid) begin
                        out_state <= ST_SEND0;
                    end
                end

                ST_SEND0: begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tdata  <= cur_data0;
                    m_axis_tlast  <= cur_last && !cur_d1pres;

                    if (m_axis_tready) begin
                        if (cur_d1pres) begin
                            out_state <= ST_SEND1;
                        end else begin
                            fifo_pop  <= 1'b1; // Safe pop strobe triggered
                            out_state <= ST_IDLE;
                        end
                    end
                end

                ST_SEND1: begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tdata  <= cur_data1;
                    m_axis_tlast  <= cur_last;

                    if (m_axis_tready) begin
                        fifo_pop  <= 1'b1; // Safe pop strobe triggered
                        out_state <= ST_IDLE;
                    end
                end

                default: begin
                    out_state <= ST_IDLE;
                end
            endcase
        end
    end