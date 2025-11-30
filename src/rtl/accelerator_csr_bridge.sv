//=======================================================
// Accelerator CSR Bridge
// Bridges between Avalon-MM CSR RAM and simd_downscaler
//
// Memory Map (base address: 0x0400_0000)
//=======================================================

//-------------------------------------------------------
// CSR Register Offsets (32-bit aligned)
//-------------------------------------------------------
// Control/Status Registers
`define CSR_CTRL           12'h000   // [0]=start, [1]=reset, [2]=step_enable, [3]=step_once
`define CSR_STATUS         12'h004   // [0]=busy, [1]=done, [7:4]=error_code
`define CSR_IN_WIDTH       12'h008   // Input image width
`define CSR_IN_HEIGHT      12'h00C   // Input image height
`define CSR_OUT_WIDTH      12'h010   // Output image width
`define CSR_OUT_HEIGHT     12'h014   // Output image height
`define CSR_SCALE_Q8_8     12'h018   // Q8.8 scale factor
`define CSR_MODE           12'h01C   // [1:0]=mode (0=SIMD, 1=serial), [7:4]=SIMD lanes
`define CSR_PROGRESS       12'h020   // Pixels processed (read-only)
`define CSR_ERRORS         12'h024   // Error count (read-only)

// Performance Counters (read-only, 64-bit split into LO/HI)
`define CSR_PERF_FLOPS_LO  12'h040   // FLOP counter [31:0]
`define CSR_PERF_FLOPS_HI  12'h044   // FLOP counter [63:32]
`define CSR_PERF_READS_LO  12'h048   // Memory reads [31:0]
`define CSR_PERF_READS_HI  12'h04C   // Memory reads [63:32]
`define CSR_PERF_WRITES_LO 12'h050   // Memory writes [31:0]
`define CSR_PERF_WRITES_HI 12'h054   // Memory writes [63:32]
`define CSR_PERF_CYCLES_LO 12'h058   // Cycle counter [31:0]
`define CSR_PERF_CYCLES_HI 12'h05C   // Cycle counter [63:32]

// Image Memory Pointers (for SDRAM-based operation)
`define CSR_IMG_IN_ADDR    12'h080   // Input image base address in SDRAM
`define CSR_IMG_OUT_ADDR   12'h084   // Output image base address in SDRAM

// Debug/Observability Registers (read-only)
`define CSR_DBG_STATE_X    12'h0A0   // [31:28]=fsm_state, [15:0]=out_x
`define CSR_DBG_Y_SRCX     12'h0A4   // [31:16]=out_y, [15:0]=src_x_int
`define CSR_DBG_SRCY_FRAC  12'h0A8   // [31:16]=src_y_int, [15:8]=frac_x, [7:0]=frac_y
`define CSR_DBG_NEIGHBORS  12'h0AC   // [31:24]=p00, [23:16]=p01, [15:8]=p10, [7:0]=p11
`define CSR_DBG_OUTPUT     12'h0B0   // [15:8]=out_pixel, [3:0]=lane_index

// Version/ID
`define CSR_VERSION        12'h0FC   // Version register (read-only): 0x0001_0000 = v1.0

