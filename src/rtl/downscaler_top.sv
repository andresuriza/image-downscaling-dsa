//=======================================================
// Downscaler Top Module
// Integrates CSR bridge and SIMD accelerator
// Uses SDRAM only for image storage
//=======================================================

module downscaler_top #(
    parameter int LANES = 8,
    parameter int Q = 8
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
    // Internal Signals
    //=======================================================
    
    // CSR Bridge to Accelerator
    logic        acc_start;
    logic        acc_reset;
    logic [31:0] acc_in_width, acc_in_height;
    logic [31:0] acc_out_width, acc_out_height;
    logic [31:0] acc_scale_q8_8;
    logic [1:0]  acc_mode;
    logic        acc_busy;
    logic [31:0] acc_progress;
    logic [31:0] acc_errors;
    logic [63:0] acc_perf_flops;
    logic [63:0] acc_perf_mem_reads;
    logic [63:0] acc_perf_mem_writes;
    
    // Stepping control
    logic        step_enable;
    logic        step_once;
    
    // DMA addresses
    logic [31:0] img_in_addr;
    logic [31:0] img_out_addr;
    
    // Accelerator pixel interface
    logic [LANES*8-1:0] p00_packed, p01_packed, p10_packed, p11_packed;
    logic [LANES*Q-1:0] frac_x_packed, frac_y_packed;
    logic [LANES*8-1:0] out_pixels_packed;
    logic               out_valid;
    
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
        
        // Accelerator control
        .acc_start        (acc_start),
        .acc_reset        (acc_reset),
        .acc_in_width     (acc_in_width),
        .acc_in_height    (acc_in_height),
        .acc_out_width    (acc_out_width),
        .acc_out_height   (acc_out_height),
        .acc_scale_q8_8   (acc_scale_q8_8),
        .acc_mode         (acc_mode),
        .acc_busy         (acc_busy),
        .acc_progress     (acc_progress),
        .acc_errors       (acc_errors),
        .acc_perf_flops   (acc_perf_flops),
        .acc_perf_mem_reads(acc_perf_mem_reads),
        .acc_perf_mem_writes(acc_perf_mem_writes),
        
        // Stepping
        .step_enable      (step_enable),
        .step_once        (step_once),
        
        // DMA addresses
        .img_in_addr      (img_in_addr),
        .img_out_addr     (img_out_addr)
    );
    
    //=======================================================
    // SIMD Downscaler Instance
    //=======================================================
    simd_downscaler #(
        .LANES(LANES),
        .Q(Q)
    ) u_accelerator (
        .clk              (clk),
        .rst_n            (rst_n & ~acc_reset),
        
        // Control
        .start            (acc_start),
        .in_width         (acc_in_width),
        .in_height        (acc_in_height),
        .out_width        (acc_out_width),
        .out_height       (acc_out_height),
        .scale_q8_8       (acc_scale_q8_8),
        .mode             (acc_mode),
        
        // Status
        .busy             (acc_busy),
        .progress         (acc_progress),
        .errors           (acc_errors),
        
        // Performance counters
        .perf_flops       (acc_perf_flops),
        .perf_mem_reads   (acc_perf_mem_reads),
        .perf_mem_writes  (acc_perf_mem_writes),
        
        // Pixel data (directly from SDRAM via pixel fetch FSM)
        .p00_packed       (p00_packed),
        .p01_packed       (p01_packed),
        .p10_packed       (p10_packed),
        .p11_packed       (p11_packed),
        .frac_x_packed    (frac_x_packed),
        .frac_y_packed    (frac_y_packed),
        
        // Output
        .out_pixels_packed(out_pixels_packed),
        .out_valid        (out_valid)
    );
    
    //=======================================================
    // Simple SDRAM Interface
    // Default: idle state (JTAG master accesses SDRAM directly)
    // TODO: Implement pixel fetch FSM when accelerator runs
    //=======================================================
    
    // For now, tie off SDRAM master to allow JTAG direct access
    // The accelerator will be extended later to fetch pixels
    assign sdram_address = 32'd0;
    assign sdram_read = 1'b0;
    assign sdram_write = 1'b0;
    assign sdram_writedata = 16'd0;
    assign sdram_byteenable = 2'b11;
    
    // Temporary: tie off pixel inputs (for initial CSR testing)
    assign p00_packed = {LANES{8'd128}};
    assign p01_packed = {LANES{8'd128}};
    assign p10_packed = {LANES{8'd128}};
    assign p11_packed = {LANES{8'd128}};
    assign frac_x_packed = {LANES{8'd0}};
    assign frac_y_packed = {LANES{8'd0}};

endmodule
