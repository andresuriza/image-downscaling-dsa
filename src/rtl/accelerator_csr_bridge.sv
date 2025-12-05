//=======================================================
// Accelerator CSR Bridge (Simplified)
// Minimal register set for image downscaling control
//
// Parameters inherited from downscaler_top
//=======================================================

//-------------------------------------------------------
// CSR Register Offsets (32-bit aligned)
//-------------------------------------------------------
`define CSR_CTRL           12'h000   // [0]=start, [1]=reset
`define CSR_STATUS         12'h004   // [0]=busy, [1]=done
`define CSR_IN_WIDTH       12'h008   // Input image width
`define CSR_IN_HEIGHT      12'h00C   // Input image height
`define CSR_OUT_WIDTH      12'h010   // Output image width
`define CSR_OUT_HEIGHT     12'h014   // Output image height
`define CSR_SCALE_Q8_8     12'h018   // Q8.8 scale factor
`define CSR_MODE           12'h020   // [0]=mode (0=SIMD, 1=Serial)
`define CSR_PROGRESS       12'h024   // Pixels processed (RO)

// Image Memory Pointers
`define CSR_IMG_IN_ADDR    12'h080   // Input image SDRAM address
`define CSR_IMG_OUT_ADDR   12'h084   // Output image SDRAM address

// Performance Counters
`define CSR_PERF_CYCLES_LO 12'h058   // Cycle counter [31:0]
`define CSR_PERF_CYCLES_HI 12'h05C   // Cycle counter [63:32]
`define CSR_PERF_REUSE_LO  12'h060   // Pixel reuse count [31:0]
`define CSR_PERF_REUSE_HI  12'h064   // Pixel reuse count [63:32]
`define CSR_PERF_MEM_RD_LO 12'h068   // Memory reads [31:0]
`define CSR_PERF_MEM_RD_HI 12'h06C   // Memory reads [63:32]
`define CSR_PERF_MEM_WR_LO 12'h070   // Memory writes [31:0]
`define CSR_PERF_MEM_WR_HI 12'h074   // Memory writes [63:32]
`define CSR_PERF_FLOPS_LO  12'h078   // FLOPs count [31:0]
`define CSR_PERF_FLOPS_HI  12'h07C   // FLOPs count [63:32]

// Debug registers - lane 0
`define CSR_DBG_OUT_Y      12'h0E0   // Debug: [18:16]=batch_size, [15:0]=out_y
`define CSR_DBG_PIXELS     12'h0E4   // Debug: p11[31:24], p10[23:16], p01[15:8], p00[7:0]
`define CSR_DBG_FSM        12'h0F0   // Debug: FSM state [19:16], out_x[15:0]
`define CSR_DBG_COORD      12'h0F4   // Debug: src_y_int[31:16], src_x_int[15:0]
`define CSR_DBG_FRAC       12'h0F8   // Debug: frac_y[15:8], frac_x[7:0]

// Debug registers - lanes 1-3
`define CSR_DBG_LANE1_COORD 12'h0A0  // Lane 1: src_y[31:16], src_x[15:0]
`define CSR_DBG_LANE1_FRAC  12'h0A4  // Lane 1: frac_y[15:8], frac_x[7:0]
`define CSR_DBG_LANE1_PIX   12'h0A8  // Lane 1: p11[31:24], p10[23:16], p01[15:8], p00[7:0]
`define CSR_DBG_LANE2_COORD 12'h0B0  // Lane 2: src_y[31:16], src_x[15:0]
`define CSR_DBG_LANE2_FRAC  12'h0B4  // Lane 2: frac_y[15:8], frac_x[7:0]
`define CSR_DBG_LANE2_PIX   12'h0B8  // Lane 2: p11[31:24], p10[23:16], p01[15:8], p00[7:0]
`define CSR_DBG_LANE3_COORD 12'h0C0  // Lane 3: src_y[31:16], src_x[15:0]
`define CSR_DBG_LANE3_FRAC  12'h0C4  // Lane 3: frac_y[15:8], frac_x[7:0]
`define CSR_DBG_LANE3_PIX   12'h0C8  // Lane 3: p11[31:24], p10[23:16], p01[15:8], p00[7:0]

// Version
`define CSR_VERSION        12'h0FC   // Version register (RO)

