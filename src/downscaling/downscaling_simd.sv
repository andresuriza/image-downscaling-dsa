module downscaling_simd #(
    parameter WIDTH = 512,
    parameter HEIGHT = 512,
    parameter SCALE = 0.5,
    parameter int LANES = 4,
    parameter int OUT_W = WIDTH * SCALE,
    parameter int OUT_H = HEIGHT * SCALE
)(
    input logic clk,
    input logic rst,
    input logic [7:0] bank_mem[LANES-1:0][HEIGHT-1:0][(WIDTH+LANES-1)/LANES - 1:0],
    output logic [7:0] pixel_out[LANES-1:0]
);

    logic [15:0] x_ratio;
    logic [15:0] y_ratio;

	initial begin
        x_ratio = ((WIDTH - 1) << 8) / (OUT_W - 1);
        y_ratio = ((HEIGHT - 1) << 8) / (OUT_H - 1);
    end

    logic [$clog2(OUT_W) - 1 + 1:0] j;
    logic [$clog2(OUT_H) - 1:0] i;

    // Calculo de indices para division de trabajo por lanes
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            j <= 0;
            i <= 0;
        end

        else begin
            if (j + LANES >= OUT_W) begin
                j <= 0;

                if (i == OUT_H - 1) begin
                    i <= 0;
                end

                else begin
                    i <= i + 1;
                end
            end
            else begin
                j <= j + LANES;
            end
        end
    end

    logic [LANES-1:0][15:0] x;
    logic [LANES-1:0][15:0] y;


    // Variables para calculo de interpolacion
    logic [LANES-1:0][$clog2(WIDTH)-1:0] x_l;
    logic [LANES-1:0][$clog2(WIDTH)-1:0] x_h;
    logic [LANES-1:0][$clog2(WIDTH)-1:0] y_l;
    logic [LANES-1:0][$clog2(WIDTH)-1:0] y_h;

    logic [LANES-1:0][7:0] x_weight;
    logic [LANES-1:0][7:0] y_weight;

    genvar lane;

    // Calculo de variables de interpolacion en lanes
    generate
        for (lane = 0; lane < LANES; lane++) begin: coordinates
            logic [$clog2(OUT_W)-1:0] j_lane;
            always_comb begin
                j_lane = j + lane; 
            end

            logic [16 + $clog2(OUT_W) - 1:0] temp_x;
            assign temp_x = j_lane * x_ratio;
            assign x[lane] = temp_x[15:0];

            logic [16 + $clog2(OUT_H) - 1:0] temp_y;
            assign temp_y = i * y_ratio;
            assign y[lane] = temp_y[15:0];

            assign x_l[lane] = x[lane][15:8];
            assign y_l[lane] = y[lane][15:8];

            always_comb begin
                if (x_l[lane] == WIDTH - 1) begin
                    x_h[lane] = x_l[lane];
                end
                else begin
                    x_h[lane] = x_l[lane] + 1;
                end
                if (y_l[lane] == HEIGHT - 1) begin
                    y_h[lane] = y_l[lane];
                end
                else begin
                    y_h[lane] = y_l[lane] + 1;
                end
            end

            assign x_weight[lane] = x[lane][7:0];
            assign y_weight[lane] = y[lane][7:0];
        end
    endgenerate

    logic [LANES-1:0][7:0] a_lane;
    logic [LANES-1:0][7:0] b_lane;
    logic [LANES-1:0][7:0] c_lane;
    logic [LANES-1:0][7:0] d_lane;

    // Distribucion de pixeles de imagen a lanes de pixeles a,b,c,d
    generate
        for (lane = 0; lane < LANES; lane++) begin : read_mem
            logic [$clog2((WIDTH + LANES - 1)) / LANES - 1:0] addr_xl, addr_xh;

            assign addr_xl = x_l[lane] / LANES;
            assign addr_xh = x_h[lane] / LANES;

            always_comb begin
                a_lane[lane] = bank_mem[lane][y_l[lane]][addr_xl];
                b_lane[lane] = bank_mem[lane][y_l[lane]][addr_xh];
                c_lane[lane] = bank_mem[lane][y_h[lane]][addr_xl];
                d_lane[lane] = bank_mem[lane][y_h[lane]][addr_xh];
            end
        end
    endgenerate

    // 16 bits de Q8.8
    localparam int ACCW = 32;

    logic [LANES-1:0][ACCW-1:0] a;
    logic [LANES-1:0][ACCW-1:0] b;
    logic [LANES-1:0][ACCW-1:0] c;
    logic [LANES-1:0][ACCW-1:0] d;
    logic [LANES-1:0][ACCW+4:0] sum;

    // Calculo final de pesos de interpolacion con punto fijo contemplado
    generate
        for (lane = 0; lane < LANES; lane++) begin : interpolation
            logic [7:0] one_minus_x, one_minus_y;
            assign one_minus_x = (({8{1'b1}}) - x_weight[lane]);
            assign one_minus_y = (({8{1'b1}}) - y_weight[lane]);

            always_comb begin
                a[lane] = (a_lane[lane] * one_minus_x * one_minus_y);
                b[lane] = (b_lane[lane] * x_weight[lane] * one_minus_y);
                c[lane] = (c_lane[lane] * one_minus_x * y_weight[lane]);
                d[lane] = (d_lane[lane] * x_weight[lane] * y_weight[lane]);

                sum[lane] = a[lane] + b[lane] + c[lane] + d[lane];
            end

            always_comb begin
                pixel_out[lane] = sum[lane][23:16];
            end
        end
    endgenerate

endmodule