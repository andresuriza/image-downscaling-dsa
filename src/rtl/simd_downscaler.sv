//=======================================================
// SIMD Bilinear Interpolation - DSP Optimized
// 
// Simplified pipelined design for efficient DSP inference.
// Uses 3-stage pipeline to improve Fmax and DSP utilization.
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

module simd_downscaler #(
    parameter int LANES = 4,    // Number of parallel lanes (from top)
    parameter int Q     = 8     // Fractional bits (from top)
) (
    input  logic clk,
    input  logic rst_n,

    // Control (directly from FSM)
    input  logic start,
    input  logic [31:0] in_width, in_height,
    input  logic [31:0] out_width, out_height,
    input  logic [31:0] scale_q8_8,
    
    // Status (directly from FSM - simplified)
    output logic busy,
    output logic [31:0] progress,
    output logic [31:0] errors,

    // Performance counters
    output logic [63:0] perf_flops,
    output logic [63:0] perf_mem_reads,
    output logic [63:0] perf_mem_writes,

    // Pixel inputs
    input  logic [LANES*8-1:0] p00_packed,
    input  logic [LANES*8-1:0] p01_packed,
    input  logic [LANES*8-1:0] p10_packed,
    input  logic [LANES*8-1:0] p11_packed,
    input  logic [LANES*Q-1:0] frac_x_packed,
    input  logic [LANES*Q-1:0] frac_y_packed,

    // Output
    output logic [LANES*8-1:0] out_pixels_packed,
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
    logic [PIXEL_WIDTH-1:0] p00_r [LANES-1:0];
    logic [PIXEL_WIDTH-1:0] p01_r [LANES-1:0];
    logic [PIXEL_WIDTH-1:0] p10_r [LANES-1:0];
    logic [PIXEL_WIDTH-1:0] p11_r [LANES-1:0];
    // Weights kept at full 18-bit precision (no pre-shift, matching C reference)
    logic [17:0] w00   [LANES-1:0];
    logic [17:0] w01   [LANES-1:0];
    logic [17:0] w10   [LANES-1:0];
    logic [17:0] w11   [LANES-1:0];
    
    // Stage 2: Multiply-accumulate result (18-bit weight * 8-bit pixel + sum of 4)
    logic [27:0] sum   [LANES-1:0];
    
    // Combinational weight calculation signals
    logic [Q:0]    fx_comb    [LANES-1:0];  // Q+1 bits for (1-fx) calculation
    logic [Q:0]    fy_comb    [LANES-1:0];
    logic [Q:0]    inv_fx_comb[LANES-1:0];
    logic [Q:0]    inv_fy_comb[LANES-1:0];
    logic [2*Q+1:0] w00_comb  [LANES-1:0];  // Weight product width
    logic [2*Q+1:0] w01_comb  [LANES-1:0];
    logic [2*Q+1:0] w10_comb  [LANES-1:0];
    logic [2*Q+1:0] w11_comb  [LANES-1:0];
    
    // Combinational output signals (no rounding, matching C reference)
    logic [PIXEL_WIDTH-1:0] out_pixel [LANES-1:0];
    
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
                produced <= produced + LANES;
                progress <= produced + LANES;
                perf_flops <= perf_flops + (LANES * FLOPS_PER_PIXEL);
            end
            
            if (running && (produced + LANES >= out_width * out_height)) begin
                running <= 1'b0;
            end
        end
    end
    
    //=======================================================
    // Combinational Weight Calculation (for DSP inference)
    //=======================================================
    genvar g;
    generate
        for (g = 0; g < LANES; g++) begin : weight_calc
            assign fx_comb[g]     = {1'b0, frac_x_packed[g*Q +: Q]};
            assign fy_comb[g]     = {1'b0, frac_y_packed[g*Q +: Q]};
            assign inv_fx_comb[g] = (Q+1)'(ONE_Q) - fx_comb[g];
            assign inv_fy_comb[g] = (Q+1)'(ONE_Q) - fy_comb[g];
            
            // Weight products ((Q+1) x (Q+1) bits = 9x9 = 18 bits)
            assign w00_comb[g] = inv_fx_comb[g] * inv_fy_comb[g];
            assign w01_comb[g] = fx_comb[g] * inv_fy_comb[g];
            assign w10_comb[g] = inv_fx_comb[g] * fy_comb[g];
            assign w11_comb[g] = fx_comb[g] * fy_comb[g];
            
            // Output normalization with Banker's Rounding (round half to even)
            // When fractional part is exactly 0.5 (0x8000), round to nearest even
            // This eliminates rounding bias and matches IEEE 754 behavior
            wire is_exactly_half = (sum[g][15:0] == 16'h8000);  // Fractional part == 0.5
            wire result_is_odd   = sum[g][16];                   // LSB of result after shift
            
            // Apply bias only if NOT (exactly half AND result would be even)
            wire apply_bias = ~is_exactly_half | result_is_odd;
            wire [27:0] sum_rounded = apply_bias ? (sum[g] + 28'h8000) : sum[g];
            
            assign out_pixel[g] = (sum_rounded[27:24] != 4'd0) ? PIXEL_WIDTH'(MAX_PIXEL) : sum_rounded[23:16];
            assign out_pixels_packed[g*PIXEL_WIDTH +: PIXEL_WIDTH] = out_pixel[g];
        end
    endgenerate
    
    //=======================================================
    // Pipeline Stage 1: Register inputs + Weight calculation
    // (* multstyle = "dsp" *) hint for Quartus DSP inference
    //=======================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s1 <= 1'b0;
            for (int i = 0; i < LANES; i++) begin
                p00_r[i] <= '0;
                p01_r[i] <= '0;
                p10_r[i] <= '0;
                p11_r[i] <= '0;
                w00[i] <= '0;
                w01[i] <= '0;
                w10[i] <= '0;
                w11[i] <= '0;
            end
        end else begin
            valid_s1 <= start;
            
            for (int i = 0; i < LANES; i++) begin
                // Register pixel inputs
                p00_r[i] <= p00_packed[i*PIXEL_WIDTH +: PIXEL_WIDTH];
                p01_r[i] <= p01_packed[i*PIXEL_WIDTH +: PIXEL_WIDTH];
                p10_r[i] <= p10_packed[i*PIXEL_WIDTH +: PIXEL_WIDTH];
                p11_r[i] <= p11_packed[i*PIXEL_WIDTH +: PIXEL_WIDTH];
                
                // Register weights at full precision (no pre-shift, matching C)
                w00[i] <= w00_comb[i][17:0];
                w01[i] <= w01_comb[i][17:0];
                w10[i] <= w10_comb[i][17:0];
                w11[i] <= w11_comb[i][17:0];
            end
        end
    end
    
    //=======================================================
    // Pipeline Stage 2: Multiply-Accumulate (MAC)
    // 4 parallel MACs per lane - maps to DSP blocks
    //=======================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s2 <= 1'b0;
            for (int i = 0; i < LANES; i++) begin
                sum[i] <= 28'd0;
            end
        end else begin
            valid_s2 <= valid_s1;
            
            for (int i = 0; i < LANES; i++) begin
                // Weighted sum: each product is 16+8=24 bits max
                sum[i] <= (w00[i] * p00_r[i]) + (w01[i] * p01_r[i]) +
                          (w10[i] * p10_r[i]) + (w11[i] * p11_r[i]);
            end
        end
    end
    
    //=======================================================
    // Output valid assignment
    //=======================================================
    assign out_valid = valid_s2;

endmodule
