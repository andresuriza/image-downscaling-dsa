// Módulo top del downscaler
// Integra CSR bridge, FSM de fetch y aceleradores SIMD/Serial

module downscaler_top #(
    // Parámetros principales
    parameter int LANES          = 4,
    parameter int Q              = 8,
    parameter int MAX_IMAGE_SIZE = 2048,
    parameter int PIXEL_WIDTH    = 8,
    
    // Parámetros derivados
    parameter int PACKED_WIDTH   = LANES * PIXEL_WIDTH,
    parameter int FRAC_WIDTH     = LANES * Q
) (
    input  logic        clk,
    input  logic        rst_n,
    
    // Interfaz Avalon-MM Slave (registros CSR)
    input  logic [11:0] csr_address,
    input  logic        csr_read,
    input  logic        csr_write,
    input  logic [31:0] csr_writedata,
    input  logic [3:0]  csr_byteenable,
    output logic [31:0] csr_readdata,
    output logic        csr_waitrequest,
    
    // Interfaz Avalon-MM Master (SDRAM)
    output logic [31:0] sdram_address,
    output logic        sdram_read,
    output logic        sdram_write,
    output logic [15:0] sdram_writedata,
    input  logic [15:0] sdram_readdata,
    input  logic        sdram_waitrequest,
    input  logic        sdram_readdatavalid,
    output logic [1:0]  sdram_byteenable
);

    // Señales de control desde CSR
    logic        acc_start;
    logic        acc_reset;
    logic [31:0] acc_in_width, acc_in_height;
    logic [31:0] acc_out_width, acc_out_height;
    logic [31:0] acc_scale_q8_8;
    logic [1:0]  acc_mode;
    
    // Control de stepping
    logic        step_enable;
    logic        step_once;
    
    // DMA addresses
    logic [31:0] img_in_addr;
    logic [31:0] img_out_addr;
    
    // Estado de la FSM hacia CSR
    logic        fsm_busy;
    logic        fsm_done;
    logic [31:0] fsm_progress;
    logic [31:0] fsm_errors;
    logic [63:0] fsm_perf_mem_reads;
    logic [63:0] fsm_perf_mem_writes;
    logic [63:0] fsm_perf_pixel_reuse;
    
    // Señales de debug
    logic [3:0]           dbg_fsm_state;
    logic [15:0]          dbg_out_x;
    logic [15:0]          dbg_out_y;
    logic [2:0]           dbg_batch_size;
    
    // Lane 0
    logic [15:0]          dbg_src_x_int;
    logic [15:0]          dbg_src_y_int;
    logic [Q-1:0]         dbg_frac_x;
    logic [Q-1:0]         dbg_frac_y;
    logic [PIXEL_WIDTH-1:0] dbg_p00;
    logic [PIXEL_WIDTH-1:0] dbg_p01;
    logic [PIXEL_WIDTH-1:0] dbg_p10;
    logic [PIXEL_WIDTH-1:0] dbg_p11;
    
    // Lane 1
    logic [15:0]          dbg_lane1_src_x, dbg_lane1_src_y;
    logic [7:0]           dbg_lane1_frac_x, dbg_lane1_frac_y;
    logic [7:0]           dbg_lane1_p00, dbg_lane1_p01, dbg_lane1_p10, dbg_lane1_p11;
    
    // Lane 2
    logic [15:0]          dbg_lane2_src_x, dbg_lane2_src_y;
    logic [7:0]           dbg_lane2_frac_x, dbg_lane2_frac_y;
    logic [7:0]           dbg_lane2_p00, dbg_lane2_p01, dbg_lane2_p10, dbg_lane2_p11;
    
    // Lane 3
    logic [15:0]          dbg_lane3_src_x, dbg_lane3_src_y;
    logic [7:0]           dbg_lane3_frac_x, dbg_lane3_frac_y;
    logic [7:0]           dbg_lane3_p00, dbg_lane3_p01, dbg_lane3_p10, dbg_lane3_p11;
    
    // Interfaz FSM a SIMD
    logic [PACKED_WIDTH-1:0] p00_packed, p01_packed, p10_packed, p11_packed;
    logic [FRAC_WIDTH-1:0]   frac_x_packed, frac_y_packed;
    logic                    pixels_valid;
    logic [PACKED_WIDTH-1:0] result_pixels;
    logic                    result_valid;
    
    // Contadores de FLOPs
    logic [63:0] simd_perf_flops;
    logic [63:0] serial_perf_flops;
    
    // Señales del downscaler serial
    logic [PIXEL_WIDTH-1:0]  serial_out_pixel;
    logic                    serial_out_valid;
    logic [PACKED_WIDTH-1:0] serial_result_pixels;
    
    // Replicar resultado serial a todos los lanes
    always_comb begin
        serial_result_pixels = '0;
        serial_result_pixels[PIXEL_WIDTH-1:0] = serial_out_pixel;
    end
    
    // Selección de modo
    logic use_serial_mode;
    assign use_serial_mode = (acc_mode == 2'd1);
    
    // Mux de resultados
    assign result_pixels = use_serial_mode ? serial_result_pixels : simd_result_pixels;
    assign result_valid  = use_serial_mode ? serial_out_valid : simd_out_valid;
    
    // Selección de contador FLOPs
    wire [63:0] active_perf_flops = use_serial_mode ? serial_perf_flops : simd_perf_flops;
    
    // Señales SIMD internas
    logic [PACKED_WIDTH-1:0] simd_result_pixels;
    logic                    simd_out_valid;
    
    // Instancia CSR Bridge
    accelerator_csr_bridge #(
        .LANES(LANES),
        .Q(Q)
    ) u_csr_bridge (
        .clk              (clk),
        .rst_n            (rst_n),
        
        // Avalon slave
        .avs_address      (csr_address),
        .avs_read         (csr_read),
        .avs_write        (csr_write),
        .avs_writedata    (csr_writedata),
        .avs_byteenable   (csr_byteenable),
        .avs_readdata     (csr_readdata),
        .avs_waitrequest  (csr_waitrequest),
        
        // Accelerator control outputs
        .acc_start        (acc_start),
        .acc_reset        (acc_reset),
        .acc_in_width     (acc_in_width),
        .acc_in_height    (acc_in_height),
        .acc_out_width    (acc_out_width),
        .acc_out_height   (acc_out_height),
        .acc_scale_q8_8   (acc_scale_q8_8),
        .acc_mode         (acc_mode),
        
        // Status inputs (from FSM)
        .acc_busy         (fsm_busy),
        .acc_progress     (fsm_progress),
        .acc_errors       (fsm_errors),
        
        // Performance counters (FLOPs from active unit, mem from FSM)
        .acc_perf_flops      (active_perf_flops),
        .acc_perf_mem_reads  (fsm_perf_mem_reads),
        .acc_perf_mem_writes (fsm_perf_mem_writes),
        .acc_perf_pixel_reuse(fsm_perf_pixel_reuse),
        
        // Stepping control
        .step_enable      (step_enable),
        .step_once        (step_once),
        
        // DMA addresses
        .img_in_addr      (img_in_addr),
        .img_out_addr     (img_out_addr),
        
        // Debug inputs - common
        .dbg_fsm_state    (dbg_fsm_state),
        .dbg_out_x        (dbg_out_x),
        .dbg_out_y        (dbg_out_y),
        .dbg_batch_size   (dbg_batch_size),
        
        // Debug inputs - lane 0
        .dbg_src_x_int    (dbg_src_x_int),
        .dbg_src_y_int    (dbg_src_y_int),
        .dbg_frac_x       (dbg_frac_x),
        .dbg_frac_y       (dbg_frac_y),
        .dbg_p00          (dbg_p00),
        .dbg_p01          (dbg_p01),
        .dbg_p10          (dbg_p10),
        .dbg_p11          (dbg_p11),
        
        // Debug inputs - lane 1
        .dbg_lane1_src_x  (dbg_lane1_src_x),
        .dbg_lane1_src_y  (dbg_lane1_src_y),
        .dbg_lane1_frac_x (dbg_lane1_frac_x),
        .dbg_lane1_frac_y (dbg_lane1_frac_y),
        .dbg_lane1_p00    (dbg_lane1_p00),
        .dbg_lane1_p01    (dbg_lane1_p01),
        .dbg_lane1_p10    (dbg_lane1_p10),
        .dbg_lane1_p11    (dbg_lane1_p11),
        
        // Debug inputs - lane 2
        .dbg_lane2_src_x  (dbg_lane2_src_x),
        .dbg_lane2_src_y  (dbg_lane2_src_y),
        .dbg_lane2_frac_x (dbg_lane2_frac_x),
        .dbg_lane2_frac_y (dbg_lane2_frac_y),
        .dbg_lane2_p00    (dbg_lane2_p00),
        .dbg_lane2_p01    (dbg_lane2_p01),
        .dbg_lane2_p10    (dbg_lane2_p10),
        .dbg_lane2_p11    (dbg_lane2_p11),
        
        // Debug inputs - lane 3
        .dbg_lane3_src_x  (dbg_lane3_src_x),
        .dbg_lane3_src_y  (dbg_lane3_src_y),
        .dbg_lane3_frac_x (dbg_lane3_frac_x),
        .dbg_lane3_frac_y (dbg_lane3_frac_y),
        .dbg_lane3_p00    (dbg_lane3_p00),
        .dbg_lane3_p01    (dbg_lane3_p01),
        .dbg_lane3_p10    (dbg_lane3_p10),
        .dbg_lane3_p11    (dbg_lane3_p11)
    );
    
    // Instancia Pixel Fetch FSM
    pixel_fetch_fsm #(
        .LANES(LANES),
        .Q(Q),
        .MAX_WIDTH(MAX_IMAGE_SIZE),
        .MAX_HEIGHT(MAX_IMAGE_SIZE)
    ) u_pixel_fetch (
        .clk              (clk),
        .rst_n            (rst_n & ~acc_reset),
        
        // Control
        .start            (acc_start),
        .abort            (acc_reset),
        .in_width         (acc_in_width),
        .in_height        (acc_in_height),
        .out_width        (acc_out_width),
        .out_height       (acc_out_height),
        .scale_q8_8       (acc_scale_q8_8),
        .mode             (acc_mode),
        .img_in_addr      (img_in_addr),
        .img_out_addr     (img_out_addr),
        
        // Stepping
        .step_enable      (step_enable),
        .step_once        (step_once),
        
        // Status
        .busy             (fsm_busy),
        .done             (fsm_done),
        .progress         (fsm_progress),
        .errors           (fsm_errors),
        .perf_mem_reads   (fsm_perf_mem_reads),
        .perf_mem_writes  (fsm_perf_mem_writes),
        .perf_pixel_reuse (fsm_perf_pixel_reuse),
        
        // Debug outputs - common
        .dbg_fsm_state    (dbg_fsm_state),
        .dbg_out_x        (dbg_out_x),
        .dbg_out_y        (dbg_out_y),
        .dbg_batch_size   (dbg_batch_size),
        
        // Debug outputs - lane 0
        .dbg_src_x_int    (dbg_src_x_int),
        .dbg_src_y_int    (dbg_src_y_int),
        .dbg_frac_x       (dbg_frac_x),
        .dbg_frac_y       (dbg_frac_y),
        .dbg_p00          (dbg_p00),
        .dbg_p01          (dbg_p01),
        .dbg_p10          (dbg_p10),
        .dbg_p11          (dbg_p11),
        
        // Debug outputs - lane 1
        .dbg_lane1_src_x  (dbg_lane1_src_x),
        .dbg_lane1_src_y  (dbg_lane1_src_y),
        .dbg_lane1_frac_x (dbg_lane1_frac_x),
        .dbg_lane1_frac_y (dbg_lane1_frac_y),
        .dbg_lane1_p00    (dbg_lane1_p00),
        .dbg_lane1_p01    (dbg_lane1_p01),
        .dbg_lane1_p10    (dbg_lane1_p10),
        .dbg_lane1_p11    (dbg_lane1_p11),
        
        // Debug outputs - lane 2
        .dbg_lane2_src_x  (dbg_lane2_src_x),
        .dbg_lane2_src_y  (dbg_lane2_src_y),
        .dbg_lane2_frac_x (dbg_lane2_frac_x),
        .dbg_lane2_frac_y (dbg_lane2_frac_y),
        .dbg_lane2_p00    (dbg_lane2_p00),
        .dbg_lane2_p01    (dbg_lane2_p01),
        .dbg_lane2_p10    (dbg_lane2_p10),
        .dbg_lane2_p11    (dbg_lane2_p11),
        
        // Debug outputs - lane 3
        .dbg_lane3_src_x  (dbg_lane3_src_x),
        .dbg_lane3_src_y  (dbg_lane3_src_y),
        .dbg_lane3_frac_x (dbg_lane3_frac_x),
        .dbg_lane3_frac_y (dbg_lane3_frac_y),
        .dbg_lane3_p00    (dbg_lane3_p00),
        .dbg_lane3_p01    (dbg_lane3_p01),
        .dbg_lane3_p10    (dbg_lane3_p10),
        .dbg_lane3_p11    (dbg_lane3_p11),
        
        // SDRAM master interface
        .sdram_address    (sdram_address),
        .sdram_read       (sdram_read),
        .sdram_write      (sdram_write),
        .sdram_writedata  (sdram_writedata),
        .sdram_readdata   (sdram_readdata),
        .sdram_waitrequest(sdram_waitrequest),
        .sdram_readdatavalid(sdram_readdatavalid),
        .sdram_byteenable (sdram_byteenable),
        
        // SIMD interface
        .p00_packed       (p00_packed),
        .p01_packed       (p01_packed),
        .p10_packed       (p10_packed),
        .p11_packed       (p11_packed),
        .frac_x_packed    (frac_x_packed),
        .frac_y_packed    (frac_y_packed),
        .pixels_valid     (pixels_valid),
        .result_pixels    (result_pixels),
        .result_valid     (result_valid)
    );
    
    // Instancia SIMD Downscaler
    simd_downscaler #(
        .LANES(LANES),
        .Q(Q)
    ) u_simd (
        .clk              (clk),
        .rst_n            (rst_n & ~acc_reset),
        
        .start            (pixels_valid & ~use_serial_mode),
        .in_width         (acc_in_width),
        .in_height        (acc_in_height),
        .out_width        (acc_out_width),
        .out_height       (acc_out_height),
        .scale_q8_8       (acc_scale_q8_8),
        
        .busy             (),
        .progress         (),
        .errors           (),
        
        .perf_flops       (simd_perf_flops),
        .perf_mem_reads   (),
        .perf_mem_writes  (),
        
        // Pixel data from FSM
        .p00_packed       (p00_packed),
        .p01_packed       (p01_packed),
        .p10_packed       (p10_packed),
        .p11_packed       (p11_packed),
        .frac_x_packed    (frac_x_packed),
        .frac_y_packed    (frac_y_packed),
        
        .out_pixels_packed(simd_result_pixels),
        .out_valid        (simd_out_valid)
    );
    
    // Instancia Serial Downscaler
    downscaling_serial #(
        .Q(Q)
    ) u_serial (
        .clk              (clk),
        .rst_n            (rst_n & ~acc_reset),
        
        .start            (pixels_valid & use_serial_mode),
        .in_width         (acc_in_width),
        .in_height        (acc_in_height),
        .out_width        (acc_out_width),
        .out_height       (acc_out_height),
        .scale_q8_8       (acc_scale_q8_8),
        
        .busy             (),
        .progress         (),
        .errors           (),
        
        .perf_flops       (serial_perf_flops),
        .perf_mem_reads   (),
        .perf_mem_writes  (),
        
        .p00              (p00_packed[PIXEL_WIDTH-1:0]),
        .p01              (p01_packed[PIXEL_WIDTH-1:0]),
        .p10              (p10_packed[PIXEL_WIDTH-1:0]),
        .p11              (p11_packed[PIXEL_WIDTH-1:0]),
        .frac_x           (frac_x_packed[Q-1:0]),
        .frac_y           (frac_y_packed[Q-1:0]),
        
        // Output
        .out_pixel        (serial_out_pixel),
        .out_valid        (serial_out_valid)
    );

endmodule
