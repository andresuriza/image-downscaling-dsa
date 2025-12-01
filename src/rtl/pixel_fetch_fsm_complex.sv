//=======================================================
// Pixel Fetch FSM
// Manages SDRAM reads, line buffering, and pixel packing
// for both SIMD (LANES pixels) and Serial (1 pixel) modes
//
// Parameters inherited from downscaler_top
//=======================================================

module pixel_fetch_fsm #(
    parameter int LANES      = 4,       // SIMD lanes
    parameter int Q          = 8,       // Fractional bits
    parameter int MAX_WIDTH  = 2048,    // Max image width
    parameter int MAX_HEIGHT = 2048     // Max image height
) (
    input  logic        clk,
    input  logic        rst_n,
    
    //=======================================================
    // Control Interface (from CSR)
    //=======================================================
    input  logic        start,
    input  logic        abort,
    input  logic [31:0] in_width,
    input  logic [31:0] in_height,
    input  logic [31:0] out_width,
    input  logic [31:0] out_height,
    input  logic [31:0] scale_q8_8,
    input  logic [31:0] inv_scale,          // Inverse scale Q16.16 from SW
    input  logic [1:0]  mode,               // 0=SIMD, 1=Serial
    input  logic [31:0] img_in_addr,
    input  logic [31:0] img_out_addr,
    
    // Stepping control
    input  logic        step_enable,
    input  logic        step_once,
    
    //=======================================================
    // Status Interface (to CSR)
    //=======================================================
    output logic        busy,
    output logic        done,
    output logic [31:0] progress,           // Output pixels completed
    output logic [31:0] errors,
    
    // Performance counters
    output logic [63:0] perf_mem_reads,
    output logic [63:0] perf_mem_writes,
    
    //=======================================================
    // Debug/Observability Interface (to CSR)
    //=======================================================
    output logic [3:0]  dbg_fsm_state,
    output logic [15:0] dbg_out_x,
    output logic [15:0] dbg_out_y,
    output logic [15:0] dbg_src_x_int,
    output logic [15:0] dbg_src_y_int,
    output logic [Q-1:0]  dbg_frac_x,
    output logic [Q-1:0]  dbg_frac_y,
    output logic [7:0]  dbg_p00,    // PIXEL_WIDTH=8 for debug interface
    output logic [7:0]  dbg_p01,
    output logic [7:0]  dbg_p10,
    output logic [7:0]  dbg_p11,
    output logic [7:0]  dbg_out_pixel,
    output logic [3:0]  dbg_lane_index,
    
    //=======================================================
    // Avalon-MM Master Interface (to SDRAM)
    //=======================================================
    output logic [31:0] sdram_address,
    output logic        sdram_read,
    output logic        sdram_write,
    output logic [15:0] sdram_writedata,
    input  logic [15:0] sdram_readdata,
    input  logic        sdram_waitrequest,
    input  logic        sdram_readdatavalid,
    output logic [1:0]  sdram_byteenable,
    
    //=======================================================
    // SIMD Downscaler Interface
    //=======================================================
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

    //=======================================================
    // FSM States
    //=======================================================
    typedef enum logic [3:0] {
        S_IDLE          = 4'd0,
        S_INIT          = 4'd1,
        S_FETCH_ROW0    = 4'd2,
        S_FETCH_ROW1    = 4'd3,
        S_WAIT_ROWS     = 4'd4,
        S_COMPUTE_COORD = 4'd5,
        S_PACK_PIXELS   = 4'd6,
        S_WAIT_PROCESS  = 4'd7,
        S_WRITE_PIXEL   = 4'd8,
        S_WAIT_WRITE    = 4'd9,
        S_NEXT_PIXEL    = 4'd10,
        S_WAIT_STEP     = 4'd11,
        S_DONE          = 4'd12,
        S_ERROR         = 4'd13
    } state_t;
    
    state_t state, next_state;
    
    //=======================================================
    // Derived constants from parameters
    //=======================================================
    // For Q8.8 format: bits [2*Q-1:Q] = integer, bits [Q-1:0] = fraction
    localparam int INT_MSB  = 2*Q - 1;  // 15 for Q=8
    localparam int INT_LSB  = Q;        // 8 for Q=8
    localparam int FRAC_MSB = Q - 1;    // 7 for Q=8
    localparam int FRAC_LSB = 0;        // 0
    localparam int PIXEL_WIDTH = 8;     // Bits per pixel

    //=======================================================
    // Internal Registers
    //=======================================================
    // Output coordinates
    logic [31:0] out_x, out_y;
    logic [31:0] total_out_pixels;
    
    // Source coordinates in Q8.8
    logic [31:0] src_x_q8 [0:LANES-1];
    logic [31:0] src_y_q8 [0:LANES-1];
    
    // Coordinate calculation intermediates (combinational)
    logic [31:0] out_x_lane [0:LANES-1];
    logic [63:0] prod_x     [0:LANES-1];
    logic [63:0] prod_y;
    
    // Fetch state
    logic [31:0] fetch_addr;
    logic [15:0] fetch_col;
    logic        fetch_row_sel;     // 0=row0, 1=row1
    logic [15:0] target_row_y [0:1]; // Y coordinate being fetched
    logic        byte_select;        // For 16-bit to 8-bit conversion
    logic [7:0]  pending_byte;       // Stored high byte from 16-bit read
    
    // Line buffer control
    logic        lb_clear;
    logic        lb_wr_en;
    logic        lb_wr_row_sel;
    logic [15:0] lb_wr_col;
    logic [7:0]  lb_wr_data;
    logic [15:0] lb_rd_col;
    logic [15:0] lb_rd_col_comb;  // Combinational read address for immediate response
    logic [7:0]  lb_p00, lb_p01, lb_p10, lb_p11;
    logic        lb_rd_valid;
    logic        lb_row0_valid, lb_row1_valid;
    
    // State for pixel read timing
    logic        pack_pixels_phase;  // 0=set address, 1=read data
    
    // Current lane being processed
    logic [3:0]  current_lane;
    // Active lanes: LANES for SIMD, 1 for serial
    localparam logic [3:0] SERIAL_LANES = 4'd1;
    wire  [3:0]  active_lanes = (mode == 2'd1) ? SERIAL_LANES : LANES[3:0];
    
    // Packed pixel registers
    logic [7:0]  lane_p00 [0:LANES-1];
    logic [7:0]  lane_p01 [0:LANES-1];
    logic [7:0]  lane_p10 [0:LANES-1];
    logic [7:0]  lane_p11 [0:LANES-1];
    logic [Q-1:0] lane_frac_x [0:LANES-1];
    logic [Q-1:0] lane_frac_y [0:LANES-1];
    
    // Write state
    logic [31:0] write_addr;
    logic [3:0]  write_lane;
    logic [7:0]  write_pixel;
    logic        write_byte_sel;    // 0=low byte, 1=high byte
    logic [7:0]  write_buffer;      // Buffer for packing 2 pixels
    
    // Write calculation temporaries (combinational)
    logic [31:0] current_write_addr;
    logic [7:0]  current_pixel;
    
    // Debug lane rotation
    logic [3:0]  dbg_lane_sel;
    
    //=======================================================
    // Line Buffer Instance
    //=======================================================
    
    // Use combinational address for immediate read response
    // In S_PACK_PIXELS, we compute the address combinationally
    // src_x_q8 is Q8.8: [INT_MSB:INT_LSB] = integer, [FRAC_MSB:FRAC_LSB] = fraction
    always_comb begin
        if (state == S_PACK_PIXELS) begin
            lb_rd_col_comb = src_x_q8[current_lane][INT_MSB:INT_LSB]; // Integer part of source X
        end else begin
            lb_rd_col_comb = lb_rd_col; // Use registered value otherwise
        end
    end
    
    line_buffer #(
        .MAX_WIDTH(MAX_WIDTH),
        .DATA_WIDTH(8)
    ) u_line_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .clear(lb_clear),
        .image_width(in_width),
        .wr_en(lb_wr_en),
        .wr_row_sel(lb_wr_row_sel),
        .wr_col(lb_wr_col),
        .wr_data(lb_wr_data),
        .rd_col(lb_rd_col_comb),  // Use combinational address
        .p00(lb_p00),
        .p01(lb_p01),
        .p10(lb_p10),
        .p11(lb_p11),
        .rd_valid(lb_rd_valid),
        .row0_valid(lb_row0_valid),
        .row1_valid(lb_row1_valid),
        .row0_y(),
        .row1_y()
    );
    
    //=======================================================
    // Coordinate calculation (combinational for DSP inference)
    // src_q8_8 = (out * inv_scale) >> 16
    // where inv_scale is Q16.16 and result is Q8.8
    //=======================================================
    always_comb begin
        prod_y = out_y * inv_scale;
        for (int i = 0; i < LANES; i++) begin
            out_x_lane[i] = out_x + i;
            prod_x[i] = out_x_lane[i] * inv_scale;
        end
    end
    
    //=======================================================
    // Write address and pixel computation (combinational)
    //=======================================================
    always_comb begin
        current_pixel = result_pixels[write_lane*PIXEL_WIDTH +: PIXEL_WIDTH];
        current_write_addr = img_out_addr + (out_y * out_width) + out_x + {28'd0, write_lane};
    end
    
    //=======================================================
    // FSM State Register
    //=======================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else if (abort)
            state <= S_IDLE;
        else
            state <= next_state;
    end
    
    //=======================================================
    // FSM Next State Logic
    //=======================================================
    always_comb begin
        next_state = state;
        
        case (state)
            S_IDLE: begin
                if (start)
                    next_state = S_INIT;
            end
            
            S_INIT: begin
                next_state = S_FETCH_ROW0;
            end
            
            S_FETCH_ROW0: begin
                if (lb_row0_valid)
                    next_state = S_FETCH_ROW1;
                else if (!sdram_waitrequest && sdram_readdatavalid && 
                         fetch_col >= in_width[15:0] - 1)
                    next_state = S_FETCH_ROW1;
            end
            
            S_FETCH_ROW1: begin
                if (lb_row1_valid)
                    next_state = S_COMPUTE_COORD;
                else if (!sdram_waitrequest && sdram_readdatavalid && 
                         fetch_col >= in_width[15:0] - 1)
                    next_state = S_COMPUTE_COORD;
            end
            
            S_COMPUTE_COORD: begin
                next_state = S_PACK_PIXELS;
            end
            
            S_PACK_PIXELS: begin
                if (current_lane >= active_lanes - 1)
                    next_state = S_WAIT_PROCESS;
            end
            
            S_WAIT_PROCESS: begin
                if (result_valid)
                    next_state = S_WRITE_PIXEL;
            end
            
            S_WRITE_PIXEL: begin
                next_state = S_WAIT_WRITE;
            end
            
            S_WAIT_WRITE: begin
                if (!sdram_waitrequest) begin
                    if (write_lane >= active_lanes - 1)
                        next_state = S_NEXT_PIXEL;
                    else
                        next_state = S_WRITE_PIXEL;
                end
            end
            
            S_NEXT_PIXEL: begin
                if (step_enable)
                    next_state = S_WAIT_STEP;
                else if (out_x + active_lanes >= out_width)
                    if (out_y + 1 >= out_height)
                        next_state = S_DONE;
                    else
                        next_state = S_FETCH_ROW0; // Need new rows
                else
                    next_state = S_COMPUTE_COORD;
            end
            
            S_WAIT_STEP: begin
                if (step_once)
                    next_state = S_COMPUTE_COORD;
            end
            
            S_DONE: begin
                next_state = S_IDLE;
            end
            
            S_ERROR: begin
                next_state = S_IDLE;
            end
            
            default: next_state = S_IDLE;
        endcase
    end
    
    //=======================================================
    // FSM Output and Datapath Logic
    //=======================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_x <= 32'd0;
            out_y <= 32'd0;
            progress <= 32'd0;
            errors <= 32'd0;
            busy <= 1'b0;
            done <= 1'b0;
            perf_mem_reads <= 64'd0;
            perf_mem_writes <= 64'd0;
            fetch_addr <= 32'd0;
            fetch_col <= 16'd0;
            fetch_row_sel <= 1'b0;
            byte_select <= 1'b0;
            lb_clear <= 1'b0;
            lb_wr_en <= 1'b0;
            lb_rd_col <= 16'd0;
            pack_pixels_phase <= 1'b0;
            sdram_read <= 1'b0;
            sdram_write <= 1'b0;
            pixels_valid <= 1'b0;
            current_lane <= 4'd0;
            write_lane <= 4'd0;
            write_byte_sel <= 1'b0;
            dbg_lane_sel <= 4'd0;
            target_row_y[0] <= 16'd0;
            target_row_y[1] <= 16'd0;
            sdram_byteenable <= 2'b11;
        end else begin
            // Default signals
            lb_clear <= 1'b0;
            lb_wr_en <= 1'b0;
            sdram_read <= 1'b0;
            sdram_write <= 1'b0;
            pixels_valid <= 1'b0;
            done <= 1'b0;
            
            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        out_x <= 32'd0;
                        out_y <= 32'd0;
                        progress <= 32'd0;
                        errors <= 32'd0;
                        perf_mem_reads <= 64'd0;
                        perf_mem_writes <= 64'd0;
                        busy <= 1'b1;
                    end
                end
                
                S_INIT: begin
                    lb_clear <= 1'b1;
                    fetch_col <= 16'd0;
                    fetch_row_sel <= 1'b0;
                    byte_select <= 1'b0;
                    // Calculate first source row needed
                    target_row_y[0] <= 16'd0;
                    target_row_y[1] <= 16'd1;
                    // Set fetch address for row 0
                    fetch_addr <= img_in_addr;
                end
                
                S_FETCH_ROW0, S_FETCH_ROW1: begin
                    fetch_row_sel <= (state == S_FETCH_ROW1);
                    
                    if (!sdram_waitrequest && !sdram_readdatavalid) begin
                        // Issue read
                        sdram_read <= 1'b1;
                        if (state == S_FETCH_ROW0)
                            sdram_address <= img_in_addr + (target_row_y[0] * in_width) + {16'd0, fetch_col};
                        else
                            sdram_address <= img_in_addr + (target_row_y[1] * in_width) + {16'd0, fetch_col};
                    end
                    
                    if (sdram_readdatavalid) begin
                        // Write received byte(s) to line buffer
                        // SDRAM returns 16-bit, we process 2 pixels
                        lb_wr_en <= 1'b1;
                        lb_wr_row_sel <= fetch_row_sel;
                        lb_wr_col <= fetch_col;
                        lb_wr_data <= sdram_readdata[7:0]; // Low byte first
                        
                        perf_mem_reads <= perf_mem_reads + 1;
                        
                        // Handle second byte on next cycle
                        pending_byte <= sdram_readdata[15:8];
                        byte_select <= 1'b1;
                        fetch_col <= fetch_col + 1;
                    end
                    
                    // Write pending high byte
                    if (byte_select && fetch_col < in_width[15:0]) begin
                        lb_wr_en <= 1'b1;
                        lb_wr_row_sel <= fetch_row_sel;
                        lb_wr_col <= fetch_col;
                        lb_wr_data <= pending_byte;
                        byte_select <= 1'b0;
                        fetch_col <= fetch_col + 1;
                    end
                    
                    // Reset for next row
                    if (state == S_FETCH_ROW0 && next_state == S_FETCH_ROW1) begin
                        fetch_col <= 16'd0;
                        byte_select <= 1'b0;
                    end
                end
                
                S_COMPUTE_COORD: begin
                    // Compute source coordinates for each lane
                    // Using precomputed combinational products (prod_x, prod_y)
                    // src_q8_8 = (out * inv_scale) >> 16
                    // where inv_scale is Q16.16 and result is Q8.8
                    // Take bits [31:16] for Q8.8 (16 bits shift from Q16.16)
                    for (int i = 0; i < LANES; i++) begin
                        src_x_q8[i] <= prod_x[i][31:16];
                        src_y_q8[i] <= prod_y[31:16];
                    end
                    current_lane <= 4'd0;
                end
                
                S_PACK_PIXELS: begin
                    // Extract pixels from line buffer for current lane
                    // src_x_q8 is Q8.8: [INT_MSB:INT_LSB] = integer, [FRAC_MSB:FRAC_LSB] = fraction
                    lb_rd_col <= src_x_q8[current_lane][INT_MSB:INT_LSB]; // Integer part
                    
                    // Store in lane registers
                    lane_p00[current_lane] <= lb_p00;
                    lane_p01[current_lane] <= lb_p01;
                    lane_p10[current_lane] <= lb_p10;
                    lane_p11[current_lane] <= lb_p11;
                    lane_frac_x[current_lane] <= src_x_q8[current_lane][FRAC_MSB:FRAC_LSB];
                    lane_frac_y[current_lane] <= src_y_q8[current_lane][FRAC_MSB:FRAC_LSB];
                    
                    current_lane <= current_lane + 1;
                end
                
                S_WAIT_PROCESS: begin
                    // Pack all lanes and signal valid
                    for (int i = 0; i < LANES; i++) begin
                        p00_packed[i*PIXEL_WIDTH +: PIXEL_WIDTH] <= lane_p00[i];
                        p01_packed[i*PIXEL_WIDTH +: PIXEL_WIDTH] <= lane_p01[i];
                        p10_packed[i*PIXEL_WIDTH +: PIXEL_WIDTH] <= lane_p10[i];
                        p11_packed[i*PIXEL_WIDTH +: PIXEL_WIDTH] <= lane_p11[i];
                        frac_x_packed[i*Q +: Q] <= lane_frac_x[i];
                        frac_y_packed[i*Q +: Q] <= lane_frac_y[i];
                    end
                    pixels_valid <= 1'b1;
                    write_lane <= 4'd0;
                end
                
                S_WRITE_PIXEL: begin
                    // Write result pixels to SDRAM
                    // current_pixel and current_write_addr are computed combinationally
                    
                    write_pixel <= current_pixel;
                    write_addr <= current_write_addr;
                    
                    // Write each pixel individually (8-bit writes)
                    // SDRAM interface is 16-bit, so we write to correct byte
                    sdram_write <= 1'b1;
                    sdram_address <= {current_write_addr[31:1], 1'b0}; // Align to 16-bit
                    
                    if (current_write_addr[0] == 1'b0) begin
                        // Even address: write to low byte
                        sdram_writedata <= {8'd0, current_pixel};
                        sdram_byteenable <= 2'b01;
                    end else begin
                        // Odd address: write to high byte
                        sdram_writedata <= {current_pixel, 8'd0};
                        sdram_byteenable <= 2'b10;
                    end
                end
                
                S_WAIT_WRITE: begin
                    if (!sdram_waitrequest) begin
                        perf_mem_writes <= perf_mem_writes + 1;
                        write_lane <= write_lane + 1;
                        sdram_byteenable <= 2'b11; // Restore for reads
                        
                        if (write_lane >= active_lanes - 1) begin
                            // All lanes written
                            progress <= progress + active_lanes;
                        end
                    end
                end
                
                S_NEXT_PIXEL: begin
                    // Advance to next output position
                    if (out_x + active_lanes >= out_width) begin
                        out_x <= 32'd0;
                        out_y <= out_y + 1;
                        // Update target rows for next line
                        target_row_y[0] <= target_row_y[1];
                        target_row_y[1] <= target_row_y[1] + 1;
                        fetch_col <= 16'd0;
                    end else begin
                        out_x <= out_x + active_lanes;
                    end
                    
                    // Rotate debug lane selector
                    if (dbg_lane_sel >= active_lanes - 1)
                        dbg_lane_sel <= 4'd0;
                    else
                        dbg_lane_sel <= dbg_lane_sel + 1;
                end
                
                S_WAIT_STEP: begin
                    // Wait for step_once pulse
                end
                
                S_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end
                
                S_ERROR: begin
                    busy <= 1'b0;
                    errors <= errors + 1;
                end
            endcase
        end
    end
    
    //=======================================================
    // SDRAM Interface - Byte Enable managed in FSM
    // Note: sdram_byteenable is now set in S_WRITE_PIXEL state
    //=======================================================
    
    //=======================================================
    // Debug Outputs (rotated by lane_index)
    // src_x_q8 is Q8.8: [15:8] = integer, [7:0] = fraction
    //=======================================================
    assign dbg_fsm_state = state;
    assign dbg_out_x = out_x[15:0];
    assign dbg_out_y = out_y[15:0];
    assign dbg_src_x_int = {{Q{1'b0}}, src_x_q8[dbg_lane_sel][INT_MSB:INT_LSB]};
    assign dbg_src_y_int = {{Q{1'b0}}, src_y_q8[dbg_lane_sel][INT_MSB:INT_LSB]};
    assign dbg_frac_x = lane_frac_x[dbg_lane_sel];
    assign dbg_frac_y = lane_frac_y[dbg_lane_sel];
    assign dbg_p00 = lane_p00[dbg_lane_sel];
    assign dbg_p01 = lane_p01[dbg_lane_sel];
    assign dbg_p10 = lane_p10[dbg_lane_sel];
    assign dbg_p11 = lane_p11[dbg_lane_sel];
    assign dbg_out_pixel = result_pixels[dbg_lane_sel*PIXEL_WIDTH +: PIXEL_WIDTH];
    assign dbg_lane_index = dbg_lane_sel;

endmodule