module accelerator_csr_bridge #(
    parameter int LANES = 4,    // SIMD lanes (from top)
    parameter int Q     = 8     // Fractional bits (from top)
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
    input  logic [63:0] acc_perf_pixel_reuse,
    
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
    input  logic [3:0]    dbg_fsm_state,
    input  logic [15:0]   dbg_out_x,
    input  logic [15:0]   dbg_out_y,
    input  logic [2:0]    dbg_batch_size,
    
    // Lane 0
    input  logic [15:0]   dbg_src_x_int,
    input  logic [15:0]   dbg_src_y_int,
    input  logic [Q-1:0]  dbg_frac_x,
    input  logic [Q-1:0]  dbg_frac_y,
    input  logic [7:0]    dbg_p00,
    input  logic [7:0]    dbg_p01,
    input  logic [7:0]    dbg_p10,
    input  logic [7:0]    dbg_p11,
    
    // Lane 1
    input  logic [15:0]   dbg_lane1_src_x,
    input  logic [15:0]   dbg_lane1_src_y,
    input  logic [7:0]    dbg_lane1_frac_x,
    input  logic [7:0]    dbg_lane1_frac_y,
    input  logic [7:0]    dbg_lane1_p00,
    input  logic [7:0]    dbg_lane1_p01,
    input  logic [7:0]    dbg_lane1_p10,
    input  logic [7:0]    dbg_lane1_p11,
    
    // Lane 2
    input  logic [15:0]   dbg_lane2_src_x,
    input  logic [15:0]   dbg_lane2_src_y,
    input  logic [7:0]    dbg_lane2_frac_x,
    input  logic [7:0]    dbg_lane2_frac_y,
    input  logic [7:0]    dbg_lane2_p00,
    input  logic [7:0]    dbg_lane2_p01,
    input  logic [7:0]    dbg_lane2_p10,
    input  logic [7:0]    dbg_lane2_p11,
    
    // Lane 3
    input  logic [15:0]   dbg_lane3_src_x,
    input  logic [15:0]   dbg_lane3_src_y,
    input  logic [7:0]    dbg_lane3_frac_x,
    input  logic [7:0]    dbg_lane3_frac_y,
    input  logic [7:0]    dbg_lane3_p00,
    input  logic [7:0]    dbg_lane3_p01,
    input  logic [7:0]    dbg_lane3_p10,
    input  logic [7:0]    dbg_lane3_p11
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
    // Detect start/reset commands from CTRL register writes
    logic start_cmd, reset_cmd;
    assign start_cmd = avs_write && (avs_address == `CSR_CTRL) && avs_writedata[0];
    assign reset_cmd = avs_write && (avs_address == `CSR_CTRL) && avs_writedata[1];
    
    // S_WAIT_STEP state = 7, don't count cycles while waiting for step
    logic fsm_waiting_step;
    assign fsm_waiting_step = (dbg_fsm_state == 4'd7);
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_counter <= 64'd0;
            was_busy <= 1'b0;
            done_flag <= 1'b0;
        end else begin
            was_busy <= acc_busy;
            
            // Reset counter on explicit reset command or start command
            if (reset_cmd || start_cmd) begin
                cycle_counter <= 64'd0;
                done_flag <= 1'b0;
            end
            // Count while busy AND not waiting for step
            else if (acc_busy && !fsm_waiting_step) begin
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
            reg_mode        <= 32'd0;     // SIMD mode (0), lanes fixed at 4
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
    // Register Read Logic (Simplified)
    //=======================================================
    always_comb begin
        avs_readdata = 32'd0;
        
        if (avs_read) begin
            case (avs_address)
                // Essential registers
                `CSR_CTRL:         avs_readdata = reg_ctrl;
                `CSR_STATUS:       avs_readdata = {30'd0, done_flag, acc_busy};
                `CSR_IN_WIDTH:     avs_readdata = reg_in_width;
                `CSR_IN_HEIGHT:    avs_readdata = reg_in_height;
                `CSR_OUT_WIDTH:    avs_readdata = reg_out_width;
                `CSR_OUT_HEIGHT:   avs_readdata = reg_out_height;
                `CSR_SCALE_Q8_8:   avs_readdata = reg_scale_q8_8;
                `CSR_MODE:         avs_readdata = reg_mode;
                `CSR_PROGRESS:     avs_readdata = acc_progress;
                
                // DMA addresses
                `CSR_IMG_IN_ADDR:  avs_readdata = reg_img_in_addr;
                `CSR_IMG_OUT_ADDR: avs_readdata = reg_img_out_addr;
                
                // Performance Counters
                `CSR_PERF_CYCLES_LO: avs_readdata = cycle_counter[31:0];
                `CSR_PERF_CYCLES_HI: avs_readdata = cycle_counter[63:32];
                `CSR_PERF_REUSE_LO:  avs_readdata = acc_perf_pixel_reuse[31:0];
                `CSR_PERF_REUSE_HI:  avs_readdata = acc_perf_pixel_reuse[63:32];
                `CSR_PERF_MEM_RD_LO: avs_readdata = acc_perf_mem_reads[31:0];
                `CSR_PERF_MEM_RD_HI: avs_readdata = acc_perf_mem_reads[63:32];
                `CSR_PERF_MEM_WR_LO: avs_readdata = acc_perf_mem_writes[31:0];
                `CSR_PERF_MEM_WR_HI: avs_readdata = acc_perf_mem_writes[63:32];
                `CSR_PERF_FLOPS_LO:  avs_readdata = acc_perf_flops[31:0];
                `CSR_PERF_FLOPS_HI:  avs_readdata = acc_perf_flops[63:32];
                
                // Version: v1.3 (SIMD batch mode with per-lane debug)
                `CSR_VERSION:      avs_readdata = 32'h0001_0300;
                
                // Debug registers - lane 0 (read-only)
                `CSR_DBG_OUT_Y:    avs_readdata = {13'd0, dbg_batch_size, dbg_out_y};
                `CSR_DBG_PIXELS:   avs_readdata = {dbg_p11, dbg_p10, dbg_p01, dbg_p00};
                `CSR_DBG_FSM:      avs_readdata = {12'd0, dbg_fsm_state, dbg_out_x};
                `CSR_DBG_COORD:    avs_readdata = {dbg_src_y_int, dbg_src_x_int};
                `CSR_DBG_FRAC:     avs_readdata = {16'd0, dbg_frac_y, dbg_frac_x};
                
                // Debug registers - lane 1
                `CSR_DBG_LANE1_COORD: avs_readdata = {dbg_lane1_src_y, dbg_lane1_src_x};
                `CSR_DBG_LANE1_FRAC:  avs_readdata = {16'd0, dbg_lane1_frac_y, dbg_lane1_frac_x};
                `CSR_DBG_LANE1_PIX:   avs_readdata = {dbg_lane1_p11, dbg_lane1_p10, dbg_lane1_p01, dbg_lane1_p00};
                
                // Debug registers - lane 2
                `CSR_DBG_LANE2_COORD: avs_readdata = {dbg_lane2_src_y, dbg_lane2_src_x};
                `CSR_DBG_LANE2_FRAC:  avs_readdata = {16'd0, dbg_lane2_frac_y, dbg_lane2_frac_x};
                `CSR_DBG_LANE2_PIX:   avs_readdata = {dbg_lane2_p11, dbg_lane2_p10, dbg_lane2_p01, dbg_lane2_p00};
                
                // Debug registers - lane 3
                `CSR_DBG_LANE3_COORD: avs_readdata = {dbg_lane3_src_y, dbg_lane3_src_x};
                `CSR_DBG_LANE3_FRAC:  avs_readdata = {16'd0, dbg_lane3_frac_y, dbg_lane3_frac_x};
                `CSR_DBG_LANE3_PIX:   avs_readdata = {dbg_lane3_p11, dbg_lane3_p10, dbg_lane3_p01, dbg_lane3_p00};
                
                default:           avs_readdata = 32'd0;
            endcase
        end
    end

endmodule
