// Testbench for downscaling_serial.sv - Serial (LANES=1) implementation
`timescale 1ns/1ps

module downscaling_serial_tb;

    // Parameters
    localparam int Q = 8;
    localparam int PIXEL_WIDTH = 8;
    localparam int MAX_DIM = 512;

    // Clock and Reset
    logic clk = 0;
    logic rst_n = 0;

    // Inputs to DUT
    logic start = 0;
    logic [31:0] in_width, in_height;
    logic [31:0] out_width, out_height;
    logic [31:0] scale_q8_8;
    logic [PIXEL_WIDTH-1:0] p00, p01, p10, p11;
    logic [Q-1:0] frac_x, frac_y;

    // Outputs from DUT
    logic busy;
    logic [31:0] progress;
    logic [31:0] errors;
    logic [63:0] perf_flops;
    logic [63:0] perf_mem_reads;
    logic [63:0] perf_mem_writes;
    logic [PIXEL_WIDTH-1:0] out_pixel;
    logic out_valid;

    // Module-level image arrays
    logic [PIXEL_WIDTH-1:0] image_in_mem[MAX_DIM][MAX_DIM];
    logic [PIXEL_WIDTH-1:0] image_out_mem[MAX_DIM][MAX_DIM];
    logic [PIXEL_WIDTH-1:0] image_ref_mem[MAX_DIM][MAX_DIM];

    // Instantiate DUT
    downscaling_serial #(
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
        .p00(p00),
        .p01(p01),
        .p10(p10),
        .p11(p11),
        .frac_x(frac_x),
        .frac_y(frac_y),
        .out_pixel(out_pixel),
        .out_valid(out_valid)
    );

    // Clock generation
    always #5 clk = ~clk;

    // Capture outputs
    always @(posedge clk) begin
        if (out_valid) begin
            automatic int out_x = (progress - 1) % out_width;
            automatic int out_y = (progress - 1) / out_width;
            if (out_y < MAX_DIM && out_x < MAX_DIM) begin
                image_out_mem[out_y][out_x] = out_pixel;
            end
        end
    end

    // Test sequence
    initial begin
        $display("Starting downscaling_serial testbench...");
        rst_n = 0;
        #10;
        rst_n = 1;
        #10;

        // Run same tests as SIMD for comparison
        run_test(4, 4, 2, 2);
        run_test(8, 8, 4, 4);
        run_test(16, 16, 8, 8);
        run_test(64, 64, 32, 32);
        run_test(128, 128, 64, 64);
        run_test(256, 256, 128, 128);
        run_test(512, 512, 256, 256);

        $display("\n========================================");
        $display("All serial downscaler tests completed!");
        $display("========================================\n");
        $finish;
    end

    // Bilinear interpolation reference (matching C implementation)
    function automatic logic [7:0] bilinear_q16(
        input logic [7:0] p00, p01, p10, p11,
        input logic [7:0] fx, fy
    );
        logic [15:0] inv_fx, inv_fy;
        logic [31:0] w00, w01, w10, w11;
        logic [31:0] sum;

        inv_fx = 256 - fx;
        inv_fy = 256 - fy;

        w00 = inv_fx * inv_fy;
        w01 = fx * inv_fy;
        w10 = inv_fx * fy;
        w11 = fx * fy;

        sum = w00 * p00 + w01 * p01 + w10 * p10 + w11 * p11;
        
        // Rounding: add 0x8000 (0.5 in Q16) before shift
        return (sum + 32768) >> 16;
    endfunction

    // Load test image with gradient pattern
    task load_image(input int w, h);
        for (int y = 0; y < h; y++) begin
            for (int x = 0; x < w; x++) begin
                image_in_mem[y][x] = ((x * 255 / (w-1)) + (y * 255 / (h-1))) / 2;
            end
        end
    endtask

    // Generate reference output
    task generate_reference(input int in_w, in_h, out_w, out_h, input logic [31:0] scale);
        for (int out_y = 0; out_y < out_h; out_y++) begin
            for (int out_x = 0; out_x < out_w; out_x++) begin
                automatic logic [31:0] src_x_q8 = (out_x << 16) / scale;
                automatic logic [31:0] src_y_q8 = (out_y << 16) / scale;
                
                automatic int x0 = src_x_q8 >> 8;
                automatic int y0 = src_y_q8 >> 8;
                automatic int x1 = (x0 + 1 < in_w) ? x0 + 1 : in_w - 1;
                automatic int y1 = (y0 + 1 < in_h) ? y0 + 1 : in_h - 1;
                
                automatic logic [7:0] fx = src_x_q8[7:0];
                automatic logic [7:0] fy = src_y_q8[7:0];
                
                automatic logic [7:0] px00 = image_in_mem[y0][x0];
                automatic logic [7:0] px01 = image_in_mem[y0][x1];
                automatic logic [7:0] px10 = image_in_mem[y1][x0];
                automatic logic [7:0] px11 = image_in_mem[y1][x1];
                
                image_ref_mem[out_y][out_x] = bilinear_q16(px00, px01, px10, px11, fx, fy);
            end
        end
    endtask

    // Drive pixel inputs
    task drive_pixel(input int out_y, out_x, input logic [31:0] scale);
        automatic logic [31:0] src_x_q8 = (out_x << 16) / scale;
        automatic logic [31:0] src_y_q8 = (out_y << 16) / scale;
        
        automatic int x0 = src_x_q8 >> 8;
        automatic int y0 = src_y_q8 >> 8;
        automatic int x1 = (x0 + 1 < in_width) ? x0 + 1 : in_width - 1;
        automatic int y1 = (y0 + 1 < in_height) ? y0 + 1 : in_height - 1;
        
        p00 = image_in_mem[y0][x0];
        p01 = image_in_mem[y0][x1];
        p10 = image_in_mem[y1][x0];
        p11 = image_in_mem[y1][x1];
        frac_x = src_x_q8[7:0];
        frac_y = src_y_q8[7:0];
    endtask

    // Run test
    task automatic run_test(input int in_w, in_h, out_w, out_h);
        automatic int total_pixels = out_w * out_h;
        automatic int mismatches = 0;
        automatic logic [31:0] scale;
        
        $display("\n--- Test: %0dx%0d -> %0dx%0d ---", in_w, in_h, out_w, out_h);
        
        // Calculate scale factor
        scale = ((in_w - 1) << 16) / (out_w - 1);
        
        // Setup
        in_width = in_w;
        in_height = in_h;
        out_width = out_w;
        out_height = out_h;
        scale_q8_8 = scale;
        
        load_image(in_w, in_h);
        generate_reference(in_w, in_h, out_w, out_h, scale);
        
        // Start processing
        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;
        
        // Drive pixels as DUT requests them
        for (int oy = 0; oy < out_h; oy++) begin
            for (int ox = 0; ox < out_w; ox++) begin
                drive_pixel(oy, ox, scale);
                @(posedge clk);
            end
        end
        
        // Wait for completion
        wait(!busy);
        @(posedge clk);
        
        // Compare results
        for (int y = 0; y < out_h; y++) begin
            for (int x = 0; x < out_w; x++) begin
                if (image_out_mem[y][x] !== image_ref_mem[y][x]) begin
                    if (mismatches < 10) begin
                        $display("  Mismatch at (%0d,%0d): got %0d, expected %0d",
                                x, y, image_out_mem[y][x], image_ref_mem[y][x]);
                    end
                    mismatches++;
                end
            end
        end
        
        if (mismatches == 0) begin
            $display("  PASS: All %0d pixels match!", total_pixels);
        end else begin
            $display("  FAIL: %0d/%0d pixels mismatch (%.1f%%)",
                    mismatches, total_pixels, (mismatches * 100.0) / total_pixels);
        end
    endtask

endmodule
