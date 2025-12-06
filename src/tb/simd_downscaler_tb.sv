// Testbench for simd_downscaler - Last Updated: 2025-12-04 22:10:30 UTC-6
`timescale 1ns/1ps

module simd_downscaler_tb;

    // Parameters
    localparam int LANES = 4;
    localparam int Q = 8;
    localparam int PIXEL_WIDTH = 8;
    localparam int MAX_DIM = 512; // Max image dimension for module-level arrays

    // Clock and Reset
    logic clk = 0;
    logic rst_n = 0;

    // Inputs to DUT (driven by testbench tasks)
    logic start = 0;
    logic [31:0] in_width;
    logic [31:0] in_height;
    logic [31:0] out_width;
    logic [31:0] out_height;
    logic [31:0] scale_q8_8;
    logic [LANES*PIXEL_WIDTH-1:0] p00_packed, p01_packed, p10_packed, p11_packed;
    logic [LANES*Q-1:0] frac_x_packed, frac_y_packed;

    // Outputs from DUT
    logic busy;
    logic [31:0] progress;
    logic [31:0] errors;
    logic [63:0] perf_flops;
    logic [63:0] perf_mem_reads;
    logic [63:0] perf_mem_writes;
    logic [LANES*PIXEL_WIDTH-1:0] out_pixels_packed;
    logic out_valid;

    // Module-level image arrays (max size, used by tasks)
    logic [PIXEL_WIDTH-1:0] image_in_mem[MAX_DIM][MAX_DIM];
    logic [PIXEL_WIDTH-1:0] image_out_mem[MAX_DIM][MAX_DIM];
    logic [PIXEL_WIDTH-1:0] image_ref_mem[MAX_DIM][MAX_DIM];

    // Instantiate the DUT
    simd_downscaler #(
        .LANES(LANES),
        .Q(Q)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .in_width(in_width),
        .in_height(in_height),
        .out_width(out_width),
        .out_height(out_height),
        .scale_q8_8(scale_q8_8),
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

    // Clock generation
    always #5 clk = ~clk;

    // Test sequence
    initial begin
        $display("Starting simd_downscaler testbench...");
        rst_n = 0;
        #10;
        rst_n = 1;
        #10;

        // Run tests with various image dimensions
        run_test(512, 512, 256, 256);
        run_test(256, 256, 128, 128);
        run_test(128, 128, 64, 64);
        run_test(320, 240, 160, 120);

        $display("All simd_downscaler tests passed!");
        $finish;
    end

    // Task to run a single downscaling test case
    task automatic run_test(
        input int IW,   // Input Width
        input int I_H,  // Input Height
        input int OW,   // Output Width
        input int OH    // Output Height
    );
        int i, j;
        // Assign dynamic dimensions to DUT inputs
        in_width = IW;
        in_height = I_H;
        out_width = OW;
        out_height = OH;
        
        $display("Running test for %dx%d -> %dx%d downscaling", IW, I_H, OW, OH);

        // Initialize input image with a simple pattern
        for (i = 0; i < I_H; i++) begin
            for (j = 0; j < IW; j++) begin
                image_in_mem[i][j] = (i + j) % 256;
            end
        end

        // Calculate scale factor for reference model and DUT
        scale_q8_8 = (IW << Q) / OW; // Using DUT\"s Q parameter

        // Generate reference output image
        generate_reference(IW, I_H, OW, OH);

        // Drive inputs to DUT and capture outputs
        process_image(IW, I_H, OW, OH, scale_q8_8);
        
        // Verify DUT output against reference
        verify_image(OW, OH);
    endtask

    // Task to drive pixel inputs to DUT and collect outputs
    task automatic process_image(
        input int IW, I_H, OW, OH,
        input [31:0] scale
    );
        int src_x_q, src_y_q;
        int src_x_int, src_y_int;
        logic [Q-1:0] frac_x, frac_y;
        int y, x, l;
        
        for (y = 0; y < OH; y++) begin
            for (x = 0; x < OW; x = x + LANES) begin
                start = 1; // Assert start for one cycle
                
                for (l = 0; l < LANES; l++) begin
                    if (x + l < OW) begin
                        src_x_q = (x + l) * scale;
                        src_y_q = y * scale;
                        
                        src_x_int = src_x_q >> Q;
                        src_y_int = src_y_q >> Q;
                        
                        frac_x = src_x_q[Q-1:0];
                        frac_y = src_y_q[Q-1:0];

                        // Clamp coordinates to avoid out-of-bounds access for image_in_mem
                        if (src_x_int >= IW - 1) src_x_int = IW - 2;
                        if (src_y_int >= I_H - 1) src_y_int = I_H - 2;

                        // Pack pixel and fractional values for DUT inputs
                        p00_packed[l*PIXEL_WIDTH +: PIXEL_WIDTH] = image_in_mem[src_y_int][src_x_int];
                        p01_packed[l*PIXEL_WIDTH +: PIXEL_WIDTH] = image_in_mem[src_y_int][src_x_int+1];
                        p10_packed[l*PIXEL_WIDTH +: PIXEL_WIDTH] = image_in_mem[src_y_int+1][src_x_int];
                        p11_packed[l*PIXEL_WIDTH +: PIXEL_WIDTH] = image_in_mem[src_y_int+1][src_x_int+1];
                        frac_x_packed[l*Q +: Q] = frac_x;
                        frac_y_packed[l*Q +: Q] = frac_y;
                    end else begin
                        // For unused lanes, drive with zeros or a neutral value
                        p00_packed[l*PIXEL_WIDTH +: PIXEL_WIDTH] = 0;
                        p01_packed[l*PIXEL_WIDTH +: PIXEL_WIDTH] = 0;
                        p10_packed[l*PIXEL_WIDTH +: PIXEL_WIDTH] = 0;
                        p11_packed[l*PIXEL_WIDTH +: PIXEL_WIDTH] = 0;
                        frac_x_packed[l*Q +: Q] = 0;
                        frac_y_packed[l*Q +: Q] = 0;
                    end
                end // for (l)
                
                @(posedge clk); // Advance one clock cycle
                start = 0;     // Deassert start after one cycle
                
                // Wait for DUT to produce valid output
                while (!out_valid) begin
                    @(posedge clk);
                end
                
                // Unpack and store output pixels
                for (l = 0; l < LANES; l++) begin
                    if (x + l < OW) begin
                        image_out_mem[y][x+l] = out_pixels_packed[l*PIXEL_WIDTH +: PIXEL_WIDTH];
                    end
                end // for (l)
            end // for (x)
        end // for (y)
    endtask

    // Task to generate the reference output using a behavioral model
    task automatic generate_reference(
        input int IW, I_H, OW, OH
    );
        int scale_factor_q;
        int p00_val, p01_val, p10_val, p11_val;
        int src_x_q, src_y_q;
        int src_x_int, src_y_int;
        int frac_x, frac_y;
        int w00, w01, w10, w11;
        int sum_val;
        int y, x;

        scale_factor_q = (IW << Q) / OW; // Calculate scale in Q format

        for (y = 0; y < OH; y++) begin
            for (x = 0; x < OW; x++) begin
                src_x_q = x * scale_factor_q;
                src_y_q = y * scale_factor_q;
                
                src_x_int = src_x_q >> Q;
                src_y_int = src_y_q >> Q;
                
                frac_x = src_x_q & ((1<<Q)-1);
                frac_y = src_y_q & ((1<<Q)-1);
                
                // Clamp coordinates to avoid out-of-bounds access for image_in_mem
                if (src_x_int >= IW - 1) src_x_int = IW - 2;
                if (src_y_int >= I_H - 1) src_y_int = I_H - 2;

                p00_val = image_in_mem[src_y_int][src_x_int];
                p01_val = image_in_mem[src_y_int][src_x_int+1];
                p10_val = image_in_mem[src_y_int+1][src_x_int];
                p11_val = image_in_mem[src_y_int+1][src_x_int+1];

                w00 = (((1<<Q) - frac_x) * ((1<<Q) - frac_y));
                w01 = (frac_x * ((1<<Q) - frac_y));
                w10 = (((1<<Q) - frac_x) * frac_y);
                w11 = (frac_x * frac_y);
                
                sum_val = (w00 * p00_val) + (w01 * p01_val) + (w10 * p10_val) + (w11 * p11_val);
                
                // Rounding: Banker\"s Rounding as in hardware
                sum_val = (sum_val + (1 << (2*Q - 1))) >> (2*Q);

                // Clamp final pixel value
                if (sum_val > ((1 << PIXEL_WIDTH) - 1)) sum_val = ((1 << PIXEL_WIDTH) - 1);
                if (sum_val < 0) sum_val = 0;
                
                image_ref_mem[y][x] = sum_val[PIXEL_WIDTH-1:0];
            end
        end
    endtask

    // Task to verify DUT output against the reference
    task automatic verify_image(
        input int OW, OH
    );
        int errors_count = 0;
        int i, j;
        for (i = 0; i < OH; i++) begin
            for (j = 0; j < OW; j++) begin
                if (image_out_mem[i][j] !== image_ref_mem[i][j]) begin
                    $display("Mismatch at (%d, %d): expected %d, got %d", j, i, image_ref_mem[i][j], image_out_mem[i][j]);
                    errors_count++;
                end
            end
        end

        if (errors_count == 0) begin
            $display("Test PASSED for %dx%d output", OW, OH);
        end else begin
            $display("Test FAILED for %dx%d output with %d errors", OW, OH, errors_count);
            $finish;
        end
    endtask

endmodule
