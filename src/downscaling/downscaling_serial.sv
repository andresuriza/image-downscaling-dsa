module downscaling_serial #(
    parameter IMG_W = 8,
    parameter IMG_H = 8,
	parameter ratio = 1,
    parameter int OUT_W = ratio * IMG_W,
    parameter int OUT_H = ratio * IMG_H,
    parameter Q = 8,
    parameter int X_RATIO_Q = ((IMG_W-1) << Q) / (OUT_W-1),
    parameter int Y_RATIO_Q = ((IMG_H-1) << Q) / (OUT_H-1)
)(
    input  logic clk,
    input  logic rst_n,
    output logic done
);

    logic [7:0] img_in [0:IMG_H-1][0:IMG_W-1];
    logic [7:0] img_out [0:OUT_H-1][0:OUT_W-1];

    logic [OUT_W-1:0] out_x;
    logic [OUT_H-1:0] out_y;

    localparam logic [15:0] ONE_Q = 16'(1 << Q);

	 // Variables de interpolacion por pesos
    logic [15:0] one_fx, one_fy;
    logic [31:0] w00, w10, w01, w11;

    logic [31:0] pa, pb, pc, pd;
    logic [31:0] sum;
    logic [7:0]  res;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_x <= '0;
            out_y <= '0;
            done  <= 1'b0;
        end 
        else if (!done) begin
            logic [31:0] src_x_q, src_y_q;
            int x_l, x_h, y_l, y_h;
            logic [15:0] fx_q, fy_q;
            logic [7:0]  a, b, c, d;
            logic [7:0]  pix;

            src_x_q = X_RATIO_Q * out_x;
            src_y_q = Y_RATIO_Q * out_y;

            x_l = src_x_q >>> Q;
            y_l = src_y_q >>> Q;

            if (x_l < 0)         
                x_l = 0;

            if (y_l < 0)         
                y_l = 0;

            if (x_l > IMG_W-1)   
                x_l = IMG_W-1;

            if (y_l > IMG_H-1)   
                y_l = IMG_H-1;

            x_h = (x_l == IMG_W-1) ? IMG_W-1 : x_l + 1;
            y_h = (y_l == IMG_H-1) ? IMG_H-1 : y_l + 1;

            fx_q = src_x_q[15:0];
            fy_q = src_y_q[15:0];

            a = img_in[y_l][x_l];
            b = img_in[y_l][x_h];
            c = img_in[y_h][x_l];
            d = img_in[y_h][x_h];

            one_fx = ONE_Q - fx_q;
            one_fy = ONE_Q - fy_q;

            w00 = (one_fx * one_fy) >> Q;
            w10 = (fx_q   * one_fy) >> Q;
            w01 = (one_fx * fy_q  ) >> Q;
            w11 = (fx_q   * fy_q  ) >> Q;

            pa = w00 * a;
            pb = w10 * b;
            pc = w01 * c;
            pd = w11 * d;

            sum = pa + pb + pc + pd;

            sum = sum + (1 << (Q-1));
            res = sum >> Q;

            if (res > 8'd255)
                res = 8'd255;

            pix = res;

            img_out[out_y][out_x] <= pix;

            if (out_x == OUT_W-1) begin
                out_x <= '0;
                if (out_y == OUT_H-1) begin
                    done <= 1'b1;
                end 
                else begin
                    out_y <= out_y + 1;
                end
            end 
            else begin
                out_x <= out_x + 1;
            end
        end
    end

endmodule