//=======================================================
// Serial Bilinear Interpolation - DSP Optimized
// 
// Single-pixel-per-cycle design for comparison with SIMD.
// Uses 3-stage pipeline for DSP inference (same as SIMD).
//
// Formula per pixel:
//   result = (1-fx)*(1-fy)*p00 + fx*(1-fy)*p01 + 
//            (1-fx)*fy*p10 + fx*fy*p11
//
// Rounding: Uses Banker's Rounding (round half to even)
// to eliminate bias when fractional part is exactly 0.5
//
// Parameters inherited from downscaler_top
//=======================================================

module downscaling_serial #(
    parameter int Q = 8     // Fractional bits (from top)
) (
    input  logic clk,
    input  logic rst_n,

    // Control
    input  logic start,
    input  logic [31:0] in_width, in_height,
    input  logic [31:0] out_width, out_height,
    input  logic [31:0] scale_q8_8,
    
    // Status
    output logic busy,
    output logic [31:0] progress,
    output logic [31:0] errors,

    // Performance counters
    output logic [63:0] perf_flops,
    output logic [63:0] perf_mem_reads,
    output logic [63:0] perf_mem_writes,

    // Pixel inputs (single pixel, not packed)
    input  logic [7:0] p00,
    input  logic [7:0] p01,
    input  logic [7:0] p10,
    input  logic [7:0] p11,
    input  logic [Q-1:0] frac_x,
    input  logic [Q-1:0] frac_y,

    // Output (single pixel)
    output logic [7:0] out_pixel,
    output logic out_valid
);

    //=======================================================
    // Derived constants from parameters
    //=======================================================
    localparam int PIXEL_WIDTH = 8;                      // Bits per pixel
    localparam int ONE_Q       = (1 << Q);               // 1.0 in Q format (256 for Q=8)
    localparam int HALF_Q      = (1 << (Q-1));           // 0.5 in Q format (128 for Q=8)
    localparam int MAX_PIXEL   = (1 << PIXEL_WIDTH) - 1; // Max pixel value (255 for 8-bit)
    localparam int FLOPS_PER_PIXEL = 8;                  // FLOPs per bilinear interpolation

    //=======================================================
    // Pipeline registers - 3 stage for DSP inference
    //=======================================================
    logic valid_s1, valid_s2;
    
    // Stage 1: Registered inputs and weight calculation
    logic [PIXEL_WIDTH-1:0] p00_r, p01_r, p10_r, p11_r;
    // Weights kept at full 18-bit precision (no pre-shift, matching C reference)
    logic [17:0] w00, w01, w10, w11;
    
    // Stage 2: Multiply-accumulate result (18-bit weight * 8-bit pixel + sum of 4)
    logic [27:0] sum;
    
    // Combinational weight calculation signals
    logic [Q:0]     fx_comb, fy_comb;
    logic [Q:0]     inv_fx_comb, inv_fy_comb;
    logic [2*Q+1:0] w00_comb, w01_comb, w10_comb, w11_comb;
    
    // Combinational output signals (no rounding, matching C reference)
    logic [PIXEL_WIDTH-1:0] out_pixel_comb;
    
    // Simple status
    logic running;
    logic [31:0] produced;
    
    // Unused outputs tied off
    assign busy = running;
    assign errors = 32'd0;
    assign perf_mem_reads = 64'd0;
    assign perf_mem_writes = 64'd0;
    
    //=======================================================
    // Control logic
    //=======================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 1'b0;
            produced <= 32'd0;
            progress <= 32'd0;
            perf_flops <= 64'd0;
        end else begin
            if (start && !running) begin
                running <= 1'b1;
                produced <= 32'd0;
            end
            
            if (running && valid_s2) begin
                produced <= produced + 1;  // Serial: 1 pixel at a time
                progress <= produced + 1;
                perf_flops <= perf_flops + FLOPS_PER_PIXEL;
            end
            
            if (running && (produced + 1 >= out_width * out_height)) begin
                running <= 1'b0;
            end
        end
    end
    
    //=======================================================
    // Combinational Weight Calculation (for DSP inference)
    //=======================================================
    assign fx_comb     = {1'b0, frac_x};
    assign fy_comb     = {1'b0, frac_y};
    assign inv_fx_comb = (Q+1)'(ONE_Q) - fx_comb;
    assign inv_fy_comb = (Q+1)'(ONE_Q) - fy_comb;
    
    // Weight products ((Q+1) x (Q+1) bits)
    assign w00_comb = inv_fx_comb * inv_fy_comb;
    assign w01_comb = fx_comb * inv_fy_comb;
    assign w10_comb = inv_fx_comb * fy_comb;
    assign w11_comb = fx_comb * fy_comb;
    
    // Output normalization with Banker's Rounding (round half to even)
    // When fractional part is exactly 0.5 (0x8000), round to nearest even
    // This eliminates rounding bias and matches IEEE 754 behavior
    wire is_exactly_half = (sum[15:0] == 16'h8000);  // Fractional part == 0.5
    wire result_is_odd   = sum[16];                   // LSB of result after shift
    
    // Apply bias only if NOT (exactly half AND result would be even)
    // i.e., apply bias if: not exactly half, OR result is odd
    wire apply_bias = ~is_exactly_half | result_is_odd;
    wire [27:0] sum_rounded = apply_bias ? (sum + 28'h8000) : sum;
    
    assign out_pixel_comb = (sum_rounded[27:24] != 4'd0) ? MAX_PIXEL[7:0] : sum_rounded[23:16];
    assign out_pixel = out_pixel_comb;
    
    //=======================================================
    // Pipeline Stage 1: Register inputs + Weight calculation
    //=======================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1 <= 1'b0;
            p00_r <= 8'd0;
            p01_r <= 8'd0;
            p10_r <= 8'd0;
            p11_r <= 8'd0;
            w00 <= 18'd0;
            w01 <= 18'd0;
            w10 <= 18'd0;
            w11 <= 18'd0;
        end else begin
            valid_s1 <= start;
            
            // Register pixel inputs
            p00_r <= p00;
            p01_r <= p01;
            p10_r <= p10;
            p11_r <= p11;
            
            // Register weights at full precision (no pre-shift, matching C)
            w00 <= w00_comb[17:0];
            w01 <= w01_comb[17:0];
            w10 <= w10_comb[17:0];
            w11 <= w11_comb[17:0];
        end
    end
    
    //=======================================================
    // Pipeline Stage 2: Multiply-Accumulate (MAC)
    // 4 MACs - maps to DSP blocks
    //=======================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s2 <= 1'b0;
            sum <= 28'd0;
        end else begin
            valid_s2 <= valid_s1;
            
            // Weighted sum: each product is 16+8=24 bits max
            sum <= (w00 * p00_r) + (w01 * p01_r) +
                   (w10 * p10_r) + (w11 * p11_r);
        end
    end
    
    //=======================================================
    // Output valid assignment
    //=======================================================
    assign out_valid = valid_s2;

endmodule