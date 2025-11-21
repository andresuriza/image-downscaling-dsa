module downscaling_simd #(
    parameter int W = 512,
    parameter int H = 512,
    parameter int NEW_W = 256,
    parameter int NEW_H = 256,
    parameter int FP = 8,
    parameter int LANES = 4
)(
    input  logic clk,
    input  logic rst,
    input  logic [7:0] bank_mem [LANES-1:0][H-1:0][ ((W + LANES-1)/LANES) - 1 : 0 ],
    output logic [7:0] pixel_out [LANES-1:0],
    output logic valid
);

    localparam int RFP_WIDTH = 16;
    logic [RFP_WIDTH-1:0] x_ratio_fp, y_ratio_fp;
    initial begin
        x_ratio_fp = ((W - 1) << FP) / (NEW_W - 1);
        y_ratio_fp = ((H - 1) << FP) / (NEW_H - 1);
    end

    logic [$clog2(NEW_W)-1 + 1:0] j_base;
    logic [$clog2(NEW_H)-1:0] i_cnt;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            j_base <= 0;
            i_cnt <= 0;
        end else begin
            if (j_base + LANES >= NEW_W) begin
                j_base <= 0;
                if (i_cnt == NEW_H - 1) i_cnt <= 0;
                else i_cnt <= i_cnt + 1;
            end else begin
                j_base <= j_base + LANES;
            end
        end
    end

    logic [LANES-1:0][RFP_WIDTH-1:0] x_fp;
    logic [LANES-1:0][RFP_WIDTH-1:0] y_fp;

    logic [LANES-1:0][$clog2(W)-1:0] x_l;
    logic [LANES-1:0][$clog2(W)-1:0] x_h;
    logic [LANES-1:0][$clog2(H)-1:0] y_l;
    logic [LANES-1:0][$clog2(H)-1:0] y_h;

    logic [LANES-1:0][FP-1:0] x_weight;
    logic [LANES-1:0][FP-1:0] y_weight;

    genvar lane;
    generate
        for (lane = 0; lane < LANES; lane++) begin : GEN_COORDS
            logic [$clog2(NEW_W)-1:0] j_lane;
            always_comb j_lane = j_base + lane;

            logic [RFP_WIDTH + $clog2(NEW_W) - 1 : 0] tmp_xfp;
            assign tmp_xfp = j_lane * x_ratio_fp;
            assign x_fp[lane] = tmp_xfp[RFP_WIDTH-1:0];

            logic [RFP_WIDTH + $clog2(NEW_H) - 1 : 0] tmp_yfp;
            assign tmp_yfp = i_cnt * y_ratio_fp;
            assign y_fp[lane] = tmp_yfp[RFP_WIDTH-1:0];

            assign x_l[lane] = x_fp[lane][RFP_WIDTH-1:FP];
            assign y_l[lane] = y_fp[lane][RFP_WIDTH-1:FP];

            always_comb begin
                if (x_l[lane] == W-1) x_h[lane] = x_l[lane];
                else                  x_h[lane] = x_l[lane] + 1;
                if (y_l[lane] == H-1) y_h[lane] = y_l[lane];
                else                  y_h[lane] = y_l[lane] + 1;
            end

            assign x_weight[lane] = x_fp[lane][FP-1:0];
            assign y_weight[lane] = y_fp[lane][FP-1:0];
        end
    endgenerate

    logic [LANES-1:0][7:0] a;
    logic [LANES-1:0][7:0] b;
    logic [LANES-1:0][7:0] c;
    logic [LANES-1:0][7:0] d;

    generate
        for (lane = 0; lane < LANES; lane++) begin : GEN_MEM_READ
            logic [$clog2((W+LANES-1)/LANES)-1:0] addr_xl, addr_xh;

            assign addr_xl = x_l[lane] / LANES;
            assign addr_xh = x_h[lane] / LANES;

            always_comb begin
                a[lane] = bank_mem[lane][y_l[lane]][addr_xl];
                b[lane] = bank_mem[lane][y_l[lane]][addr_xh];
                c[lane] = bank_mem[lane][y_h[lane]][addr_xl];
                d[lane] = bank_mem[lane][y_h[lane]][addr_xh];
            end
        end
    endgenerate

    localparam int ACCW = 8 + 2*FP + 8;
    logic [LANES-1:0][ACCW-1:0] term_a;
    logic [LANES-1:0][ACCW-1:0] term_b;
    logic [LANES-1:0][ACCW-1:0] term_c;
    logic [LANES-1:0][ACCW-1:0] term_d;
    logic [LANES-1:0][ACCW+4:0] sum_fp;

    generate
        for (lane = 0; lane < LANES; lane++) begin : GEN_MATH
            logic [FP-1:0] one_minus_xw, one_minus_yw;
            assign one_minus_xw = ({FP{1'b1}}) - x_weight[lane];
            assign one_minus_yw = ({FP{1'b1}}) - y_weight[lane];

            always_comb begin
                term_a[lane] = (a[lane] * one_minus_xw * one_minus_yw);
                term_b[lane] = (b[lane] * x_weight[lane] * one_minus_yw);
                term_c[lane] = (c[lane] * one_minus_xw * y_weight[lane]);
                term_d[lane] = (d[lane] * x_weight[lane] * y_weight[lane]);

                sum_fp[lane] = term_a[lane] + term_b[lane] + term_c[lane] + term_d[lane];
            end

            always_comb begin
                pixel_out[lane] = sum_fp[lane][2*FP + 7 : 2*FP];
            end
        end
    endgenerate

    assign valid = 1'b1;

endmodule