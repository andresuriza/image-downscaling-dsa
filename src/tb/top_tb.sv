//=======================================================
// Downscaler Top Integration Testbench - Last Updated: 2025-12-04 22:25:30 UTC-6
// Verifies full system: CSR control, SDRAM interface
// Compares output against a behavioral reference model.
//=======================================================

`timescale 1ns/1ps

module top_tb;

    //=======================================================
    // Parameters
    //=======================================================
    parameter int LANES = 4;
    parameter int Q = 8;
    parameter int MAX_IMAGE_SIZE = 512;
    parameter int CLK_PERIOD = 20;  // 50 MHz
    
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
    logic [7:0] sdram_mem [0:MAX_IMAGE_SIZE*MAX_IMAGE_SIZE*2-1]; 
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
    // Removed initial block for these signals to avoid multiple drivers.
    // Initialization moved to the !rst_n block below.
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sdram_readdatavalid <= 1'b0;
            pending_read <= 1'b0;
            read_latency_counter <= 4'd0;
            sdram_readdata <= 16'd0; // Also initialize readdata here
            sdram_waitrequest <= 1'b0;
            sdram_byteenable <= 2'b0;
        end else begin
            sdram_readdatavalid <= 1'b0; // Default to false unless a read completes
            sdram_waitrequest <= 1'b0;
            
            // Handle writes (immediate)
            if (sdram_write && !sdram_waitrequest) begin
                if (sdram_byteenable[0]) sdram_mem[sdram_address] <= sdram_writedata[7:0];
                if (sdram_byteenable[1]) sdram_mem[sdram_address + 1] <= sdram_writedata[15:8];
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
                    sdram_readdata <= {sdram_mem[pending_read_addr + 1], 
                                       sdram_mem[pending_read_addr]};
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
    //=======================================================
    function automatic logic [7:0] bilinear_interpolate(
        input logic [7:0] p00, p01, p10, p11,
        input logic [7:0] frac_x, frac_y
    );
        int ONE_Q = 256;
        int sum;
        int result;
        int w00, w01, w10, w11;

        w00 = (ONE_Q - frac_x) * (ONE_Q - frac_y);
        w01 = frac_x * (ONE_Q - frac_y);
        w10 = (ONE_Q - frac_x) * frac_y;
        w11 = frac_x * frac_y;

        sum = (w00 * p00) + (w01 * p01) + (w10 * p10) + (w11 * p11);

        result = (sum + (1 << (2*Q - 1))) >> (2*Q);

        if (result > 255) result = 255;
        if (result < 0) result = 0;
        
        return result[7:0];
    endfunction
    
    //=======================================================
    // Generate Reference Output
    //=======================================================
    task automatic generate_reference_output(
        input int in_w, in_h, out_w, out_h,
        input int scale_q8_8,
        input logic [7:0] image_in[0:MAX_IMAGE_SIZE*MAX_IMAGE_SIZE-1],
        output logic [7:0] image_ref[0:MAX_IMAGE_SIZE*MAX_IMAGE_SIZE-1]
    );
        int out_x, out_y;
        int src_x_q8, src_y_q8;
        int src_x_int, src_y_int;
        logic [Q-1:0] frac_x, frac_y;
        int x0, y0, x1, y1;
        logic [7:0] p00, p01, p10, p11;
        
        for (out_y = 0; out_y < out_h; out_y++) begin
            for (out_x = 0; out_x < out_w; out_x++) begin
                src_x_q8 = out_x * scale_q8_8;
                src_y_q8 = out_y * scale_q8_8;
                
                src_x_int = src_x_q8 >> Q;
                src_y_int = src_y_q8 >> Q;
                frac_x = src_x_q8[Q-1:0];
                frac_y = src_y_q8[Q-1:0];
                
                x0 = src_x_int;
                y0 = src_y_int;
                x1 = (src_x_int + 1 < in_w) ? src_x_int + 1 : in_w - 1;
                y1 = (src_y_int + 1 < in_h) ? src_y_int + 1 : in_h - 1;
                
                p00 = image_in[y0 * in_w + x0];
                p01 = image_in[y0 * in_w + x1];
                p10 = image_in[y1 * in_w + x0];
                p11 = image_in[y1 * in_w + x1];
                
                image_ref[out_y * out_w + out_x] = 
                    bilinear_interpolate(p00, p01, p10, p11, frac_x, frac_y);
            end
        end
    endtask
    
    //=======================================================
    // Load Input Image to SDRAM
    //=======================================================
    task automatic load_input_to_sdram(
        input int in_w, in_h,
        input logic [31:0] base_addr,
        input logic [7:0] image_in[0:MAX_IMAGE_SIZE*MAX_IMAGE_SIZE-1]
    );
        int x, y;
        for (y = 0; y < in_h; y++) begin
            for (x = 0; x < in_w; x++) begin
                sdram_mem[base_addr + y * in_w + x] = image_in[y * in_w + x];
            end
        end
        $display("[TB] Loaded %0dx%0d input image to SDRAM @ 0x%08X", in_w, in_h, base_addr);
    endtask
    
    //=======================================================
    // Read Output Image from SDRAM
    //=======================================================
    task automatic read_output_from_sdram(
        input int out_w, out_h,
        input logic [31:0] base_addr,
        output logic [7:0] image_out[0:MAX_IMAGE_SIZE*MAX_IMAGE_SIZE-1]
    );
        int x, y;
        for (y = 0; y < out_h; y++) begin
            for (x = 0; x < out_w; x++) begin
                image_out[y * out_w + x] = sdram_mem[base_addr + y * out_w + x];
            end
        end
        $display("[TB] Read %0dx%0d output image from SDRAM @ 0x%08X", out_w, out_h, base_addr);
    endtask
    
    //=======================================================
    // Compare Output Against Reference
    //=======================================================
    task automatic compare_output(
        input int out_w, out_h,
        input logic [7:0] image_out[0:MAX_IMAGE_SIZE*MAX_IMAGE_SIZE-1],
        input logic [7:0] image_ref[0:MAX_IMAGE_SIZE*MAX_IMAGE_SIZE-1],
        output int mismatches
    );
        int x, y;
        logic [7:0] actual, expected;
        mismatches = 0;
        
        for (y = 0; y < out_h; y++) begin
            for (x = 0; x < out_w; x++) begin
                actual = image_out[y * out_w + x];
                expected = image_ref[y * out_w + x];
                
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
            
            if (cycles % 10000 == 0) begin
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
    // Test: Image Downscaling
    //=======================================================
    task automatic test_image_downscale(input int in_w, in_h, out_w, out_h);
        logic [31:0] version, status, progress;
        logic [31:0] perf_flops, perf_cycles;
        int mismatches;
        int scale;
        int y, x;
        
        $display("\n========================================");
        $display("TEST: Image Downscale %dx%d -> %dx%d", in_w, in_h, out_w, out_h);
        $display("========================================");
        
        scale = (in_w << Q) / out_w;
        
        // Generate gradient test pattern
        for (y = 0; y < in_h; y++) begin
            for (x = 0; x < in_w; x++) begin
                input_image[y * in_w + x] = ((x + y) * (256/in_w)) & 8'hFF;
            end
        end
        
        // Generate reference output
        generate_reference_output(in_w, in_h, out_w, out_h, scale, input_image, expected_output);
        
        // Load input to SDRAM
        load_input_to_sdram(in_w, in_h, 32'h0000_0000, input_image);
        
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
        wait_for_done(in_w*in_h*2);
        
        // Read performance counters
        csr_read_reg(CSR_PERF_FLOPS_LO, perf_flops);
        csr_read_reg(CSR_PERF_CYCLES_LO, perf_cycles);
        csr_read_reg(CSR_PROGRESS, progress);
        $display("[TB] Progress: %0d pixels", progress);
        $display("[TB] FLOPs: %0d", perf_flops);
        $display("[TB] Cycles: %0d", perf_cycles);
        
        // Read output from SDRAM
        read_output_from_sdram(out_w, out_h, 32'h0001_0000, actual_output);
        
        // Compare against reference
        compare_output(out_w, out_h, actual_output, expected_output, mismatches);
        
        if (mismatches == 0) begin
            test_pass_count++;
        end else begin
            test_fail_count++;
            total_mismatches += mismatches;
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
        
        // Initialize SDRAM (This block is not related to the always_ff block for sdram_readdatavalid etc., it initializes the memory content)
        for (int i = 0; i < MAX_IMAGE_SIZE*MAX_IMAGE_SIZE*2; i++) begin
            sdram_mem[i] = 8'd0;
        end
        
        // Reset
        repeat(10) @(posedge clk);
        rst_n = 1'b1;
        repeat(10) @(posedge clk);
        
        // Run tests
        test_image_downscale(8, 8, 4, 4);
        test_image_downscale(16, 16, 8, 8);
        test_image_downscale(32, 32, 16, 16);
        test_image_downscale(64, 64, 32, 32);
        test_image_downscale(128, 128, 64, 64);
        test_image_downscale(256, 256, 128, 128);
        test_image_downscale(512, 512, 256, 256);
        test_image_downscale(320, 240, 160, 120);

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
        #20000000;  // 20ms timeout
        $display("[TB] ERROR: Global timeout!");
        $finish;
    end

endmodule
