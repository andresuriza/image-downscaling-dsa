module pixel_fetch_fsm #(
    parameter int LANES      = 4,
    parameter int Q          = 8,
    parameter int MAX_WIDTH  = 2048,
    parameter int MAX_HEIGHT = 2048
) (
    input  logic        clk,
    input  logic        rst_n,
    
    // Control
    input  logic        start,
    input  logic        abort,
    input  logic [31:0] in_width,
    input  logic [31:0] in_height,
    input  logic [31:0] out_width,
    input  logic [31:0] out_height,
    input  logic [31:0] scale_q8_8,
    input  logic [1:0]  mode,
    input  logic [31:0] img_in_addr,
    input  logic [31:0] img_out_addr,
    input  logic        step_enable,
    input  logic        step_once,
    
    // Status
    output logic        busy,
    output logic        done,
    output logic [31:0] progress,
    output logic [31:0] errors,
    output logic [63:0] perf_mem_reads,
    output logic [63:0] perf_mem_writes,
    output logic [63:0] perf_pixel_reuse,
    
    // Debug - common
    output logic [3:0]  dbg_fsm_state,
    output logic [15:0] dbg_out_x,
    output logic [15:0] dbg_out_y,
    output logic [2:0]  dbg_batch_size,
    
    // Debug 
    output logic [15:0] dbg_src_x_int,
    output logic [15:0] dbg_src_y_int,
    output logic [Q-1:0] dbg_frac_x,
    output logic [Q-1:0] dbg_frac_y,
    output logic [7:0]  dbg_p00, dbg_p01, dbg_p10, dbg_p11,
    
    // Debug - lanes 1-3 (empaquetados como arrays)
    output logic [15:0] dbg_lane1_src_x, dbg_lane1_src_y,
    output logic [7:0]  dbg_lane1_frac_x, dbg_lane1_frac_y,
    output logic [7:0]  dbg_lane1_p00, dbg_lane1_p01, dbg_lane1_p10, dbg_lane1_p11,
    
    output logic [15:0] dbg_lane2_src_x, dbg_lane2_src_y,
    output logic [7:0]  dbg_lane2_frac_x, dbg_lane2_frac_y,
    output logic [7:0]  dbg_lane2_p00, dbg_lane2_p01, dbg_lane2_p10, dbg_lane2_p11,
    
    output logic [15:0] dbg_lane3_src_x, dbg_lane3_src_y,
    output logic [7:0]  dbg_lane3_frac_x, dbg_lane3_frac_y,
    output logic [7:0]  dbg_lane3_p00, dbg_lane3_p01, dbg_lane3_p10, dbg_lane3_p11,
    
    // SDRAM Master
    output logic [31:0] sdram_address,
    output logic        sdram_read,
    output logic        sdram_write,
    output logic [15:0] sdram_writedata,
    input  logic [15:0] sdram_readdata,
    input  logic        sdram_waitrequest,
    input  logic        sdram_readdatavalid,
    output logic [1:0]  sdram_byteenable,
    
    output logic [LANES*8-1:0] p00_packed,
    output logic [LANES*8-1:0] p01_packed,
    output logic [LANES*8-1:0] p10_packed,
    output logic [LANES*8-1:0] p11_packed,
    output logic [LANES*Q-1:0] frac_x_packed,
    output logic [LANES*Q-1:0] frac_y_packed,
    output logic               pixels_valid,
    input  logic [LANES*8-1:0] result_pixels,
    input  logic               result_valid
);

    // Estados de la FSM principal
    typedef enum logic [3:0] {
        S_IDLE       = 4'd0,
        S_COMPUTE    = 4'd1,
        S_FETCH      = 4'd2,
        S_PROCESS    = 4'd3,
        S_WRITE      = 4'd4,
        S_NEXT       = 4'd5,
        S_DONE       = 4'd6,
        S_WAIT_STEP  = 4'd7
    } state_t;
    
    state_t state;
    
    localparam MODE_SIMD   = 2'd0;
    localparam MODE_SERIAL = 2'd1;
    
    // Coordenadas de salida actuales
    logic [15:0] out_x, out_y;
    logic [2:0]  batch_size;
    logic [2:0]  batch_idx;
    
    // Coordenadas fuente por lane
    logic [15:0] lane_src_x_int [LANES-1:0];
    logic [15:0] lane_src_y_int [LANES-1:0];
    logic [7:0]  lane_frac_x    [LANES-1:0];
    logic [7:0]  lane_frac_y    [LANES-1:0];
    logic        lane_valid     [LANES-1:0];
    
    // Píxeles vecinos por lane
    logic [7:0] lane_p00 [LANES-1:0];
    logic [7:0] lane_p01 [LANES-1:0];
    logic [7:0] lane_p10 [LANES-1:0];
    logic [7:0] lane_p11 [LANES-1:0];
    
    // Control de lectura de píxeles
    logic [2:0] fetch_lane;
    logic [1:0] fetch_phase;
    logic       read_pending;
    logic       write_pending;
    
    // Reuso entre batches
    logic [15:0] prev_src_x_int;
    logic [15:0] prev_src_y_int;
    logic        prev_valid;
    logic [7:0]  prev_p01, prev_p11;
    
    // Flags de detección de reuso
    logic        do_full_reuse;
    logic        do_partial_reuse;
    logic [7:0]  pixel_data;
    
    // Control del pipeline
    logic        process_started;
    logic [1:0]  process_countdown;
    
    // Cálculo de coordenadas fuente (combinacional)
    logic [31:0] dividend_x, dividend_y;
    logic [31:0] src_coord_x_q8, src_coord_y_q8;
    
    assign dividend_x = {out_x, 16'd0};
    assign dividend_y = {out_y, 16'd0};
    assign src_coord_x_q8 = (scale_q8_8[15:0] != 0) ? (dividend_x / scale_q8_8[15:0]) : 32'd0;
    assign src_coord_y_q8 = (scale_q8_8[15:0] != 0) ? (dividend_y / scale_q8_8[15:0]) : 32'd0;
    
    // Coordenadas por lane
    logic [31:0] lane_dividend_x [LANES-1:0];
    logic [31:0] lane_src_coord_x_q8 [LANES-1:0];
    
    genvar gi;
    generate
        for (gi = 0; gi < LANES; gi++) begin : lane_coord_calc
            assign lane_dividend_x[gi] = {out_x + gi[15:0], 16'd0};
            assign lane_src_coord_x_q8[gi] = (scale_q8_8[15:0] != 0) ? 
                                             (lane_dividend_x[gi] / scale_q8_8[15:0]) : 32'd0;
        end
    endgenerate
    
    // Direcciones de memoria
    logic [31:0] addr_fetch;
    logic [31:0] addr_write;
    logic [31:0] x0_fetch, y0_fetch, x1_fetch, y1_fetch;
    
    // Coordenadas del lane actual
    wire [15:0] cur_src_x = lane_src_x_int[fetch_lane];
    wire [15:0] cur_src_y = lane_src_y_int[fetch_lane];
    
    // Clamp de coordenadas
    wire [31:0] x0_raw = {16'd0, cur_src_x};
    wire [31:0] y0_raw = {16'd0, cur_src_y};
    assign x0_fetch = (x0_raw >= in_width) ? in_width - 32'd1 : x0_raw;
    assign y0_fetch = (y0_raw >= in_height) ? in_height - 32'd1 : y0_raw;
    assign x1_fetch = (x0_fetch + 1 < in_width) ? x0_fetch + 32'd1 : in_width - 32'd1;
    assign y1_fetch = (y0_fetch + 1 < in_height) ? y0_fetch + 32'd1 : in_height - 32'd1;
    
    // Dirección de lectura según fase
    always_comb begin
        case (fetch_phase)
            2'd0: addr_fetch = img_in_addr + y0_fetch * in_width + x0_fetch;
            2'd1: addr_fetch = img_in_addr + y0_fetch * in_width + x1_fetch;
            2'd2: addr_fetch = img_in_addr + y1_fetch * in_width + x0_fetch;
            2'd3: addr_fetch = img_in_addr + y1_fetch * in_width + x1_fetch;
        endcase
    end
    
    // Dirección de escritura
    assign addr_write = img_out_addr + {16'd0, out_y} * out_width + {16'd0, out_x} + {29'd0, batch_idx};
    
    // FSM principal del módulo
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset
            state <= S_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            progress <= 32'd0;
            errors <= 32'd0;
            perf_mem_reads <= 64'd0;
            perf_mem_writes <= 64'd0;
            perf_pixel_reuse <= 64'd0;
            out_x <= 16'd0;
            out_y <= 16'd0;
            batch_size <= 3'd1;
            batch_idx <= 3'd0;
            fetch_lane <= 3'd0;
            fetch_phase <= 2'd0;
            read_pending <= 1'b0;
            write_pending <= 1'b0;
            sdram_read <= 1'b0;
            sdram_write <= 1'b0;
            pixels_valid <= 1'b0;
            process_started <= 1'b0;
            process_countdown <= 2'd0;
            prev_valid <= 1'b0;
            prev_src_x_int <= 16'd0;
            prev_src_y_int <= 16'd0;
            prev_p01 <= 8'd0;
            prev_p11 <= 8'd0;
            for (int i = 0; i < LANES; i++) begin
                lane_src_x_int[i] <= 16'd0;
                lane_src_y_int[i] <= 16'd0;
                lane_frac_x[i] <= 8'd0;
                lane_frac_y[i] <= 8'd0;
                lane_valid[i] <= 1'b0;
                lane_p00[i] <= 8'd0;
                lane_p01[i] <= 8'd0;
                lane_p10[i] <= 8'd0;
                lane_p11[i] <= 8'd0;
            end
        end else if (abort) begin
            // Abortar operación
            state <= S_IDLE;
            busy <= 1'b0;
            read_pending <= 1'b0;
            write_pending <= 1'b0;
            sdram_read <= 1'b0;
            sdram_write <= 1'b0;
            pixels_valid <= 1'b0;
            prev_valid <= 1'b0;
        end else begin
            done <= 1'b0;
            
            case (state)
                S_IDLE: begin
                    // Inactivo
                    busy <= 1'b0;
                    pixels_valid <= 1'b0;
                    sdram_read <= 1'b0;
                    sdram_write <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        out_x <= 16'd0;
                        out_y <= 16'd0;
                        progress <= 32'd0;
                        perf_mem_reads <= 64'd0;
                        perf_mem_writes <= 64'd0;
                        perf_pixel_reuse <= 64'd0;
                        prev_valid <= 1'b0;
             
                        state <= S_COMPUTE;
                    end
                end
                
                // Calcular coordenadas fuente y batch
                S_COMPUTE: begin
                    sdram_read <= 1'b0;
                    sdram_write <= 1'b0;
                    read_pending <= 1'b0;
                    
                    if (mode == MODE_SERIAL) begin
                        // Modo serial: 1 píxel
                        batch_size <= 3'd1;
                        lane_valid[0] <= 1'b1;
                        lane_valid[1] <= 1'b0;
                        lane_valid[2] <= 1'b0;
                        lane_valid[3] <= 1'b0;
                    end else begin
                        // Modo SIMD: hasta 4 píxeles
                        if (out_x + 4 <= out_width[15:0]) begin
                            batch_size <= 3'd4;
                            lane_valid[0] <= 1'b1;
                            lane_valid[1] <= 1'b1;
                            lane_valid[2] <= 1'b1;
                            lane_valid[3] <= 1'b1;
                        end else if (out_x + 3 <= out_width[15:0]) begin
                            batch_size <= 3'd3;
                            lane_valid[0] <= 1'b1;
                            lane_valid[1] <= 1'b1;
                            lane_valid[2] <= 1'b1;
                            lane_valid[3] <= 1'b0;
                        end else if (out_x + 2 <= out_width[15:0]) begin
                            batch_size <= 3'd2;
                            lane_valid[0] <= 1'b1;
                            lane_valid[1] <= 1'b1;
                            lane_valid[2] <= 1'b0;
                            lane_valid[3] <= 1'b0;
                        end else begin
                            batch_size <= 3'd1;
                            lane_valid[0] <= 1'b1;
                            lane_valid[1] <= 1'b0;
                            lane_valid[2] <= 1'b0;
                            lane_valid[3] <= 1'b0;
                        end
                    end
                    
                    // Calcular coordenadas para todos los lanes
                    for (int i = 0; i < LANES; i++) begin
                        lane_src_x_int[i] <= lane_src_coord_x_q8[i][23:8];
                        lane_src_y_int[i] <= src_coord_y_q8[23:8];
                        lane_frac_x[i] <= lane_src_coord_x_q8[i][7:0];
                        lane_frac_y[i] <= src_coord_y_q8[7:0];
                    end
                    
                    // Verificar reuso del batch anterior en lane 0
                    if (prev_valid && 
                        (lane_src_coord_x_q8[0][23:8] == prev_src_x_int + 16'd1) &&
                        (src_coord_y_q8[23:8] == prev_src_y_int)) begin
                        lane_p00[0] <= prev_p01;
                        lane_p10[0] <= prev_p11;
                        perf_pixel_reuse <= perf_pixel_reuse + 1;
                    end
                    
                    fetch_lane <= 3'd0;
                    fetch_phase <= 2'd0;
                    state <= S_FETCH;
                end
                
                // Leer píxeles vecinos de SDRAM
                S_FETCH: begin
                    if (fetch_lane >= batch_size) begin
                        // Todos los lanes leídos
                        state <= S_PROCESS;
                        process_started <= 1'b0;
                        process_countdown <= 2'd3;
                    end else if (!lane_valid[fetch_lane]) begin
                        // Saltar lanes inválidos
                        fetch_lane <= fetch_lane + 1;
                        fetch_phase <= 2'd0;
                    end else if (!read_pending) begin
                        // Verificar reuso dentro del batch
                        do_full_reuse = 1'b0;
                        do_partial_reuse = 1'b0;
                        
                        if (fetch_lane > 0 && fetch_phase == 2'd0) begin
                            // Mismo píxel fuente que lane anterior
                            if (lane_src_x_int[fetch_lane] == lane_src_x_int[fetch_lane-1] &&
                                lane_src_y_int[fetch_lane] == lane_src_y_int[fetch_lane-1]) begin
                                // Reuso completo
                                lane_p00[fetch_lane] <= lane_p00[fetch_lane-1];
                                lane_p01[fetch_lane] <= lane_p01[fetch_lane-1];
                                lane_p10[fetch_lane] <= lane_p10[fetch_lane-1];
                                lane_p11[fetch_lane] <= lane_p11[fetch_lane-1];
                                do_full_reuse = 1'b1;
                                perf_pixel_reuse <= perf_pixel_reuse + 1;
                            end else if (lane_src_x_int[fetch_lane] == lane_src_x_int[fetch_lane-1] + 16'd1 &&
                                         lane_src_y_int[fetch_lane] == lane_src_y_int[fetch_lane-1]) begin
                                // Píxel adyacente: reuso parcial
                                lane_p00[fetch_lane] <= lane_p01[fetch_lane-1];
                                lane_p10[fetch_lane] <= lane_p11[fetch_lane-1];
                                do_partial_reuse = 1'b1;
                            end
                        end else if (fetch_lane == 0 && fetch_phase == 2'd0 && prev_valid &&
                                     lane_src_x_int[0] == prev_src_x_int + 16'd1 &&
                                     lane_src_y_int[0] == prev_src_y_int) begin
                            // Reuso parcial de batch anterior
                            do_partial_reuse = 1'b1;
                        end
                        
                        if (do_full_reuse) begin
                            // Avanzar al siguiente lane
                            fetch_lane <= fetch_lane + 1;
                            fetch_phase <= 2'd0;
                        end else if (do_partial_reuse && fetch_phase == 2'd0) begin
                            // Saltar fase 0
                            fetch_phase <= 2'd1;
                        end else begin
                            // Emitir lectura SDRAM
                            sdram_read <= 1'b1;
                            sdram_byteenable <= 2'b11;
                            sdram_address <= {addr_fetch[31:1], 1'b0};
                            if (!sdram_waitrequest) begin
                                read_pending <= 1'b1;
                                sdram_read <= 1'b0;
                            end
                        end
                    end else begin
                        sdram_read <= 1'b0;
                    end
                    
                    // Procesar datos recibidos
                    if (sdram_readdatavalid) begin
                        perf_mem_reads <= perf_mem_reads + 1;
                        read_pending <= 1'b0;
                        
                        // Extraer byte del píxel
                        pixel_data = addr_fetch[0] ? sdram_readdata[15:8] : sdram_readdata[7:0];
                        
                        case (fetch_phase)
                            2'd0: lane_p00[fetch_lane] <= pixel_data;
                            2'd1: lane_p01[fetch_lane] <= pixel_data;
                            2'd2: lane_p10[fetch_lane] <= pixel_data;
                            2'd3: lane_p11[fetch_lane] <= pixel_data;
                        endcase
                        
                        // Avanzar fase/lane
                        if (fetch_phase == 2'd3) begin
                            if (fetch_lane + 1 >= batch_size) begin
                                state <= S_PROCESS;
                                process_started <= 1'b0;
                                process_countdown <= 2'd3;
                            end else begin
                                fetch_lane <= fetch_lane + 1;
                                fetch_phase <= 2'd0;
                            end
                        end else begin
                            // Verificar si saltar p10
                            if (fetch_phase == 2'd1) begin
                                // Reuso parcial: saltar p10
                                if (fetch_lane > 0 &&
                                    lane_src_x_int[fetch_lane] == lane_src_x_int[fetch_lane-1] + 16'd1 &&
                                    lane_src_y_int[fetch_lane] == lane_src_y_int[fetch_lane-1]) begin
                                    fetch_phase <= 2'd3;
                                end else if (fetch_lane == 0 && prev_valid &&
                                             lane_src_x_int[0] == prev_src_x_int + 16'd1 &&
                                             lane_src_y_int[0] == prev_src_y_int) begin
                                    fetch_phase <= 2'd3;
                                end else begin
                                    fetch_phase <= fetch_phase + 1;
                                end
                            end else begin
                                fetch_phase <= fetch_phase + 1;
                            end
                        end
                    end
                end
                
                // Enviar píxeles al downscaler
                S_PROCESS: begin
                    sdram_read <= 1'b0;
                    sdram_write <= 1'b0;
                    
                    for (int i = 0; i < LANES; i++) begin
                        p00_packed[i*8 +: 8] <= lane_p00[i];
                        p01_packed[i*8 +: 8] <= lane_p01[i];
                        p10_packed[i*8 +: 8] <= lane_p10[i];
                        p11_packed[i*8 +: 8] <= lane_p11[i];
                        frac_x_packed[i*Q +: Q] <= lane_frac_x[i];
                        frac_y_packed[i*Q +: Q] <= lane_frac_y[i];
                    end
                    
                    if (!process_started) begin
                        pixels_valid <= 1'b1;
                        process_started <= 1'b1;
                    end else begin
                        pixels_valid <= 1'b0;
                    end
                    
                    if (process_countdown > 0) begin
                        process_countdown <= process_countdown - 1;
                    end
                    
                    if (result_valid || process_countdown == 0) begin
                        batch_idx <= 3'd0;
                        state <= S_WRITE;
                    end
                end
                
                // Escribir resultado en SDRAM
                S_WRITE: begin
                    if (batch_idx < batch_size && lane_valid[batch_idx]) begin
                        if (!write_pending) begin
                            sdram_write <= 1'b1;
                            sdram_address <= {addr_write[31:1], 1'b0};
                            sdram_byteenable <= addr_write[0] ? 2'b10 : 2'b01;
                            sdram_writedata <= addr_write[0] ? 
                                {result_pixels[batch_idx*8 +: 8], 8'd0} : 
                                {8'd0, result_pixels[batch_idx*8 +: 8]};
                            
                            if (!sdram_waitrequest) begin
                                write_pending <= 1'b1;
                                sdram_write <= 1'b0;
                                perf_mem_writes <= perf_mem_writes + 1;
                            end
                        end else begin
                            write_pending <= 1'b0;
                            batch_idx <= batch_idx + 1;
                        end
                    end else begin
                        write_pending <= 1'b0;
                        state <= S_NEXT;
                    end
                end
                
                // Avanzar a la siguiente coordenada de salida
                S_NEXT: begin
                    write_pending <= 1'b0;
                    sdram_read <= 1'b0;
                    sdram_write <= 1'b0;
                    progress <= progress + {29'd0, batch_size};
                    
                    prev_src_x_int <= lane_src_x_int[batch_size-1];
                    prev_src_y_int <= lane_src_y_int[batch_size-1];
                    prev_p01 <= lane_p01[batch_size-1];
                    prev_p11 <= lane_p11[batch_size-1];
                    prev_valid <= 1'b1;
                    
                    if (out_x + {13'd0, batch_size} >= out_width[15:0]) begin
                        out_x <= 16'd0;
                        prev_valid <= 1'b0; 
                        if (out_y + 1 >= out_height[15:0]) begin
                            state <= S_DONE;
                        end else begin
                            out_y <= out_y + 1;
                            if (step_enable) begin
                                state <= S_WAIT_STEP;
                            end else begin
                                state <= S_COMPUTE;
                            end
                        end
                    end else begin
                        out_x <= out_x + {13'd0, batch_size};
                        if (step_enable) begin
                            state <= S_WAIT_STEP;
                        end else begin
                            state <= S_COMPUTE;
                        end
                    end
                end
                
                S_WAIT_STEP: begin
                    sdram_read <= 1'b0;
                    sdram_write <= 1'b0;
                    pixels_valid <= 1'b0;
                    if (step_once || !step_enable) begin
                        state <= S_COMPUTE;
                    end
                end
                
                // Finalizar procesamiento
                S_DONE: begin
                    done <= 1'b1;
                    busy <= 1'b0;
                    sdram_read <= 1'b0;
                    sdram_write <= 1'b0;
                    state <= S_IDLE;
                end
                
                default: begin
                    sdram_read <= 1'b0;
                    sdram_write <= 1'b0;
                    state <= S_IDLE;
                end
            endcase
        end
    end
    
    // Señales de depuración
    assign dbg_fsm_state = state;
    assign dbg_out_x = out_x;
    assign dbg_out_y = out_y;
    assign dbg_batch_size = batch_size;
    
    // Lane 0
    assign dbg_src_x_int = lane_src_x_int[0];
    assign dbg_src_y_int = lane_src_y_int[0];
    assign dbg_frac_x = lane_frac_x[0];
    assign dbg_frac_y = lane_frac_y[0];
    assign dbg_p00 = lane_p00[0];
    assign dbg_p01 = lane_p01[0];
    assign dbg_p10 = lane_p10[0];
    assign dbg_p11 = lane_p11[0];
    
    // Lane 1
    assign dbg_lane1_src_x = lane_src_x_int[1];
    assign dbg_lane1_src_y = lane_src_y_int[1];
    assign dbg_lane1_frac_x = lane_frac_x[1];
    assign dbg_lane1_frac_y = lane_frac_y[1];
    assign dbg_lane1_p00 = lane_p00[1];
    assign dbg_lane1_p01 = lane_p01[1];
    assign dbg_lane1_p10 = lane_p10[1];
    assign dbg_lane1_p11 = lane_p11[1];
    
    // Lane 2
    assign dbg_lane2_src_x = lane_src_x_int[2];
    assign dbg_lane2_src_y = lane_src_y_int[2];
    assign dbg_lane2_frac_x = lane_frac_x[2];
    assign dbg_lane2_frac_y = lane_frac_y[2];
    assign dbg_lane2_p00 = lane_p00[2];
    assign dbg_lane2_p01 = lane_p01[2];
    assign dbg_lane2_p10 = lane_p10[2];
    assign dbg_lane2_p11 = lane_p11[2];
    
    // Lane 3
    assign dbg_lane3_src_x = lane_src_x_int[3];
    assign dbg_lane3_src_y = lane_src_y_int[3];
    assign dbg_lane3_frac_x = lane_frac_x[3];
    assign dbg_lane3_frac_y = lane_frac_y[3];
    assign dbg_lane3_p00 = lane_p00[3];
    assign dbg_lane3_p01 = lane_p01[3];
    assign dbg_lane3_p10 = lane_p10[3];
    assign dbg_lane3_p11 = lane_p11[3];

endmodule
