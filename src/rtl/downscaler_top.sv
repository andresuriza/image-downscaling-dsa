//=======================================================
// Downscaler Top Module
// Integrates CSR bridge, Pixel Fetch FSM, and SIMD accelerator
// Uses SDRAM for image storage (supports up to MAX_IMAGE_SIZE)
//
// All design parameters are declared here and propagated
// to sub-modules for centralized configuration.
//=======================================================

module downscaler_top #(
    // Core design parameters - modify these for configuration
    parameter int LANES          = 4,       // SIMD lanes (fixed at 4 for this design)
    parameter int Q              = 8,       // Fractional bits for Q8.8 fixed-point
    parameter int MAX_IMAGE_SIZE = 2048,    // Maximum supported image dimension
    parameter int PIXEL_WIDTH    = 8,       // Bits per pixel (grayscale)
    
    // Derived parameters (do not modify)
    parameter int PACKED_WIDTH   = LANES * PIXEL_WIDTH,  // Width of packed pixel bus
    parameter int FRAC_WIDTH     = LANES * Q             // Width of packed fraction bus
) (
    input  logic        clk,
    input  logic        rst_n,
    
    //=======================================================
    // Avalon-MM Slave Interface (CSR registers)
    // Base address: 0x0404_0000
    //=======================================================
    input  logic [11:0] csr_address,
    input  logic        csr_read,
    input  logic        csr_write,
    input  logic [31:0] csr_writedata,
    input  logic [3:0]  csr_byteenable,
    output logic [31:0] csr_readdata,
    output logic        csr_waitrequest,
    
    //=======================================================
    // Avalon-MM Master Interface (to SDRAM)
    // Addresses: 0x0000_0000 - 0x03FF_FFFF
    //=======================================================
    output logic [31:0] sdram_address,
    output logic        sdram_read,
    output logic        sdram_write,
    output logic [15:0] sdram_writedata,
    input  logic [15:0] sdram_readdata,
    input  logic        sdram_waitrequest,
    input  logic        sdram_readdatavalid,
    output logic [1:0]  sdram_byteenable
);

    //=======================================================
    // Internal Signals - CSR Bridge outputs
    //=======================================================
    logic        acc_start;
    logic        acc_reset;
    logic [31:0] acc_in_width, acc_in_height;
    logic [31:0] acc_out_width, acc_out_height;
    logic [31:0] acc_scale_q8_8;
    logic [31:0] acc_inv_scale;
    logic [1:0]  acc_mode;
    
    // Stepping control
    logic        step_enable;
    logic        step_once;
    
    // DMA addresses
    logic [31:0] img_in_addr;
    logic [31:0] img_out_addr;
    
    //=======================================================
    // Internal Signals - FSM to CSR status
    //=======================================================
    logic        fsm_busy;
    logic        fsm_done;
    logic [31:0] fsm_progress;
    logic [31:0] fsm_errors;
    logic [63:0] fsm_perf_mem_reads;
    logic [63:0] fsm_perf_mem_writes;
    
    //=======================================================
    // Internal Signals - Debug/Observability
    //=======================================================
    logic [3:0]           dbg_fsm_state;
    logic [15:0]          dbg_out_x;
    logic [15:0]          dbg_out_y;
    logic [15:0]          dbg_src_x_int;
    logic [15:0]          dbg_src_y_int;
    logic [Q-1:0]         dbg_frac_x;
    logic [Q-1:0]         dbg_frac_y;
    logic [PIXEL_WIDTH-1:0] dbg_p00;
    logic [PIXEL_WIDTH-1:0] dbg_p01;
    logic [PIXEL_WIDTH-1:0] dbg_p10;
    logic [PIXEL_WIDTH-1:0] dbg_p11;
    logic [PIXEL_WIDTH-1:0] dbg_out_pixel;
    logic [3:0]           dbg_lane_index;
    
    //=======================================================
    // Internal Signals - FSM to SIMD interface
    //=======================================================
    logic [PACKED_WIDTH-1:0] p00_packed, p01_packed, p10_packed, p11_packed;
    logic [FRAC_WIDTH-1:0]   frac_x_packed, frac_y_packed;
    logic                    pixels_valid;
    logic [PACKED_WIDTH-1:0] result_pixels;
    logic                    result_valid;
    
    //=======================================================
    // SIMD Downscaler Performance Counter (FLOPs)
    //=======================================================
    logic [63:0] simd_perf_flops;
    logic [63:0] serial_perf_flops;
    
    //=======================================================
    // Serial Downscaler Signals
    //=======================================================
    logic [PIXEL_WIDTH-1:0]  serial_out_pixel;
    logic                    serial_out_valid;
    logic [PACKED_WIDTH-1:0] serial_result_pixels;
    
    // Serial uses only lane 0, replicate to all lanes for FSM compatibility
    always_comb begin
        serial_result_pixels = '0;
        serial_result_pixels[PIXEL_WIDTH-1:0] = serial_out_pixel;
    end
    
    // Mode selection: 0 = SIMD, 1 = Serial
    logic use_serial_mode;
    assign use_serial_mode = (acc_mode == 2'd1);
    
    // Mux results based on mode
    assign result_pixels = use_serial_mode ? serial_result_pixels : simd_result_pixels;
    assign result_valid  = use_serial_mode ? serial_out_valid : simd_out_valid;
    
    // Select FLOPs counter based on mode
    wire [63:0] active_perf_flops = use_serial_mode ? serial_perf_flops : simd_perf_flops;
    
    //=======================================================
    // Internal SIMD signals (before mux)
    //=======================================================
    logic [PACKED_WIDTH-1:0] simd_result_pixels;
    logic                    simd_out_valid;
    
    //=======================================================
    // CSR Bridge Instance
    //=======================================================
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
        .acc_inv_scale    (acc_inv_scale),
        .acc_mode         (acc_mode),
        
        // Status inputs (from FSM)
        .acc_busy         (fsm_busy),
        .acc_progress     (fsm_progress),
        .acc_errors       (fsm_errors),
        
        // Performance counters (FLOPs from active unit, mem from FSM)
        .acc_perf_flops      (active_perf_flops),
        .acc_perf_mem_reads  (fsm_perf_mem_reads),
        .acc_perf_mem_writes (fsm_perf_mem_writes),
        
        // Stepping control
        .step_enable      (step_enable),
        .step_once        (step_once),
        
        // DMA addresses
        .img_in_addr      (img_in_addr),
        .img_out_addr     (img_out_addr),
        
        // Debug inputs
        .dbg_fsm_state    (dbg_fsm_state),
        .dbg_out_x        (dbg_out_x),
        .dbg_out_y        (dbg_out_y),
        .dbg_src_x_int    (dbg_src_x_int),
        .dbg_src_y_int    (dbg_src_y_int),
        .dbg_frac_x       (dbg_frac_x),
        .dbg_frac_y       (dbg_frac_y),
        .dbg_p00          (dbg_p00),
        .dbg_p01          (dbg_p01),
        .dbg_p10          (dbg_p10),
        .dbg_p11          (dbg_p11),
        .dbg_out_pixel    (dbg_out_pixel),
        .dbg_lane_index   (dbg_lane_index)
    );
    
    //=======================================================
    // Pixel Fetch FSM Instance
    // Manages SDRAM reads/writes and feeds SIMD accelerator
    //=======================================================
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
        .inv_scale        (acc_inv_scale),
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
        
        // Debug outputs
        .dbg_fsm_state    (dbg_fsm_state),
        .dbg_out_x        (dbg_out_x),
        .dbg_out_y        (dbg_out_y),
        .dbg_src_x_int    (dbg_src_x_int),
        .dbg_src_y_int    (dbg_src_y_int),
        .dbg_frac_x       (dbg_frac_x),
        .dbg_frac_y       (dbg_frac_y),
        .dbg_p00          (dbg_p00),
        .dbg_p01          (dbg_p01),
        .dbg_p10          (dbg_p10),
        .dbg_p11          (dbg_p11),
        .dbg_out_pixel    (dbg_out_pixel),
        .dbg_lane_index   (dbg_lane_index),
        
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
    
    //=======================================================
    // SIMD Downscaler Instance
    // Parallel bilinear interpolation (LANES pixels per cycle)
    //=======================================================
    simd_downscaler #(
        .LANES(LANES),
        .Q(Q)
    ) u_simd (
        .clk              (clk),
        .rst_n            (rst_n & ~acc_reset),
        
        // Control (directly from FSM valid signal, only when in SIMD mode)
        .start            (pixels_valid & ~use_serial_mode),
        .in_width         (acc_in_width),
        .in_height        (acc_in_height),
        .out_width        (acc_out_width),
        .out_height       (acc_out_height),
        .scale_q8_8       (acc_scale_q8_8),
        
        // Status (used for FLOPs counting)
        .busy             (),  // FSM manages overall busy
        .progress         (),  // FSM tracks progress
        .errors           (),
        
        // Performance counters
        .perf_flops       (simd_perf_flops),
        .perf_mem_reads   (),  // FSM tracks this
        .perf_mem_writes  (),  // FSM tracks this
        
        // Pixel data from FSM
        .p00_packed       (p00_packed),
        .p01_packed       (p01_packed),
        .p10_packed       (p10_packed),
        .p11_packed       (p11_packed),
        .frac_x_packed    (frac_x_packed),
        .frac_y_packed    (frac_y_packed),
        
        // Output (internal, before mux)
        .out_pixels_packed(simd_result_pixels),
        .out_valid        (simd_out_valid)
    );
    
    //=======================================================
    // Serial Downscaler Instance
    // Single pixel bilinear interpolation (1 pixel per cycle)
    //=======================================================
    downscaling_serial #(
        .Q(Q)
    ) u_serial (
        .clk              (clk),
        .rst_n            (rst_n & ~acc_reset),
        
        // Control (only when in serial mode)
        .start            (pixels_valid & use_serial_mode),
        .in_width         (acc_in_width),
        .in_height        (acc_in_height),
        .out_width        (acc_out_width),
        .out_height       (acc_out_height),
        .scale_q8_8       (acc_scale_q8_8),
        
        // Status
        .busy             (),  // FSM manages overall busy
        .progress         (),  // FSM tracks progress
        .errors           (),
        
        // Performance counters
        .perf_flops       (serial_perf_flops),
        .perf_mem_reads   (),  // FSM tracks this
        .perf_mem_writes  (),  // FSM tracks this
        
        // Pixel data from FSM (only lane 0)
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
