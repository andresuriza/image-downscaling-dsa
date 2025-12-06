//=======================================================
// Downscaler Top Integration Testbench
// Verifies full system: CSR control, SDRAM interface, stepping
// Compares output against C reference model (bit-exact)
//=======================================================

`timescale 1ns/1ps

module downscaler_top_tb;

    //=======================================================
    // Parameters
    //=======================================================
    parameter int LANES = 8;
    parameter int Q = 8;
    parameter int MAX_IMAGE_SIZE = 512;
    parameter int CLK_PERIOD = 20;  // 50 MHz
    
    // Test image sizes
    parameter int TEST_IN_W = 8;
    parameter int TEST_IN_H = 8;
    parameter int TEST_OUT_W = 4;
    parameter int TEST_OUT_H = 4;
    
    //=======================================================
    // CSR Register Offsets (match accelerator_csr_bridge.sv)
    //=======================================================
    localparam logic [11:0] CSR_CTRL         = 12'h000;
    localparam logic [11:0] CSR_STATUS       = 12'h004;
    localparam logic [11:0] CSR_IN_WIDTH     = 12'h008;
    localparam logic [11:0] CSR_IN_HEIGHT    = 12'h00C;
    localparam logic [11:0] CSR_OUT_WIDTH    = 12'h010;
    localparam logic [11:0] CSR_OUT_HEIGHT   = 12'h014;
    localparam logic [11:0] CSR_SCALE_Q8_8   = 12'h018;
    localparam logic [11:0] CSR_MODE         = 12'h01C;
    localparam logic [11:0] CSR_PROGRESS     = 12'h020;
    localparam logic [11:0] CSR_ERRORS       = 12'h024;
    localparam logic [11:0] CSR_PERF_FLOPS_LO  = 12'h040;
    localparam logic [11:0] CSR_PERF_FLOPS_HI  = 12'h044;
    localparam logic [11:0] CSR_PERF_READS_LO  = 12'h048;
    localparam logic [11:0] CSR_PERF_CYCLES_LO = 12'h058;
    localparam logic [11:0] CSR_IMG_IN_ADDR  = 12'h080;
    localparam logic [11:0] CSR_IMG_OUT_ADDR = 12'h084;
    localparam logic [11:0] CSR_DBG_STATE_X  = 12'h0A0;
    localparam logic [11:0] CSR_VERSION      = 12'h0FC;
    
    //=======================================================
    // DUT Signals
    //=======================================================
    logic        clk;
    logic        rst_n;
    
    // CSR Avalon-MM Slave
    logic [11:0] csr_address;
    logic        csr_read;
    logic        csr_write;
    logic [31:0] csr_writedata;
    logic [3:0]  csr_byteenable;
    logic [31:0] csr_readdata;
    logic        csr_waitrequest;
    
    // SDRAM Avalon-MM Master
    logic [31:0] sdram_address;
    logic        sdram_read;
    logic        sdram_write;
    logic [15:0] sdram_writedata;
    logic [15:0] sdram_readdata;
    logic        sdram_waitrequest;
    logic        sdram_readdatavalid;
    logic [1:0]  sdram_byteenable;
    
    //=======================================================
    // SDRAM Memory Model
    //=======================================================
    logic [7:0] sdram_mem [0:1048575];  // 1MB memory model
    logic [3:0] read_latency_counter;
    logic       pending_read;
    logic [31:0] pending_read_addr;
    
    //=======================================================
    // Reference Model Data
    //=======================================================
    logic [7:0] input_image [0:MAX_IMAGE_SIZE*MAX_IMAGE_SIZE-1];
    logic [7:0] expected_output [0:MAX_IMAGE_SIZE*MAX_IMAGE_SIZE-1];
    logic [7:0] actual_output [0:MAX_IMAGE_SIZE*MAX_IMAGE_SIZE-1];
    
    //=======================================================
    // Test Control
    //=======================================================
    int test_pass_count;
    int test_fail_count;
    int total_mismatches;
    
    //=======================================================
    // Clock Generation
    //=======================================================
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    //=======================================================
    // DUT Instance
    //=======================================================
    downscaler_top #(
        .LANES(LANES),
        .Q(Q),
        .MAX_IMAGE_SIZE(MAX_IMAGE_SIZE)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        
        // CSR slave
        .csr_address      (csr_address),
        .csr_read         (csr_read),
        .csr_write        (csr_write),
        .csr_writedata    (csr_writedata),
        .csr_byteenable   (csr_byteenable),
        .csr_readdata     (csr_readdata),
        .csr_waitrequest  (csr_waitrequest),
        
        // SDRAM master
        .sdram_address    (sdram_address),
        .sdram_read       (sdram_read),
        .sdram_write      (sdram_write),
        .sdram_writedata  (sdram_writedata),
        .sdram_readdata   (sdram_readdata),
        .sdram_waitrequest(sdram_waitrequest),
        .sdram_readdatavalid(sdram_readdatavalid),
        .sdram_byteenable (sdram_byteenable)
    );
    
    //=======================================================
    // SDRAM Memory Model with Latency
    //=======================================================
    initial begin
        sdram_waitrequest = 1'b0;
        sdram_readdatavalid = 1'b0;
        sdram_readdata = 16'd0;
        pending_read = 1'b0;
        read_latency_counter = 4'd0;
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sdram_readdatavalid <= 1'b0;
            pending_read <= 1'b0;
            read_latency_counter <= 4'd0;
        end else begin
            sdram_readdatavalid <= 1'b0;
            
            // Handle writes (immediate)
            if (sdram_write && !sdram_waitrequest) begin
                sdram_mem[sdram_address[19:0]] <= sdram_writedata[7:0];
                if (sdram_byteenable[1])
                    sdram_mem[sdram_address[19:0] + 1] <= sdram_writedata[15:8];
            end
            
            // Handle reads with latency
            if (sdram_read && !sdram_waitrequest && !pending_read) begin
                pending_read <= 1'b1;
                pending_read_addr <= sdram_address;
                read_latency_counter <= 4'd2;  // 2-cycle latency
            end
            
            if (pending_read) begin
                if (read_latency_counter > 0) begin
                    read_latency_counter <= read_latency_counter - 1;
                end else begin
                    sdram_readdata <= {sdram_mem[pending_read_addr[19:0] + 1], 
                                       sdram_mem[pending_read_addr[19:0]]};
                    sdram_readdatavalid <= 1'b1;
                    pending_read <= 1'b0;
                end
            end
        end
    end
    
    //=======================================================
    // CSR Read/Write Tasks
    //=======================================================
    task automatic csr_write_reg(input logic [11:0] addr, input logic [31:0] data);
        @(posedge clk);
        csr_address <= addr;
        csr_write <= 1'b1;
        csr_writedata <= data;
        csr_byteenable <= 4'hF;
        @(posedge clk);
        while (csr_waitrequest) @(posedge clk);
        csr_write <= 1'b0;
        @(posedge clk);
    endtask
    
    task automatic csr_read_reg(input logic [11:0] addr, output logic [31:0] data);
        @(posedge clk);
        csr_address <= addr;
        csr_read <= 1'b1;
        csr_byteenable <= 4'hF;
        @(posedge clk);
        while (csr_waitrequest) @(posedge clk);
        data = csr_readdata;
        csr_read <= 1'b0;
        @(posedge clk);
    endtask
    
    //=======================================================
    // Bilinear Interpolation Reference Model (Q8.8)
    // Must match C reference model exactly
    //=======================================================
    function automatic logic [7:0] bilinear_interpolate(
        input logic [7:0] p00, p01, p10, p11,
        input logic [7:0] frac_x, frac_y
    );
        int ONE_Q = 256;  // 1.0 in Q8.8
        int HALF_Q = 128; // 0.5 for rounding
        
        int w00, w10, w01, w11;
        int sum;
        int result;
        
        // Compute weights (pre-shift like C++ reference)
        w00 = ((ONE_Q - frac_x) * (ONE_Q - frac_y)) >> 8;
        w10 = (frac_x * (ONE_Q - frac_y)) >> 8;
        w01 = ((ONE_Q - frac_x) * frac_y) >> 8;
        w11 = (frac_x * frac_y) >> 8;
        
        // Weighted sum
        sum = w00 * p00 + w10 * p01 + w01 * p10 + w11 * p11;
        
        // Round and convert to 8-bit
        result = (sum + HALF_Q) >> 8;
        
        // Clamp
        if (result > 255) result = 255;
        if (result < 0) result = 0;
        
        return result[7:0];
    endfunction
    
    //=======================================================
    // Generate Reference Output
    //=======================================================
    task automatic generate_reference_output(
        input int in_w, in_h, out_w, out_h,
        input logic [15:0] scale_q8_8
    );
        int out_x, out_y;
        int src_x_q8, src_y_q8;
        int src_x_int, src_y_int;
        int frac_x, frac_y;
        int x0, y0, x1, y1;
        logic [7:0] p00, p01, p10, p11;
        
        for (out_y = 0; out_y < out_h; out_y++) begin
            for (out_x = 0; out_x < out_w; out_x++) begin
                // Calculate source coordinates in Q8.8
                // src = out * (1/scale) = out * 256 / scale_q8_8
                src_x_q8 = (out_x << 16) / scale_q8_8;
                src_y_q8 = (out_y << 16) / scale_q8_8;
                
                // Integer and fractional parts
                src_x_int = src_x_q8 >> 8;
                src_y_int = src_y_q8 >> 8;
                frac_x = src_x_q8 & 8'hFF;
                frac_y = src_y_q8 & 8'hFF;
                
                // Neighbor coordinates (clamped)
                x0 = src_x_int;
                y0 = src_y_int;
                x1 = (src_x_int + 1 < in_w) ? src_x_int + 1 : in_w - 1;
                y1 = (src_y_int + 1 < in_h) ? src_y_int + 1 : in_h - 1;
                
                // Get neighbor pixels
                p00 = input_image[y0 * in_w + x0];
                p01 = input_image[y0 * in_w + x1];
                p10 = input_image[y1 * in_w + x0];
                p11 = input_image[y1 * in_w + x1];
                
                // Interpolate
                expected_output[out_y * out_w + out_x] = 
                    bilinear_interpolate(p00, p01, p10, p11, frac_x[7:0], frac_y[7:0]);
            end
        end
    endtask
    
    //=======================================================
    // Load Input Image to SDRAM
    //=======================================================
    task automatic load_input_to_sdram(
        input int in_w, in_h,
        input logic [31:0] base_addr
    );
        int x, y;
        for (y = 0; y < in_h; y++) begin
            for (x = 0; x < in_w; x++) begin
                sdram_mem[base_addr + y * in_w + x] = input_image[y * in_w + x];
            end
        end
        $display("[TB] Loaded %0dx%0d input image to SDRAM @ 0x%08X", in_w, in_h, base_addr);
    endtask
    
    //=======================================================
    // Read Output Image from SDRAM
    //=======================================================
    task automatic read_output_from_sdram(
        input int out_w, out_h,
        input logic [31:0] base_addr
    );
        int x, y;
        for (y = 0; y < out_h; y++) begin
            for (x = 0; x < out_w; x++) begin
                actual_output[y * out_w + x] = sdram_mem[base_addr + y * out_w + x];
            end
        end
        $display("[TB] Read %0dx%0d output image from SDRAM @ 0x%08X", out_w, out_h, base_addr);
    endtask
    
    //=======================================================
    // Compare Output Against Reference
    //=======================================================
    task automatic compare_output(
        input int out_w, out_h,
        output int mismatches
    );
        int x, y;
        logic [7:0] actual, expected;
        mismatches = 0;
        
        for (y = 0; y < out_h; y++) begin
            for (x = 0; x < out_w; x++) begin
                actual = actual_output[y * out_w + x];
                expected = expected_output[y * out_w + x];
                
                if (actual !== expected) begin
                    mismatches++;
                    if (mismatches <= 10) begin
                        $display("[TB] MISMATCH at (%0d,%0d): actual=%0d, expected=%0d", 
                                 x, y, actual, expected);
                    end
                end
            end
        end
        
        if (mismatches == 0) begin
            $display("[TB] PASS: All %0d pixels match reference", out_w * out_h);
        end else begin
            $display("[TB] FAIL: %0d/%0d pixels mismatch", mismatches, out_w * out_h);
        end
    endtask
    
    //=======================================================
    // Wait for Processing Complete
    //=======================================================
    task automatic wait_for_done(input int timeout_cycles);
        int cycles;
        logic [31:0] status;
        cycles = 0;
        
        do begin
            @(posedge clk);
            csr_read_reg(CSR_STATUS, status);
            cycles++;
            
            if (cycles % 1000 == 0) begin
                $display("[TB] Waiting... cycles=%0d, status=0x%08X", cycles, status);
            end
            
            if (cycles >= timeout_cycles) begin
                $display("[TB] ERROR: Timeout after %0d cycles", timeout_cycles);
                return;
            end
        end while (status[0] == 1'b1);  // busy bit
        
        $display("[TB] Processing complete after %0d cycles", cycles);
    endtask
    
    //=======================================================
    // Test: Basic Downscaling (8x8 -> 4x4, scale=0.5)
    //=======================================================
    task automatic test_basic_downscale();
        logic [31:0] version, status, progress;
        logic [31:0] perf_flops, perf_cycles;
        int mismatches;
        int in_w, in_h, out_w, out_h;
        logic [15:0] scale;
        
        $display("\n========================================");
        $display("TEST: Basic Downscale 8x8 -> 4x4");
        $display("========================================");
        
        in_w = 8; in_h = 8;
        out_w = 4; out_h = 4;
        scale = 16'h0080;  // 0.5 in Q8.8
        
        // Generate gradient test pattern
        for (int y = 0; y < in_h; y++) begin
            for (int x = 0; x < in_w; x++) begin
                input_image[y * in_w + x] = ((x + y) * 16) & 8'hFF;
            end
        end
        
        // Generate reference output
        generate_reference_output(in_w, in_h, out_w, out_h, scale);
        
        // Load input to SDRAM
        load_input_to_sdram(in_w, in_h, 32'h0000_0000);
        
        // Read version register
        csr_read_reg(CSR_VERSION, version);
        $display("[TB] Version: 0x%08X", version);
        assert(version == 32'h0001_0000) else $error("Version mismatch!");
        
        // Configure accelerator
        csr_write_reg(CSR_IN_WIDTH, in_w);
        csr_write_reg(CSR_IN_HEIGHT, in_h);
        csr_write_reg(CSR_OUT_WIDTH, out_w);
        csr_write_reg(CSR_OUT_HEIGHT, out_h);
        csr_write_reg(CSR_SCALE_Q8_8, scale);
        csr_write_reg(CSR_MODE, 32'd0);  // SIMD mode
        csr_write_reg(CSR_IMG_IN_ADDR, 32'h0000_0000);
        csr_write_reg(CSR_IMG_OUT_ADDR, 32'h0001_0000);
        
        // Start processing
        csr_write_reg(CSR_CTRL, 32'h0000_0001);  // Set start bit
        
        // Wait for completion
        wait_for_done(100000);
        
        // Read performance counters
        csr_read_reg(CSR_PERF_FLOPS_LO, perf_flops);
        csr_read_reg(CSR_PERF_CYCLES_LO, perf_cycles);
        csr_read_reg(CSR_PROGRESS, progress);
        $display("[TB] Progress: %0d pixels", progress);
        $display("[TB] FLOPs: %0d", perf_flops);
        $display("[TB] Cycles: %0d", perf_cycles);
        
        // Read output from SDRAM
        read_output_from_sdram(out_w, out_h, 32'h0001_0000);
        
        // Compare against reference
        compare_output(out_w, out_h, mismatches);
        
        if (mismatches == 0) begin
            test_pass_count++;
        end else begin
            test_fail_count++;
            total_mismatches += mismatches;
        end
    endtask
    
    //=======================================================
    // Test: Stepping Mode
    //=======================================================
    task automatic test_stepping_mode();
        logic [31:0] status, dbg_state;
        int step_count;
        
        $display("\n========================================");
        $display("TEST: Stepping Mode");
        $display("========================================");
        
        // Configure for small image
        csr_write_reg(CSR_IN_WIDTH, 4);
        csr_write_reg(CSR_IN_HEIGHT, 4);
        csr_write_reg(CSR_OUT_WIDTH, 2);
        csr_write_reg(CSR_OUT_HEIGHT, 2);
        csr_write_reg(CSR_SCALE_Q8_8, 16'h0080);
        csr_write_reg(CSR_MODE, 32'd0);
        
        // Enable stepping mode and start
        csr_write_reg(CSR_CTRL, 32'h0000_0005);  // step_enable + start
        
        // Single step a few times
        for (step_count = 0; step_count < 5; step_count++) begin
            @(posedge clk);
            repeat(5) @(posedge clk);
            
            // Read debug state
            csr_read_reg(CSR_DBG_STATE_X, dbg_state);
            $display("[TB] Step %0d: FSM state=%0d, out_x=%0d", 
                     step_count, dbg_state[31:28], dbg_state[15:0]);
            
            // Trigger next step
            csr_write_reg(CSR_CTRL, 32'h0000_000C);  // step_enable + step_once
        end
        
        // Disable stepping to let it complete
        csr_write_reg(CSR_CTRL, 32'h0000_0000);
        
        $display("[TB] Stepping test complete");
        test_pass_count++;
    endtask
    
    //=======================================================
    // Test: CSR Register Access
    //=======================================================
    task automatic test_csr_registers();
        logic [31:0] wr_data, rd_data;
        int errors;
        
        $display("\n========================================");
        $display("TEST: CSR Register Access");
        $display("========================================");
        
        errors = 0;
        
        // Test IN_WIDTH
        wr_data = 32'h0000_0100;  // 256
        csr_write_reg(CSR_IN_WIDTH, wr_data);
        csr_read_reg(CSR_IN_WIDTH, rd_data);
        if (rd_data !== wr_data) begin
            $display("[TB] FAIL: IN_WIDTH write=0x%08X, read=0x%08X", wr_data, rd_data);
            errors++;
        end
        
        // Test SCALE_Q8_8
        wr_data = 32'h0000_00C0;  // 0.75 in Q8.8
        csr_write_reg(CSR_SCALE_Q8_8, wr_data);
        csr_read_reg(CSR_SCALE_Q8_8, rd_data);
        if (rd_data !== wr_data) begin
            $display("[TB] FAIL: SCALE_Q8_8 write=0x%08X, read=0x%08X", wr_data, rd_data);
            errors++;
        end
        
        // Test MODE
        wr_data = 32'h0000_0001;  // Serial mode
        csr_write_reg(CSR_MODE, wr_data);
        csr_read_reg(CSR_MODE, rd_data);
        if (rd_data !== wr_data) begin
            $display("[TB] FAIL: MODE write=0x%08X, read=0x%08X", wr_data, rd_data);
            errors++;
        end
        
        // Test IMG_IN_ADDR
        wr_data = 32'h0010_0000;
        csr_write_reg(CSR_IMG_IN_ADDR, wr_data);
        csr_read_reg(CSR_IMG_IN_ADDR, rd_data);
        if (rd_data !== wr_data) begin
            $display("[TB] FAIL: IMG_IN_ADDR write=0x%08X, read=0x%08X", wr_data, rd_data);
            errors++;
        end
        
        if (errors == 0) begin
            $display("[TB] PASS: All CSR register tests passed");
            test_pass_count++;
        end else begin
            $display("[TB] FAIL: %0d CSR register errors", errors);
            test_fail_count++;
        end
    endtask
    
    //=======================================================
    // Main Test Sequence
    //=======================================================
    initial begin
        $display("\n");
        $display("=============================================");
        $display("  Downscaler Top Integration Testbench");
        $display("  LANES=%0d, Q=%0d", LANES, Q);
        $display("=============================================");
        
        // Initialize
        rst_n = 1'b0;
        csr_address = 12'd0;
        csr_read = 1'b0;
        csr_write = 1'b0;
        csr_writedata = 32'd0;
        csr_byteenable = 4'hF;
        test_pass_count = 0;
        test_fail_count = 0;
        total_mismatches = 0;
        
        // Initialize SDRAM
        for (int i = 0; i < 1048576; i++) begin
            sdram_mem[i] = 8'd0;
        end
        
        // Reset
        repeat(10) @(posedge clk);
        rst_n = 1'b1;
        repeat(10) @(posedge clk);
        
        // Run tests
        test_csr_registers();
        test_basic_downscale();
        test_stepping_mode();
        
        // Summary
        $display("\n");
        $display("=============================================");
        $display("  TEST SUMMARY");
        $display("=============================================");
        $display("  PASSED: %0d", test_pass_count);
        $display("  FAILED: %0d", test_fail_count);
        $display("  Total pixel mismatches: %0d", total_mismatches);
        $display("=============================================");
        
        if (test_fail_count == 0) begin
            $display("  *** ALL TESTS PASSED ***");
        end else begin
            $display("  *** SOME TESTS FAILED ***");
        end
        
        $finish;
    end
    
    //=======================================================
    // Timeout Watchdog
    //=======================================================
    initial begin
        #10000000;  // 10ms timeout
        $display("[TB] ERROR: Global timeout!");
        $finish;
    end

endmodule
