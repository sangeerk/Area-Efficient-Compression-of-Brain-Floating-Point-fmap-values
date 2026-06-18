module tb_axi_compressor;

    // Clock and reset
    reg         s_axis_aclk;
    reg         m_axis_aclk;
    reg         s_axis_aresetn;
    reg         m_axis_aresetn;
    
    // AXI Stream Slave (Input)
    reg         s_axis_tvalid;
    reg         s_axis_tlast;
    reg  [15:0] s_axis_tdata;
    wire        s_axis_tready;
    
    // AXI Stream Master (Output)
    wire        m_axis_tvalid;
    wire        m_axis_tlast;
    wire [15:0] m_axis_tdata;
    reg         m_axis_tready;
    
    // File I/O Handlers & Variables
    integer file_in, file_out;
    integer status;
    reg [15:0] temp_val;
    integer timeout_counter;
    
    // Execution Control Flags
    reg         tx_done; // Explicitly tracks when file reading is finished
    
    // Debug signals from wrapper and compressor
    wire        comp_out_valid;
    wire [15:0] comp_out_data0;
    wire [15:0] comp_out_data1;
    wire [1:0]  out_state;
    wire        comp_in_last;
    wire        zrle_valid;
    wire [4:0]  zrle_code;
    wire        delta_valid;
    wire [16:0] delta_code;
    wire [4:0]  delta_size;
    wire        next_valid;
    
    // Instantiate the AXI compressor wrapper
    axi_compressor_wrapper dut (
        .s_axis_aclk(s_axis_aclk),
        .s_axis_aresetn(s_axis_aresetn),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tready(s_axis_tready),
        .m_axis_aclk(m_axis_aclk),
        .m_axis_aresetn(m_axis_aresetn),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tready(m_axis_tready)
    );
    
    // Access internal signals for debug
    assign comp_out_valid = dut.comp_inst.out_valid;
    assign comp_out_data0 = dut.comp_inst.out_data0;
    assign comp_out_data1 = dut.comp_inst.out_data1;
    assign out_state = dut.out_state;
    assign comp_in_last = dut.comp_inst.in_last;
    assign zrle_valid = dut.comp_inst.zrle_valid;
    assign zrle_code = dut.comp_inst.zrle_code;
    assign delta_valid = dut.comp_inst.delta_valid;
    assign delta_code = dut.comp_inst.delta_code;
    assign delta_size = dut.comp_inst.delta_size;
    assign next_valid = dut.next_valid;
    
    // Clock generation
    initial begin
        s_axis_aclk = 0;
        m_axis_aclk = 0;
        forever #5 begin
            s_axis_aclk = ~s_axis_aclk;
            m_axis_aclk = ~m_axis_aclk;
        end
    end
    
    // Block 1: Read stimulus from input file
    initial begin
        // Initialize signals
        s_axis_aresetn = 0;
        m_axis_aresetn = 0;
        s_axis_tvalid  = 0;
        s_axis_tlast   = 0;
        s_axis_tdata   = 0;
        tx_done        = 0;
        
        // Open the input text file
        file_in = $fopen("C:/Users/nisha/Downloads/bf16_fmaps_hex.txt", "r");
        if (file_in == 0) begin
            $display("======================================================================");
            $display("CRITICAL ERROR: Could not open C:/Users/nisha/Downloads/bf16_fmaps_hex.txt");
            $display("======================================================================");
            $finish;
        end
        
        // Reset sequence
        #20;
        s_axis_aresetn = 1;
        m_axis_aresetn = 1;
        #20;
        
        // Read file line by line and stream via AXI
        status = $fscanf(file_in, "%h\n", temp_val);
        while (status == 1) begin
            s_axis_tvalid = 1;
            s_axis_tdata  = temp_val;
            
            if ($feof(file_in)) begin
                s_axis_tlast = 1;
            end else begin
                s_axis_tlast = 0;
            end
            
            @(posedge s_axis_aclk);
            wait(s_axis_tready);
            #10;
            s_axis_tvalid = 0;
            #10;
            
            if (!s_axis_tlast) begin
                status = $fscanf(file_in, "%h\n", temp_val);
            end else begin
                status = 0; // Break loop
            end
        end
        
        s_axis_tvalid = 0;
        s_axis_tlast  = 0;
        $fclose(file_in);
        $display("Finished transmitting data from input file.");
        
        // Signal to Block 2 that transmission is complete
        tx_done = 1; 
    end
    
    // Block 2: Catch compressor internal outputs and save to file
    initial begin
        m_axis_tready = 1;
        timeout_counter = 0;
        
        // Open the output destination file
        file_out = $fopen("C:/Users/nisha/Downloads/compressorop.txt", "w");
        if (file_out == 0) begin
            $display("ERROR: Could not create output file compressorop.txt");
            $finish;
        end
        
        // Wait for reset release
        wait(s_axis_aresetn == 1);
        
        // Process outputs over simulation runtime
        forever begin
            @(posedge m_axis_aclk);
            
            // 1. Capture valid data directly from compressor cores (comp_out_valid)
            if (comp_out_valid) begin
                timeout_counter <= 0; // Active processing resets timeout
                
                // Write out_data0 if valid
                if (^comp_out_data0 !== 1'bx) begin
                    $fwrite(file_out, "%h\n", comp_out_data0);
                end
                
                // Write out_data1 if valid
                if (^comp_out_data1 !== 1'bx) begin
                    $fwrite(file_out, "%h\n", comp_out_data1);
                end
                
            end else begin
                // Only increment timeout counter if Tx is dead silent and completely done
                if (tx_done) begin
                    timeout_counter <= timeout_counter + 1;
                end
            end
            
            // 2. Clean exit conditions: Either TLAST propagates or timeout hits post-Tx
            if ((m_axis_tvalid && m_axis_tlast) || (timeout_counter > 200)) begin
                if (timeout_counter > 200) begin
                    $display("Simulation timed out safely after pipeline went completely idle. Saving results.");
                end else begin
                    $display("Output file written successfully via TLAST. Ending Simulation.");
                end
                #100;
                $fclose(file_out);
                $finish;
            end
        end
    end
    
    // Debug monitor
    initial begin
        $monitor("Time=%0t, comp_in_last=%b, zrle_valid=%b, zrle_code=%h, delta_valid=%b, delta_code=%h, delta_size=%d, comp_out_valid=%b, out_data0=%h, out_data1=%h, out_state=%d, next_valid=%b",
                  $time, comp_in_last, zrle_valid, zrle_code, delta_valid, delta_code, delta_size, comp_out_valid, comp_out_data0, comp_out_data1, out_state, next_valid);
    end

endmodule