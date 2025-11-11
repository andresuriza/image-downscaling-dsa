// ======================================================================
// Downscaling bilineal secuencial - versión mínima para Avance 3
// - 1 pixel de salida por ciclo
// - Sin start, sin case: al salir de reset procesa todo y luego done=1
// - Formato fijo único: Q8.8 para ratios y fracciones
// ======================================================================

module downscaling #(
    parameter int IMG_W = 8,
    parameter int IMG_H = 8,
    parameter int OUT_W = 4,
    parameter int OUT_H = 4,
    parameter int Q     = 8,  // Q8.8

    // Ratios fijos en Q8.8: (IMG_W-1)/(OUT_W-1) y (IMG_H-1)/(OUT_H-1)
    parameter int X_RATIO_Q = ((IMG_W-1) << Q) / (OUT_W-1),
    parameter int Y_RATIO_Q = ((IMG_H-1) << Q) / (OUT_H-1)
)(
    input  logic clk,
    input  logic rst_n,
    output logic done
);

    // Imagen de entrada (modelo simple, luego se puede mapear a BRAM o puertos)
    logic [7:0] img_in  [0:IMG_H-1][0:IMG_W-1];

    // Imagen de salida reducida
    logic [7:0] img_out [0:OUT_H-1][0:OUT_W-1];

    // Coordenadas de salida
    logic [$clog2(OUT_W)-1:0] out_x;
    logic [$clog2(OUT_H)-1:0] out_y;

    // Constante 1.0 en Q8.8
    localparam logic [15:0] ONE_Q = 16'(1 << Q);

    // ------------------------------------------------------------------
    // Función bilineal en Q8.8, versión compacta
    // ------------------------------------------------------------------
    function automatic logic [7:0] bilinear_q88 (
        input logic [7:0] a,
        input logic [7:0] b,
        input logic [7:0] c,
        input logic [7:0] d,
        input logic [15:0] fx_q,   // Q8.8
        input logic [15:0] fy_q    // Q8.8
    );
        // pesos
        logic [15:0] one_fx, one_fy;
        logic [31:0] w00, w10, w01, w11;
        // productos
        logic [31:0] pa, pb, pc, pd;
        logic [31:0] sum;
        logic [7:0]  res;
        begin
            one_fx = ONE_Q - fx_q;
            one_fy = ONE_Q - fy_q;

            // Pesos: (Q8.8 * Q8.8) >> 8 -> Q8.8
            w00 = (one_fx * one_fy) >> Q;
            w10 = (fx_q   * one_fy) >> Q;
            w01 = (one_fx * fy_q  ) >> Q;
            w11 = (fx_q   * fy_q  ) >> Q;

            // peso * pixel: Q8.8 * U8.0 -> ~Q16.8
            pa = w00 * a;
            pb = w10 * b;
            pc = w01 * c;
            pd = w11 * d;

            sum = pa + pb + pc + pd;

            // Pasar de Q8.8 aprox a entero con redondeo
            sum = sum + (1 << (Q-1));
            res = sum >> Q;

            // Saturación de seguridad
            if (res > 8'd255)
                res = 8'd255;

            bilinear_q88 = res;
        end
    endfunction

    // ------------------------------------------------------------------
    // Lógica secuencial mínima:
    // - Mientras done=0, en cada ciclo calcula 1 pixel de salida.
    // - Cuando se llena OUT_H x OUT_W, pone done=1 y se detiene.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_x <= '0;
            out_y <= '0;
            done  <= 1'b0;
        end else if (!done) begin
            // Coordenadas fuente en Q8.8
            logic [31:0] src_x_q, src_y_q;
            int x_l, x_h, y_l, y_h;
            logic [15:0] fx_q, fy_q;
            logic [7:0]  a, b, c, d;
            logic [7:0]  pix;

            src_x_q = X_RATIO_Q * out_x;   // Q8.8 * entero
            src_y_q = Y_RATIO_Q * out_y;

            // Parte entera (floor)
            x_l = src_x_q >>> Q;
            y_l = src_y_q >>> Q;

            // Clamp
            if (x_l < 0)         x_l = 0;
            if (y_l < 0)         y_l = 0;
            if (x_l > IMG_W-1)   x_l = IMG_W-1;
            if (y_l > IMG_H-1)   y_l = IMG_H-1;

            // Vecinos ceil (con bordes)
            x_h = (x_l == IMG_W-1) ? IMG_W-1 : x_l + 1;
            y_h = (y_l == IMG_H-1) ? IMG_H-1 : y_l + 1;

            // Fracciones en Q8.8 = parte baja
            fx_q = src_x_q[15:0];
            fy_q = src_y_q[15:0];

            // Leer vecinos
            a = img_in[y_l][x_l];
            b = img_in[y_l][x_h];
            c = img_in[y_h][x_l];
            d = img_in[y_h][x_h];

            // Bilineal
            pix = bilinear_q88(a,b,c,d, fx_q, fy_q);

            // Guardar en salida
            img_out[out_y][out_x] <= pix;

            // Avanzar al siguiente pixel de salida
            if (out_x == OUT_W-1) begin
                out_x <= '0;
                if (out_y == OUT_H-1) begin
                    done <= 1'b1;    // último pixel: terminamos
                end else begin
                    out_y <= out_y + 1;
                end
            end else begin
                out_x <= out_x + 1;
            end
        end
        // Si done=1, no se hace nada más (el módulo "terminó").
    end

endmodule