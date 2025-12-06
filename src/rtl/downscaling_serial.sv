// Interpolación bilineal serial
// 1 píxel por ciclo, pipeline de 3 etapas

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

    // Constantes de formato fijo Q y píxeles
    localparam int PIXEL_WIDTH = 8;
    localparam int ONE_Q       = (1 << Q);
    localparam int HALF_Q      = (1 << (Q-1));
    localparam int MAX_PIXEL   = (1 << PIXEL_WIDTH) - 1;
    localparam int FLOPS_PER_PIXEL = 8;

    // Registros del pipeline
    logic valid_s1, valid_s2;
    
    // Etapa 1: píxeles y pesos
    logic [PIXEL_WIDTH-1:0] p00_r, p01_r, p10_r, p11_r;
    logic [17:0] w00, w01, w10, w11;
    
    // Etapa 2: acumulación
    logic [27:0] sum;
    
    // Cálculo combinacional de pesos
    logic [Q:0]     fx_comb, fy_comb;
    logic [Q:0]     inv_fx_comb, inv_fy_comb;
    logic [2*Q+1:0] w00_comb, w01_comb, w10_comb, w11_comb;
    
    // Resultado
    logic [PIXEL_WIDTH-1:0] out_pixel_comb;
    
    // Control del módulo
    logic running;
    logic [31:0] produced;
    
    // Señales no usadas
    assign busy = running;
    assign errors = 32'd0;
    assign perf_mem_reads = 64'd0;
    assign perf_mem_writes = 64'd0;
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
                produced <= produced + 1;
                progress <= produced + 1;
                perf_flops <= perf_flops + FLOPS_PER_PIXEL;
            end
            
            if (running && (produced + 1 >= out_width * out_height)) begin
                running <= 1'b0;
            end
        end
    end
    
    // Cálculo de pesos bilineales
    assign fx_comb     = {1'b0, frac_x};
    assign fy_comb     = {1'b0, frac_y};
    assign inv_fx_comb = (Q+1)'(ONE_Q) - fx_comb;
    assign inv_fy_comb = (Q+1)'(ONE_Q) - fy_comb;
    
    assign w00_comb = inv_fx_comb * inv_fy_comb;
    assign w01_comb = fx_comb * inv_fy_comb;
    assign w10_comb = inv_fx_comb * fy_comb;
    assign w11_comb = fx_comb * fy_comb;
    
    // Redondeo y saturación
    wire [27:0] sum_rounded = sum + 28'h8000;
    assign out_pixel_comb = (sum_rounded[27:24] != 4'd0) ? MAX_PIXEL[7:0] : sum_rounded[23:16];
    assign out_pixel = out_pixel_comb;
    
    // Etapa 1: registrar entradas y pesos
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
            
            p00_r <= p00;
            p01_r <= p01;
            p10_r <= p10;
            p11_r <= p11;
            
            w00 <= w00_comb[17:0];
            w01 <= w01_comb[17:0];
            w10 <= w10_comb[17:0];
            w11 <= w11_comb[17:0];
        end
    end
    
    // Etapa 2: suma ponderada (MAC)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s2 <= 1'b0;
            sum <= 28'd0;
        end else begin
            valid_s2 <= valid_s1;
            
            sum <= (w00 * p00_r) + (w01 * p01_r) +
                   (w10 * p10_r) + (w11 * p11_r);
        end
    end
    
    // Salida válida
    assign out_valid = valid_s2;

endmodule