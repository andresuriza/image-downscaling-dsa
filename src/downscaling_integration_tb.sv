module downscaling_integration_tb;

    // Parameters
    localparam LANES = 8;
    localparam Q = 8;

    // Clock and reset
    logic clk = 0;
    logic rst_n = 1;
    always #5 clk = ~clk;

    // DUT signals
    logic start;
    logic [31:0] in_width, in_height;
    logic [31:0] out_width, out_height;
    logic [31:0] scale_q8_8;
    logic [1:0] mode;
    logic busy;
    logic [31:0] progress, errors;
    logic [63:0] perf_flops, perf_mem_reads, perf_mem_writes;
    logic [LANES*8-1:0] p00_packed, p01_packed, p10_packed, p11_packed;
    logic [LANES*Q-1:0] frac_x_packed, frac_y_packed;
    logic [LANES*8-1:0] out_pixels_packed;
    logic out_valid;

    // Test control
    logic test_passed = 1;
    int test_case = 0;

    // Instantiate DUT
    simd_downscaler #(.LANES(LANES), .Q(Q)) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .in_width(in_width),
        .in_height(in_height),
        .out_width(out_width),
        .out_height(out_height),
        .scale_q8_8(scale_q8_8),
        .mode(mode),
        .busy(busy),
        .progress(progress),
        .errors(errors),
        .perf_flops(perf_flops),
        .perf_mem_reads(perf_mem_reads),
        .perf_mem_writes(perf_mem_writes),
        .p00_packed(p00_packed),
        .p01_packed(p01_packed),
        .p10_packed(p10_packed),
        .p11_packed(p11_packed),
        .frac_x_packed(frac_x_packed),
        .frac_y_packed(frac_y_packed),
        .out_pixels_packed(out_pixels_packed),
        .out_valid(out_valid)
    );

    // Task to run a single test case
    task run_test_case(
        input int in_w, 
        input int in_h, 
        input int out_w, 
        input int out_h
    );
        int total_pixels;
        int cycles_waited;
        
        $display("\n=== TEST CASE %0d: %0dx%0d -> %0dx%0d ===", 
                 test_case, in_w, in_h, out_w, out_h);
        
        // Setup parameters
        in_width = in_w;
        in_height = in_h;
        out_width = out_w;
        out_height = out_h;
        
        // Calculate scale factor
        if (out_w > 1)
            scale_q8_8 = ((in_w - 1) * 256) / (out_w - 1);
        else
            scale_q8_8 = 256; // Scale 1:1
        
        mode = 2'b00; // SIMD mode
        total_pixels = out_w * out_h;
        cycles_waited = 0;
        
        // Reset the DUT
        $display("Resetting DUT...");
        rst_n = 0;
        start = 0;
        #40;
        rst_n = 1;
        #20;
        
        // Start processing
        $display("Starting processing...");
        start = 1;
        @(posedge clk);
        start = 0;
        
        // Wait for completion with timeout
        $display("Waiting for completion...");
        while (busy && cycles_waited < 1000) begin
            @(posedge clk);
            cycles_waited++;
            
            // Provide dummy input data (all zeros for simplicity)
            p00_packed = {LANES{8'h00}};
            p01_packed = {LANES{8'h00}};
            p10_packed = {LANES{8'h00}};
            p11_packed = {LANES{8'h00}};
            frac_x_packed = {LANES{8'h80}}; // 0.5 in Q0.8
            frac_y_packed = {LANES{8'h80}}; // 0.5 in Q0.8
            
            if (cycles_waited % 100 == 0) begin
                $display("  Progress: %0d/%0d (cycle %0d)", 
                         progress, total_pixels, cycles_waited);
            end
        end
        
        // Check results
        if (cycles_waited >= 1000) begin
            $display("ERROR: Timeout after %0d cycles!", cycles_waited);
            test_passed = 0;
        end else begin
            $display("SUCCESS: Completed in %0d cycles", cycles_waited);
            $display("  Progress: %0d, Errors: %0d", progress, errors);
            $display("  Performance: FLOPS=%0d, Reads=%0d, Writes=%0d",
                     perf_flops, perf_mem_reads, perf_mem_writes);
        end
        
        test_case++;
        #100; // Wait before next test
    endtask

    // Main test sequence
    initial begin
        $display("==========================================");
        $display("    SIMD DOWNSCALER INTEGRATION TEST");
        $display("==========================================");
        
        // Wait a bit after reset
        #100;
        
        // Run test cases from smallest to largest
        run_test_case(4, 4, 2, 2);
        run_test_case(8, 8, 4, 4);
        run_test_case(16, 16, 8, 8);
        run_test_case(32, 32, 16, 16);
        
        // Final summary
        $display("\n==========================================");
        $display("            TEST SUMMARY");
        $display("==========================================");
        if (test_passed) begin
            $display("*** ALL INTEGRATION TESTS PASSED ***");
        end else begin
            $display("*** SOME TESTS FAILED ***");
        end
        $display("Total test cases run: %0d", test_case);
        $display("==========================================");
        
        $finish;
    end

    // Monitor for output data
    initial begin
        int output_count = 0;
        forever begin
            @(posedge clk);
            if (out_valid) begin
                output_count += LANES;
                if (output_count % 100 == 0) begin
                    $display("Output data: %0d pixels processed", output_count);
                end
            end
        end
    end

endmodule