module accelerator_csr_bridge #(
    parameter int LANES = 8,
    parameter int Q = 8
) (
    input  logic        clk,
    input  logic        rst_n,
    
    //=======================================================
    // Avalon-MM Slave Interface (directly mapped to CSR space)
    // Connect to a second port of csr_ram or use address decode
    //=======================================================
    input  logic [11:0] avs_address,      // 12-bit = 4KB address space
    input  logic        avs_read,
    input  logic        avs_write,
    input  logic [31:0] avs_writedata,
    input  logic [3:0]  avs_byteenable,
    output logic [31:0] avs_readdata,
    output logic        avs_waitrequest,
    
    //=======================================================
    // Accelerator Control Interface (directly to simd_downscaler)
    //=======================================================
    // Control outputs
    output logic        acc_start,
    output logic        acc_reset,
    output logic [31:0] acc_in_width,
    output logic [31:0] acc_in_height,
    output logic [31:0] acc_out_width,
    output logic [31:0] acc_out_height,
    output logic [31:0] acc_scale_q8_8,
    output logic [1:0]  acc_mode,
    
    // Status inputs
    input  logic        acc_busy,
    input  logic [31:0] acc_progress,
    input  logic [31:0] acc_errors,
    
    // Performance counter inputs
    input  logic [63:0] acc_perf_flops,
    input  logic [63:0] acc_perf_mem_reads,
    input  logic [63:0] acc_perf_mem_writes,
    
    //=======================================================
    // Stepping Control (optional)
    //=======================================================
    output logic        step_enable,      // Enable step mode
    output logic        step_once,        // Trigger single step
    
    //=======================================================
    // DMA Address Configuration (for SDRAM image transfer)
    //=======================================================
    output logic [31:0] img_in_addr,      // Input image SDRAM address
    output logic [31:0] img_out_addr,     // Output image SDRAM address
    
    //=======================================================
    // Debug/Observability Inputs (from pixel_fetch_fsm)
    //=======================================================
    input  logic [3:0]  dbg_fsm_state,
    input  logic [15:0] dbg_out_x,
    input  logic [15:0] dbg_out_y,
    input  logic [15:0] dbg_src_x_int,
    input  logic [15:0] dbg_src_y_int,
    input  logic [7:0]  dbg_frac_x,
    input  logic [7:0]  dbg_frac_y,
    input  logic [7:0]  dbg_p00,
    input  logic [7:0]  dbg_p01,
    input  logic [7:0]  dbg_p10,
    input  logic [7:0]  dbg_p11,
    input  logic [7:0]  dbg_out_pixel,
    input  logic [3:0]  dbg_lane_index
);

    //=======================================================
    // Internal Registers
    //=======================================================
    logic [31:0] reg_ctrl;
    logic [31:0] reg_in_width;
    logic [31:0] reg_in_height;
    logic [31:0] reg_out_width;
    logic [31:0] reg_out_height;
    logic [31:0] reg_scale_q8_8;
    logic [31:0] reg_mode;
    logic [31:0] reg_img_in_addr;
    logic [31:0] reg_img_out_addr;
    
    // Cycle counter (internal performance counter)
    logic [63:0] cycle_counter;
    logic        was_busy;
    logic        done_flag;
    
    // Control signal extraction
    assign acc_start     = reg_ctrl[0];
    assign acc_reset     = reg_ctrl[1];
    assign step_enable   = reg_ctrl[2];
    assign step_once     = reg_ctrl[3];
    
    assign acc_in_width   = reg_in_width;
    assign acc_in_height  = reg_in_height;
    assign acc_out_width  = reg_out_width;
    assign acc_out_height = reg_out_height;
    assign acc_scale_q8_8 = reg_scale_q8_8;
    assign acc_mode       = reg_mode[1:0];
    
    assign img_in_addr   = reg_img_in_addr;
    assign img_out_addr  = reg_img_out_addr;
    
    // No wait states for simple register access
    assign avs_waitrequest = 1'b0;
    
    //=======================================================
    // Cycle Counter Logic
    //=======================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_counter <= 64'd0;
            was_busy <= 1'b0;
            done_flag <= 1'b0;
        end else begin
            was_busy <= acc_busy;
            
            // Detect rising edge of busy (start) - reset counter
            if (acc_busy && !was_busy) begin
                cycle_counter <= 64'd0;
                done_flag <= 1'b0;
            end
            // Count while busy
            else if (acc_busy) begin
                cycle_counter <= cycle_counter + 1;
            end
            // Detect falling edge of busy (done)
            else if (!acc_busy && was_busy) begin
                done_flag <= 1'b1;
            end
        end
    end
    
    //=======================================================
    // Register Write Logic
    //=======================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_ctrl        <= 32'd0;
            reg_in_width    <= 32'd512;   // Default 512x512
            reg_in_height   <= 32'd512;
            reg_out_width   <= 32'd256;   // Default output 256x256 (0.5 scale)
            reg_out_height  <= 32'd256;
            reg_scale_q8_8  <= 32'h0080;  // 0.5 in Q8.8 = 128
            reg_mode        <= 32'd0;     // SIMD mode
            reg_img_in_addr <= 32'h0000_0000;  // SDRAM base
            reg_img_out_addr<= 32'h0010_0000;  // 1MB offset
        end else begin
            // Auto-clear start bit after one cycle
            if (reg_ctrl[0]) begin
                reg_ctrl[0] <= 1'b0;
            end
            // Auto-clear step_once after one cycle
            if (reg_ctrl[3]) begin
                reg_ctrl[3] <= 1'b0;
            end
            
            // Register writes
            if (avs_write) begin
                case (avs_address)
                    `CSR_CTRL:        reg_ctrl        <= avs_writedata;
                    `CSR_IN_WIDTH:    reg_in_width    <= avs_writedata;
                    `CSR_IN_HEIGHT:   reg_in_height   <= avs_writedata;
                    `CSR_OUT_WIDTH:   reg_out_width   <= avs_writedata;
                    `CSR_OUT_HEIGHT:  reg_out_height  <= avs_writedata;
                    `CSR_SCALE_Q8_8:  reg_scale_q8_8  <= avs_writedata;
                    `CSR_MODE:        reg_mode        <= avs_writedata;
                    `CSR_IMG_IN_ADDR: reg_img_in_addr <= avs_writedata;
                    `CSR_IMG_OUT_ADDR:reg_img_out_addr<= avs_writedata;
                    default: ; // Ignore writes to read-only registers
                endcase
            end
        end
    end
    
    //=======================================================
    // Register Read Logic
    //=======================================================
    always_comb begin
        avs_readdata = 32'd0;
        
        if (avs_read) begin
            case (avs_address)
                // Control/Config registers
                `CSR_CTRL:         avs_readdata = reg_ctrl;
                `CSR_STATUS:       avs_readdata = {24'd0, 4'd0, 2'd0, done_flag, acc_busy};
                `CSR_IN_WIDTH:     avs_readdata = reg_in_width;
                `CSR_IN_HEIGHT:    avs_readdata = reg_in_height;
                `CSR_OUT_WIDTH:    avs_readdata = reg_out_width;
                `CSR_OUT_HEIGHT:   avs_readdata = reg_out_height;
                `CSR_SCALE_Q8_8:   avs_readdata = reg_scale_q8_8;
                `CSR_MODE:         avs_readdata = reg_mode;
                `CSR_PROGRESS:     avs_readdata = acc_progress;
                `CSR_ERRORS:       avs_readdata = acc_errors;
                
                // Performance counters
                `CSR_PERF_FLOPS_LO:  avs_readdata = acc_perf_flops[31:0];
                `CSR_PERF_FLOPS_HI:  avs_readdata = acc_perf_flops[63:32];
                `CSR_PERF_READS_LO:  avs_readdata = acc_perf_mem_reads[31:0];
                `CSR_PERF_READS_HI:  avs_readdata = acc_perf_mem_reads[63:32];
                `CSR_PERF_WRITES_LO: avs_readdata = acc_perf_mem_writes[31:0];
                `CSR_PERF_WRITES_HI: avs_readdata = acc_perf_mem_writes[63:32];
                `CSR_PERF_CYCLES_LO: avs_readdata = cycle_counter[31:0];
                `CSR_PERF_CYCLES_HI: avs_readdata = cycle_counter[63:32];
                
                // DMA addresses
                `CSR_IMG_IN_ADDR:  avs_readdata = reg_img_in_addr;
                `CSR_IMG_OUT_ADDR: avs_readdata = reg_img_out_addr;
                
                // Debug/Observability registers (read-only)
                `CSR_DBG_STATE_X:  avs_readdata = {12'd0, dbg_fsm_state, dbg_out_x};
                `CSR_DBG_Y_SRCX:   avs_readdata = {dbg_out_y, dbg_src_x_int};
                `CSR_DBG_SRCY_FRAC: avs_readdata = {dbg_src_y_int, dbg_frac_x, dbg_frac_y};
                `CSR_DBG_NEIGHBORS: avs_readdata = {dbg_p00, dbg_p01, dbg_p10, dbg_p11};
                `CSR_DBG_OUTPUT:   avs_readdata = {16'd0, dbg_out_pixel, 4'd0, dbg_lane_index};
                
                // Version
                `CSR_VERSION:      avs_readdata = 32'h0001_0000; // v1.0
                
                default:           avs_readdata = 32'hDEAD_BEEF;
            endcase
        end
    end

endmodule
