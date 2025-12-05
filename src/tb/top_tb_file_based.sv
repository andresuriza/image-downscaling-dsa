//=======================================================
// File-Based Downscaler Integration Testbench
// Loads test images from .hex files, processes them, and compares
// against expected outputs. Simulates FPGA operation where software
// loads images to SDRAM.
//=======================================================

`timescale 1ns/1ps

module top_tb_file_based;

    //=======================================================
    // Parameters
    //=======================================================
    parameter int LANES = 4;
    parameter int Q = 8;
    parameter int MAX_IMAGE_SIZE = 512;
    parameter int CLK_PERIOD = 20;  // 50 MHz
    
    //=======================================================
    // CSR Register Offsets
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
    localparam logic [11:0] CSR_PERF_CYCLES_LO = 12'h058;
    localparam logic [11:0] CSR_IMG_IN_ADDR  = 12'h080;
    localparam logic [11:0] CSR_IMG_OUT_ADDR = 12'h084;
    
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
    // SDRAM Memory Model (starts empty like real FPGA)
    //=======================================================
    logic [7:0] sdram_mem [0:MAX_IMAGE_SIZE*MAX_IMAGE_SIZE*4-1]; 
    logic [3:0] read_latency_counter;
    logic       pending_read;
    logic [31:0] pending_read_addr;
    
    //=======================================================
    // Test Arrays
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
    string test_name;
    
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
        .csr_address      (csr_address),
        .csr_read         (csr_read),
        .csr_write        (csr_write),
        .csr_writedata    (csr_writedata),
        .csr_byteenable   (csr_byteenable),
        .csr_readdata     (csr_readdata),
        .csr_waitrequest  (csr_waitrequest),
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
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sdram_readdatavalid <= 1'b0;
            pending_read <= 1'b0;
            read_latency_counter <= 4'd0;
            sdram_readdata <= 16'd0;
            sdram_waitrequest <= 1'b0;
        end else begin
            sdram_readdatavalid <= 1'b0;
            sdram_waitrequest <= 1'b0;
            
            // Handle writes
            if (sdram_write && !sdram_waitrequest) begin
                if (sdram_byteenable[0]) sdram_mem[sdram_address] <= sdram_writedata[7:0];
                if (sdram_byteenable[1]) sdram_mem[sdram_address + 1] <= sdram_writedata[15:8];
            end
            
            // Handle reads with 2-cycle latency
            if (sdram_read && !sdram_waitrequest && !pending_read) begin
                pending_read <= 1'b1;
                pending_read_addr <= sdram_address;
                read_latency_counter <= 4'd2;
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
    // CSR Tasks
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
    // Load Image from Hex File to Testbench Array
    //=======================================================
    task automatic load_image_from_file(
        input string filename,
        input int width, height,
        output logic [7:0] image[0:MAX_IMAGE_SIZE*MAX_IMAGE_SIZE-1]
    );
        int fd, status;
        int pixel_count;
        
        fd = $fopen(filename, "r");
        if (fd == 0) begin
            $display("[ERROR] Cannot open file: %s", filename);
            $finish;
        end
        
        pixel_count = 0;
        while (!$feof(fd) && pixel_count < width * height) begin
            status = $fscanf(fd, "%h\n", image[pixel_count]);
            if (status != 1) break;
            pixel_count++;
        end
        
        $fclose(fd);
        
        if (pixel_count != width * height) begin
            $display("[ERROR] Expected %0d pixels, got %0d from %s", 
                     width * height, pixel_count, filename);
            $finish;
        end
        
        $display("[INFO] Loaded %0d pixels from %s", pixel_count, filename);
    endtask
    
    //=======================================================
    // Write Image to SDRAM (simulates software/DMA load)
    //=======================================================
    task automatic write_image_to_sdram(
        input int width, height,
        input logic [31:0] base_addr,
        input logic [7:0] image[0:MAX_IMAGE_SIZE*MAX_IMAGE_SIZE-1]
    );
        int x, y;
        for (y = 0; y < height; y++) begin
            for (x = 0; x < width; x++) begin
                sdram_mem[base_addr + y * width + x] = image[y * width + x];
            end
        end
        $display("[INFO] Wrote %0dx%0d image to SDRAM @ 0x%08X", width, height, base_addr);
    endtask
    
    //=======================================================
    // Read Image from SDRAM
    //=======================================================
    task automatic read_image_from_sdram(
        input int width, height,
        input logic [31:0] base_addr,
        output logic [7:0] image[0:MAX_IMAGE_SIZE*MAX_IMAGE_SIZE-1]
    );
        int x, y;
        for (y = 0; y < height; y++) begin
            for (x = 0; x < width; x++) begin
                image[y * width + x] = sdram_mem[base_addr + y * width + x];
            end
        end
        $display("[INFO] Read %0dx%0d image from SDRAM @ 0x%08X", width, height, base_addr);
    endtask
    
    //=======================================================
    // Compare Images
    //=======================================================
    task automatic compare_images(
        input int width, height,
        input logic [7:0] actual[0:MAX_IMAGE_SIZE*MAX_IMAGE_SIZE-1],
        input logic [7:0] expected[0:MAX_IMAGE_SIZE*MAX_IMAGE_SIZE-1],
        output int mismatches
    );
        int x, y;
        logic [7:0] act, exp;
        int first_mismatch_x, first_mismatch_y;
        logic found_first;
        
        mismatches = 0;
        found_first = 0;
        
        for (y = 0; y < height; y++) begin
            for (x = 0; x < width; x++) begin
                act = actual[y * width + x];
                exp = expected[y * width + x];
                
                if (act !== exp) begin
                    mismatches++;
                    if (!found_first) begin
                        first_mismatch_x = x;
                        first_mismatch_y = y;
                        found_first = 1;
                    end
                    if (mismatches <= 10) begin
                        $display("  [MISMATCH] Pixel(%0d,%0d): actual=0x%02X, expected=0x%02X, diff=%0d", 
                                 x, y, act, exp, $signed(act - exp));
                    end
                end
            end
        end
        
        if (mismatches == 0) begin
            $display("  [PASS] All %0d pixels match", width * height);
        end else begin
            $display("  [FAIL] %0d/%0d pixels mismatch (%.2f%%)", 
                     mismatches, width * height, 
                     (mismatches * 100.0) / (width * height));
            if (found_first) begin
                $display("  First mismatch at (%0d, %0d)", first_mismatch_x, first_mismatch_y);
            end
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
            
            if (cycles % 50000 == 0) begin
                $display("  [WAIT] %0d cycles, status=0x%08X", cycles, status);
            end
            
            if (cycles >= timeout_cycles) begin
                $display("  [ERROR] Timeout after %0d cycles", timeout_cycles);
                return;
            end
        end while (status[0] == 1'b1);
        
        $display("  [INFO] Processing complete in %0d cycles", cycles);
    endtask
    
    //=======================================================
    // Run Single Test Case
    //=======================================================
    task automatic run_test_case(
        input int in_w, in_h, out_w, out_h,
        input string name
    );
        logic [31:0] perf_flops, perf_cycles, progress, errors;
        int mismatches;
        int scale;
        string input_file, expected_file;
        
        $display("\n========================================");
        $display("TEST: %s", name);
        $display("  %0dx%0d -> %0dx%0d", in_w, in_h, out_w, out_h);
        $display("========================================");
        
        // Construct filenames
        input_file = {name, "_input.hex"};
        expected_file = {name, "_expected.hex"};
        
        // Load test data from files
        load_image_from_file(input_file, in_w, in_h, input_image);
        load_image_from_file(expected_file, out_w, out_h, expected_output);
        
        // Simulate software loading image to SDRAM
        write_image_to_sdram(in_w, in_h, 32'h0000_0000, input_image);
        
        // Calculate scale factor
        scale = (in_w << Q) / out_w;
        
        // Configure accelerator via CSR
        csr_write_reg(CSR_IN_WIDTH, in_w);
        csr_write_reg(CSR_IN_HEIGHT, in_h);
        csr_write_reg(CSR_OUT_WIDTH, out_w);
        csr_write_reg(CSR_OUT_HEIGHT, out_h);
        csr_write_reg(CSR_SCALE_Q8_8, scale);
        csr_write_reg(CSR_MODE, 32'd0);  // SIMD mode
        csr_write_reg(CSR_IMG_IN_ADDR, 32'h0000_0000);
        csr_write_reg(CSR_IMG_OUT_ADDR, 32'h0001_0000);
        
        // Start processing
        csr_write_reg(CSR_CTRL, 32'h0000_0001);
        
        // Wait for completion
        wait_for_done(in_w * in_h * 4);
        
        // Read performance counters
        csr_read_reg(CSR_PERF_FLOPS_LO, perf_flops);
        csr_read_reg(CSR_PERF_CYCLES_LO, perf_cycles);
        csr_read_reg(CSR_PROGRESS, progress);
        csr_read_reg(CSR_ERRORS, errors);
        
        $display("  [PERF] Progress: %0d pixels", progress);
        $display("  [PERF] FLOPs: %0d", perf_flops);
        $display("  [PERF] Cycles: %0d", perf_cycles);
        $display("  [PERF] Errors: 0x%08X", errors);
        
        // Read output from SDRAM
        read_image_from_sdram(out_w, out_h, 32'h0001_0000, actual_output);
        
        // Compare against expected
        compare_images(out_w, out_h, actual_output, expected_output, mismatches);
        
        if (mismatches == 0) begin
            test_pass_count++;
            $display("  *** TEST PASSED ***");
        end else begin
            test_fail_count++;
            total_mismatches += mismatches;
            $display("  *** TEST FAILED ***");
        end
    endtask
    
    //=======================================================
    // Main Test Sequence
    //=======================================================
    initial begin
        $display("\n=============================================");
        $display("  File-Based Integration Testbench");
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
        
        // Initialize SDRAM to zero (simulates power-on state)
        for (int i = 0; i < MAX_IMAGE_SIZE*MAX_IMAGE_SIZE*4; i++) begin
            sdram_mem[i] = 8'd0;
        end
        
        // Reset
        repeat(10) @(posedge clk);
        rst_n = 1'b1;
        repeat(10) @(posedge clk);
        
        // Run all test cases (files must exist in test_images/)
        run_test_case(8, 8, 4, 4, "gradient_8x8_to_4x4");
        run_test_case(16, 16, 8, 8, "gradient_16x16_to_8x8");
        run_test_case(32, 32, 16, 16, "gradient_32x32_to_16x16");
        run_test_case(64, 64, 32, 32, "gradient_64x64_to_32x32");
        run_test_case(128, 128, 64, 64, "gradient_128x128_to_64x64");
        run_test_case(256, 256, 128, 128, "gradient_256x256_to_128x128");
        run_test_case(512, 512, 256, 256, "gradient_512x512_to_256x256");
        run_test_case(320, 240, 160, 120, "gradient_320x240_to_160x120");
        
        // Additional pattern tests
        run_test_case(64, 64, 32, 32, "checkerboard_64x64_to_32x32");
        run_test_case(128, 128, 64, 64, "checkerboard_128x128_to_64x64");
        run_test_case(64, 64, 32, 32, "stripes_64x64_to_32x32");
        run_test_case(128, 128, 64, 64, "ramp_128x128_to_64x64");
        
        // Summary
        $display("\n=============================================");
        $display("  TEST SUMMARY");
        $display("=============================================");
        $display("  PASSED: %0d", test_pass_count);
        $display("  FAILED: %0d", test_fail_count);
        $display("  Total mismatches: %0d", total_mismatches);
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
        #50000000;  // 50ms timeout
        $display("[ERROR] Global timeout!");
        $finish;
    end

endmodule
