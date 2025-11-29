module simd_downscaler #(
    parameter int LANES = 8,                 // SIMD width (must be > 4 by your constraint)
    parameter int Q = 8                       // fractional bits (Q8.8)
) (
    input  logic clk,
    input  logic rst_n,

    // Control registers (simple register write via TB or APB/AXI-MM in future)
    input  logic start,                       // start operation
    input  logic [31:0] in_width, in_height,
    input  logic [31:0] out_width, out_height,
    input  logic [31:0] scale_q8_8,           // Q8.8 scale factor: src = dst * (1/scale) OR we define scale = src/dst? (TB uses it consistently)
    input  logic [1:0] mode,                  // 0 = SIMD, 1 = serial (reserved)
    output logic busy,
    output logic [31:0] progress,             // output pixels produced
    output logic [31:0] errors,

    // Performance counters
    output logic [63:0] perf_flops,           // counts multiply-add ops
    output logic [63:0] perf_mem_reads,
    output logic [63:0] perf_mem_writes,

    // Input: per-lane neighbor pixels; each packed lane is 8 bits
    input  logic [LANES*8-1:0] p00_packed,    // pixel at (x0,y0) for each lane
    input  logic [LANES*8-1:0] p01_packed,    // (x1,y0)
    input  logic [LANES*8-1:0] p10_packed,    // (x0,y1)
    input  logic [LANES*8-1:0] p11_packed,    // (x1,y1)

    // Input: per-lane fractional weights in Q0.8 (0..255)
    input  logic [LANES*Q-1:0] frac_x_packed, // wx for each lane
    input  logic [LANES*Q-1:0] frac_y_packed, // wy for each lane

    // Output: packed result pixels (8 bits per lane)
    output logic [LANES*8-1:0] out_pixels_packed,
    output logic out_valid
);

    // sanity assert (simulation-only)
    // synopsys translate_off
    initial begin
        if (LANES <= 4) begin
            $warning("LANES should be > 4 for this design; current LANES=%0d", LANES);
        end
    end
    // synopsys translate_on

    // Internal registers
    logic running;
    logic [31:0] produced;

    // Counters
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 0;
            busy <= 0;
            produced <= 0;
            progress <= 0;
            errors <= 0;
            perf_flops <= 0;
            perf_mem_reads <= 0;
            perf_mem_writes <= 0;
        end else begin
            if (start && !running) begin
                running <= 1;
                busy <= 1;
                produced <= 0;
            end

            if (running) begin
                // produce one vector per cycle
                produced <= produced + LANES;
                progress <= produced + LANES;
                // update counters: each lane does (2 multiplies per top/bot row) + (2 multiplies for vertical blend) -> count as 4 mults and ~6 adds
                perf_flops <= perf_flops + (LANES * 4); // rough count for multiplies
            end

            // Simple stop condition: when produced >= out_width*out_height stop
            if (running && (produced + LANES >= out_width * out_height)) begin
                running <= 0;
                busy <= 0;
            end
        end
    end
	
// === PACKED SIMD TEMPORARIES ===
logic [LANES*16-1:0] res_q8_8;     // Q8.8 intermediate
logic [LANES*24-1:0] rounded;      // for rounding
logic [LANES*8 -1:0] finalpix;     // final clipped pixels


genvar gi;
generate
    for (gi = 0; gi < LANES; gi++) begin : LANE_COMPUTE

        // -------------------------------------------------------------
        // Extract 8-bit pixels and Q0.8 weights (all UNSIGNED)
        // -------------------------------------------------------------
        // per-lane locals (declared, then assigned via continuous assigns)
        logic [7:0] p00_l, p01_l, p10_l, p11_l;
        logic [Q-1:0] wx_l, wy_l;

        // continuous part-select assigns (gi is constant per instance)
        assign p00_l = p00_packed[8*gi +: 8];
        assign p01_l = p01_packed[8*gi +: 8];
        assign p10_l = p10_packed[8*gi +: 8];
        assign p11_l = p11_packed[8*gi +: 8];
        assign wx_l  = frac_x_packed[gi*Q +: Q];
        assign wy_l  = frac_y_packed[gi*Q +: Q];

        // Widened intermediates to avoid overflow from multiply-add chains
        logic [31:0] res_acc_l;                // full bilinear blend accumulation
        logic [31:0] round_q_l;                // sum + rounding (wider for safety)
        logic [7:0]  pix_l;
        logic [31:0] pix_temp;                 // temp before clipping

        // -------------------------------------------------------------
        // UNSIGNED arithmetic
        // -------------------------------------------------------------


        always_comb begin
            // Unsigned Q constants
            automatic int unsigned ONE_Q  = (1 << Q);      // e.g. 256 for Q8
            automatic int unsigned HALF_Q = (1 << (Q-1));  // e.g. 128 for Q8

            // Compute weights (pre-shift like C++ reference)
            logic [15:0] w00, w10, w01, w11;
            w00 = ((ONE_Q - wx_l) * (ONE_Q - wy_l)) >> Q;
            w10 = (wx_l * (ONE_Q - wy_l)) >> Q;
            w01 = ((ONE_Q - wx_l) * wy_l) >> Q;
            w11 = (wx_l * wy_l) >> Q;

            // Weighted sum
            res_acc_l = w00 * p00_l + w10 * p01_l + w01 * p10_l + w11 * p11_l;

            // Rounding
            round_q_l = res_acc_l + HALF_Q;

            // Convert to 8-bit integer
            pix_temp = (round_q_l >> Q);
            if (pix_temp > 32'd255)
                pix_l = 8'd255;
            else
                pix_l = pix_temp[7:0];

            // Store into packed output vectors
            res_q8_8 [gi*16 +: 16] = res_acc_l[15:0];
            rounded  [gi*24 +: 24] = round_q_l[23:0];
            finalpix [gi*8  +: 8 ] = pix_l;
            out_pixels_packed[gi*8 +: 8] = pix_l;
        end
    end
endgenerate

assign out_valid = running;


endmodule
