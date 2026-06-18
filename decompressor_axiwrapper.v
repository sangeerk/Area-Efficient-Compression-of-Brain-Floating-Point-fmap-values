`timescale 1ns / 1ps

module axi_wrapper (
    input wire aclk,
    input wire aresetn,
    // AXI-Stream Slave Ports
    input wire [15:0] s_axis_tdata,
    input wire s_axis_tvalid,
    output wire s_axis_tready,
    input wire s_axis_tlast,
    // AXI-Stream Master Ports
    output wire [15:0] m_axis_tdata,
    output wire m_axis_tvalid,
    input wire m_axis_tready,
    output wire m_axis_tlast
);
    wire reset = ~aresetn;
    wire [15:0] decoded_out;
    wire out_valid;
    wire expansion_done;
    wire ready_for_input;
    reg m_axis_tlast_reg;

    assign s_axis_tready = ready_for_input;

    combined_unpacker_decompressor u_combined (
        .clk(aclk),
        .reset(reset),
        .data_in(s_axis_tdata),
        .data_in_valid(s_axis_tvalid), 
        .in_last(s_axis_tlast),
        .decoded_out(decoded_out),
        .out_valid(out_valid),
        .expansion_done(expansion_done),
        .ready_for_input(ready_for_input)
    );

    assign m_axis_tdata  = decoded_out;
    assign m_axis_tvalid = out_valid;
    assign m_axis_tlast  = m_axis_tlast_reg;

    always @(posedge aclk or negedge aresetn) begin
        if (~aresetn) begin
            m_axis_tlast_reg <= 1'b0;
        end else begin
            if (out_valid && m_axis_tready) begin
                m_axis_tlast_reg <= expansion_done;
            end else if (m_axis_tready) begin
                m_axis_tlast_reg <= 1'b0;
            end
        end
    end
endmodule