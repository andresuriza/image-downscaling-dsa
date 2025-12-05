module simd_downscaler #(
    parameter int LANES = 4,    
    parameter int Q     = 8     
) (
    input  logic clk,
    input  logic rst_n,

    // Control desde la FSM
    input  logic start,
    input  logic [31:0] in_width, in_height,
    input  logic [31:0] out_width, out_height,
    input  logic [31:0] scale_q8_8,
    
    // Estado
    output logic busy,
    output logic [31:0] progress,
    output logic [31:0] errors,

    // Métricas de rendimiento
    output logic [63:0] perf_flops,
    output logic [63:0] perf_mem_reads,
    output logic [63:0] perf_mem_writes,

    // Entradas de píxeles (SIMD)
    input  logic [LANES*8-1:0] p00_packed,
    input  logic [LANES*8-1:0] p01_packed,
    input  logic [LANES*8-1:0] p10_packed,
    input  logic [LANES*8-1:0] p11_packed,
    input  logic [LANES*Q-1:0] frac_x_packed,
    input  logic [LANES*Q-1:0] frac_y_packed,

    /// Resultado (SIMD)
    output logic [LANES*8-1:0] out_pixels_packed,
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
    
    // Etapa 1: registrar entradas y pesos
    logic [PIXEL_WIDTH-1:0] p00_r [LANES-1:0];
    logic [PIXEL_WIDTH-1:0] p01_r [LANES-1:0];
    logic [PIXEL_WIDTH-1:0] p10_r [LANES-1:0];
    logic [PIXEL_WIDTH-1:0] p11_r [LANES-1:0];
  
    logic [17:0] w00   [LANES-1:0];
    logic [17:0] w01   [LANES-1:0];
    logic [17:0] w10   [LANES-1:0];
    logic [17:0] w11   [LANES-1:0];
    
    // Etapa 2: acumulación ponderada
    logic [27:0] sum   [LANES-1:0];
    
    // Cálculo combinacional de pesos
    logic [Q:0]    fx_comb    [LANES-1:0]; 
    logic [Q:0]    fy_comb    [LANES-1:0];
    logic [Q:0]    inv_fx_comb[LANES-1:0];
    logic [Q:0]    inv_fy_comb[LANES-1:0];
    logic [2*Q+1:0] w00_comb  [LANES-1:0]; 
    logic [2*Q+1:0] w01_comb  [LANES-1:0];
    logic [2*Q+1:0] w10_comb  [LANES-1:0];
    logic [2*Q+1:0] w11_comb  [LANES-1:0];
    
    // Resultado por lane
    logic [PIXEL_WIDTH-1:0] out_pixel [LANES-1:0];
    
    // Simple status
    logic running;
    logic [31:0] produced;
    
    // Señales no usadas quedan en cero
    assign busy = running;
    assign errors = 32'd0;
    assign perf_mem_reads = 64'd0;
    assign perf_mem_writes = 64'd0;
    
    // Control general del módulo: inicio, avance y conteo FLOPs
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 1'b0;
            produced <= 32'd0;
            progress <= 32'd0;
            perf_flops <= 64'd0;
        end else begin
            // Inicia un nuevo procesamiento
            if (start && !running) begin
                running <= 1'b1;
                produced <= 32'd0;
            end
            
            // Contabilizar píxeles procesados (cuando la etapa 2 es válida)
            if (running && valid_s2) begin
                produced <= produced + LANES;
                progress <= produced + LANES;
                perf_flops <= perf_flops + (LANES * FLOPS_PER_PIXEL);
            end
            
            // Finaliza cuando se cubren los píxeles de salida
            if (running && (produced + LANES >= out_width * out_height)) begin
                running <= 1'b0;
            end
        end
    end
    
    // Cálculo de pesos bilineales combinacional
    genvar g;
    generate
        for (g = 0; g < LANES; g++) begin : weight_calc
            // Extraer fracciones Q
            assign fx_comb[g]     = {1'b0, frac_x_packed[g*Q +: Q]};
            assign fy_comb[g]     = {1'b0, frac_y_packed[g*Q +: Q]};
            assign inv_fx_comb[g] = (Q+1)'(ONE_Q) - fx_comb[g];
            assign inv_fy_comb[g] = (Q+1)'(ONE_Q) - fy_comb[g];
            
            // Complementos (1 - frac)
            assign w00_comb[g] = inv_fx_comb[g] * inv_fy_comb[g];
            assign w01_comb[g] = fx_comb[g] * inv_fy_comb[g];
            assign w10_comb[g] = inv_fx_comb[g] * fy_comb[g];
            assign w11_comb[g] = fx_comb[g] * fy_comb[g];
            
            // Redondeo del acumulador
            wire [27:0] sum_rounded = sum[g] + 28'h8000;
            // Saturación y recorte a 8 bits
            assign out_pixel[g] = (sum_rounded[27:24] != 4'd0) ? PIXEL_WIDTH'(MAX_PIXEL) : sum_rounded[23:16];
            // Empaquetar el resultado
            assign out_pixels_packed[g*PIXEL_WIDTH +: PIXEL_WIDTH] = out_pixel[g];
        end
    endgenerate
    
    // Etapa 1 del pipeline: registrar píxeles y pesos
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
            // Avanza la validez del pipeline
            valid_s1 <= start;
            
            for (int i = 0; i < LANES; i++) begin
                // Registrar píxeles vecinos
                p00_r[i] <= p00_packed[i*PIXEL_WIDTH +: PIXEL_WIDTH];
                p01_r[i] <= p01_packed[i*PIXEL_WIDTH +: PIXEL_WIDTH];
                p10_r[i] <= p10_packed[i*PIXEL_WIDTH +: PIXEL_WIDTH];
                p11_r[i] <= p11_packed[i*PIXEL_WIDTH +: PIXEL_WIDTH];
                
                // Registrar pesos normalizados
                w00[i] <= w00_comb[i][17:0];
                w01[i] <= w01_comb[i][17:0];
                w10[i] <= w10_comb[i][17:0];
                w11[i] <= w11_comb[i][17:0];
            end
        end
    end
    
    // Etapa 2 del pipeline: suma ponderada (MAC)
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
    
    // Ultima etapa
    assign out_valid = valid_s2;

endmodule
