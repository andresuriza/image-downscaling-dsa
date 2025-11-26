// Top-level module for FPGA synthesis
module fpga_top (
    input logic clk,
    input logic rst_n,
    input logic start,
    output logic done
);

    // Parameters for a 512x512 -> 256x256 downscale
    localparam IN_W = 512;
    localparam IN_H = 512;
    localparam OUT_W = 256;
    localparam OUT_H = 256;
    localparam LANES = 8;
    localparam Q = 8;

    // BRAM for input and output images
    (* syn_ramstyle = "block_ram" *) logic [7:0] img_in[IN_H-1:0][IN_W-1:0];
    (* syn_ramstyle = "block_ram" *) logic [7:0] img_out[OUT_H-1:0][OUT_W-1:0];

    // Wires for DUT interface
    logic [31:0] in_width_w, in_height_w;
    logic [31:0] out_width_w, out_height_w;
    logic [31:0] scale_q8_8_w;
    logic [1:0]  mode_w;
    logic        busy_w;
    logic [LANES*8-1:0] p00_w, p01_w, p10_w, p11_w;
    logic [LANES*Q-1:0] fracx_w, fracy_w;
    logic [LANES*8-1:0] out_vec_w;
    logic        out_valid_w;

    // Instantiate the downscaler
    simd_downscaler #(.LANES(LANES), .Q(Q)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start),
        .in_width(in_width_w), .in_height(in_height_w),
        .out_width(out_width_w), .out_height(out_height_w),
        .scale_q8_8(scale_q8_8_w),
        .mode(mode_w),
        .busy(busy_w),
        .progress(), .errors(), .perf_flops(), .perf_mem_reads(), .perf_mem_writes(), // Unused outputs
        .p00_packed(p00_w),
        .p01_packed(p01_w),
        .p10_packed(p10_w),
        .p11_packed(p11_w),
        .frac_x_packed(fracx_w),
        .frac_y_packed(fracy_w),
        .out_pixels_packed(out_vec_w),
        .out_valid(out_valid_w)
    );

    // --- Control Logic ---
    assign in_width_w  = IN_W;
    assign in_height_w = IN_H;
    assign out_width_w = OUT_W;
    assign out_height_w = OUT_H;
    assign mode_w = 0; // SIMD mode

    // Compute fixed-point Q8 scale: (width-1)/(out_w-1) * 256
    assign scale_q8_8_w = ((IN_W - 1) * 256) / (OUT_W - 1);
    
    // FSM to drive the DUT
    typedef enum logic [1:0] {IDLE, RUN, FINISH} state_t;
    state_t state, next_state;

    integer out_pixel_count;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            out_pixel_count <= 0;
        end else begin
            state <= next_state;
            if (state == RUN) begin
                out_pixel_count <= out_pixel_count + LANES;
            end else if (state == IDLE) begin
                out_pixel_count <= 0;
            end
        end
    end

    always_comb begin
        next_state = state;
        done = 0;
        case(state)
            IDLE: begin
                if (start) next_state = RUN;
            end
            RUN: begin
                if (out_pixel_count + LANES >= OUT_W * OUT_H) begin
                    next_state = FINISH;
                end
            end
            FINISH: begin
                done = 1;
                next_state = IDLE;
            end
        endcase
    end
    
    // --- Data Path Logic ---

    // Read logic to drive the DUT inputs
    always_comb begin
        for (integer lane = 0; lane < LANES; lane = lane + 1) begin
            integer pix_idx, ox, oy, x0, x1, y0, y1;
            logic [7:0] fx, fy;
            integer scaled_x_fp, scaled_y_fp;
            pix_idx = out_pixel_count + lane;
            ox = pix_idx % OUT_W;
            oy = pix_idx / OUT_W;

            if (oy < OUT_H) begin
                scaled_x_fp = ox * scale_q8_8_w;
                scaled_y_fp = oy * scale_q8_8_w;
                x0 = scaled_x_fp >>> Q;
                y0 = scaled_y_fp >>> Q;
                x1 = (x0 + 1 < IN_W) ? x0 + 1 : x0;
                y1 = (y0 + 1 < IN_H) ? y0 + 1 : y0;
                fx = scaled_x_fp[Q-1:0];
                fy = scaled_y_fp[Q-1:0];
                
                p00_w[8*lane +:8] = img_in[y0][x0];
                p01_w[8*lane +:8] = img_in[y0][x1];
                p10_w[8*lane +:8] = img_in[y1][x0];
                p11_w[8*lane +:8] = img_in[y1][x1];
                fracx_w[lane*Q +:Q] = fx;
                fracy_w[lane*Q +:Q] = fy;
            end else begin
                p00_w[8*lane +:8] = 0;
                p01_w[8*lane +:8] = 0;
                p10_w[8*lane +:8] = 0;
                p11_w[8*lane +:8] = 0;
                fracx_w[lane*Q +:Q] = 0;
                fracy_w[lane*Q +:Q] = 0;
            end
        end
    end

    // Write logic to capture DUT output
    integer write_pixel_count;
    always_ff @(posedge clk) begin
        if (state == IDLE) begin
            write_pixel_count <= 0;
        end else if (out_valid_w) begin
            for (integer lane = 0; lane < LANES; lane = lane + 1) begin
                integer pix_idx, ox, oy;
                pix_idx = write_pixel_count + lane;
                ox = pix_idx % OUT_W;
                oy = pix_idx / OUT_W;
                if (oy < OUT_H) begin
                    img_out[oy][ox] <= out_vec_w[8*lane +: 8];
                end
            end
            write_pixel_count <= write_pixel_count + LANES;
        end
    end

    // Temporary: Load initial image data into BRAM (for synthesis)
    // In a real application, this would come from a different interface (e.g., SD card, camera)
    initial begin
        for (int y = 0; y < IN_H; y++) begin
            for (int x = 0; x < IN_W; x++) begin
                img_in[y][x] = ((x * 64 + y * 32) & 8'hFF);
            end
        end
    end

endmodule
