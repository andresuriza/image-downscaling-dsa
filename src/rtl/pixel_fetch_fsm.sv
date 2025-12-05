//=======================================================
// Simplified Pixel Fetch FSM
// Direct SDRAM fetch without line buffering
// Trades memory bandwidth for simpler timing
//
// For each output pixel:
//   1. Compute source coordinates
//   2. Fetch 4 neighbor pixels from SDRAM (p00, p01, p10, p11)
//   3. Send to downscaler
//   4. Write result to SDRAM
//=======================================================

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
    
    // Debug
    output logic [3:0]  dbg_fsm_state,
    output logic [15:0] dbg_out_x,
    output logic [15:0] dbg_out_y,
    output logic [15:0] dbg_src_x_int,
    output logic [15:0] dbg_src_y_int,
    output logic [Q-1:0] dbg_frac_x,
    output logic [Q-1:0] dbg_frac_y,
    output logic [7:0]  dbg_p00, dbg_p01, dbg_p10, dbg_p11,
    output logic [7:0]  dbg_out_pixel,
    output logic [3:0]  dbg_lane_index,
    
    // SDRAM Master
    output logic [31:0] sdram_address,
    output logic        sdram_read,
    output logic        sdram_write,
    output logic [15:0] sdram_writedata,
    input  logic [15:0] sdram_readdata,
    input  logic        sdram_waitrequest,
    input  logic        sdram_readdatavalid,
    output logic [1:0]  sdram_byteenable,
    
    // Downscaler Interface
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
    // Simplified FSM - 8 states including stepping
    //=======================================================
    typedef enum logic [3:0] {
        S_IDLE      = 4'd0,
        S_COMPUTE   = 4'd1,  // Compute source coords
        S_FETCH     = 4'd2,  // Fetch 4 pixels (sequential)
        S_PROCESS   = 4'd3,  // Wait for downscaler
        S_WRITE     = 4'd4,  // Write result
        S_NEXT      = 4'd5,  // Advance to next pixel
        S_DONE      = 4'd6,
        S_WAIT_STEP = 4'd7   // Wait for step_once when stepping
    } state_t;
    
    state_t state;
    
    //=======================================================
    // Registers
    //=======================================================
    // Output coordinates
    logic [15:0] out_x, out_y;
    
    // Source coordinates Q8.8
    logic [15:0] src_x, src_y;
    logic [7:0]  frac_x, frac_y;
    logic [15:0] src_x_int, src_y_int;
    
    // Fetched pixels
    logic [7:0] p00, p01, p10, p11;
    logic [1:0] fetch_phase;  // 0=p00, 1=p01, 2=p10, 3=p11
    logic       read_pending; // Track if a read request is in flight
    logic       write_pending; // Track if a write request is in flight
    
    // Pixel reuse state (for horizontal adjacency optimization)
    logic [15:0] prev_src_x_int;  // Previous pixel's source X coordinate
    logic [15:0] prev_src_y_int;  // Previous pixel's source Y coordinate  
    logic        prev_valid;      // Previous pixel data is valid for reuse
    logic        can_reuse;       // Current pixel can reuse previous data
    
    // Pipeline valid
    logic process_started;
    logic [1:0] process_countdown;
    
    // Mode
    localparam MODE_SIMD = 2'd0;
    localparam MODE_SERIAL = 2'd1;
    
    //=======================================================
    // Coordinate calculation
    // Formula: src_coord = out_coord / scale (matching C reference)
    // Implementation: src_q8 = (out_coord << 16) / scale_q8_8
    // Result is in Q16.8 format (16-bit integer, 8-bit fraction)
    // scale_q8_8 is in Q8.8: integer[15:8], fraction[7:0]
    //=======================================================
    logic [31:0] dividend_x, dividend_y;
    logic [31:0] src_coord_x_q8, src_coord_y_q8;
    
    // Prepare dividends: out_coord << 16
    assign dividend_x = {out_x, 16'd0};
    assign dividend_y = {out_y, 16'd0};
    
    // Division: (out_coord << 16) / scale_q8_8 = src_coord in Q24.8
    // Note: This is combinational division - synthesizes to LUT-based divider
    assign src_coord_x_q8 = (scale_q8_8[15:0] != 0) ? (dividend_x / scale_q8_8[15:0]) : 32'd0;
    assign src_coord_y_q8 = (scale_q8_8[15:0] != 0) ? (dividend_y / scale_q8_8[15:0]) : 32'd0;
    
    // Extract integer and fractional parts from result
    // In C: src_int = src_q8 >> 8 (equivalent to bits [31:8])
    // Result format: integer in bits [23:8] for images up to 64K, fraction in bits [7:0]
    // src_x_int is 16 bits, we take bits [23:8] to get the integer part
    assign src_x_int = src_coord_x_q8[23:8];
    assign src_y_int = src_coord_y_q8[23:8];
    assign frac_x = src_coord_x_q8[7:0];
    assign frac_y = src_coord_y_q8[7:0];
    
    //=======================================================
    // Address calculation for 4 neighbor pixels
    // Use 32-bit arithmetic to avoid overflow for large images
    //=======================================================
    logic [31:0] addr_p00, addr_p01, addr_p10, addr_p11;
    logic [31:0] addr_out;  // Output pixel address
    logic [31:0] x0, x1, y0, y1;  // 32-bit to avoid overflow in multiplication
    
    // Clamp coordinates to image bounds (matching C reference)
    // First clamp x0/y0 to valid range, then compute x1/y1
    wire [31:0] x0_raw = {16'd0, src_x_int};
    wire [31:0] y0_raw = {16'd0, src_y_int};
    assign x0 = (x0_raw >= in_width) ? in_width - 32'd1 : x0_raw;
    assign y0 = (y0_raw >= in_height) ? in_height - 32'd1 : y0_raw;
    assign x1 = (x0 + 1 < in_width) ? x0 + 32'd1 : in_width - 32'd1;
    assign y1 = (y0 + 1 < in_height) ? y0 + 32'd1 : in_height - 32'd1;
    
    // Pixel addresses (row-major layout) - all 32-bit arithmetic
    assign addr_p00 = img_in_addr + y0 * in_width + x0;
    assign addr_p01 = img_in_addr + y0 * in_width + x1;
    assign addr_p10 = img_in_addr + y1 * in_width + x0;
    assign addr_p11 = img_in_addr + y1 * in_width + x1;
    
    // Output address - all 32-bit arithmetic
    assign addr_out = img_out_addr + {16'd0, out_y} * out_width + {16'd0, out_x};
    
    //=======================================================
    // Main FSM
    //=======================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
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
            p00 <= 8'd0;
            p01 <= 8'd0;
            p10 <= 8'd0;
            p11 <= 8'd0;
            fetch_phase <= 2'd0;
            read_pending <= 1'b0;
            write_pending <= 1'b0;
            sdram_read <= 1'b0;
            sdram_write <= 1'b0;
            pixels_valid <= 1'b0;
            process_started <= 1'b0;
            process_countdown <= 2'd0;
            prev_src_x_int <= 16'd0;
            prev_src_y_int <= 16'd0;
            prev_valid <= 1'b0;
        end else if (abort) begin
            state <= S_IDLE;
            busy <= 1'b0;
            read_pending <= 1'b0;
            write_pending <= 1'b0;
            sdram_read <= 1'b0;
            sdram_write <= 1'b0;
            pixels_valid <= 1'b0;
            prev_valid <= 1'b0;
        end else begin
            // Defaults (only for signals that should pulse)
            done <= 1'b0;
            
            case (state)
                S_IDLE: begin
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
                        // If stepping mode, wait for step_once before first compute
                        if (step_enable) begin
                            state <= S_WAIT_STEP;
                        end else begin
                            state <= S_COMPUTE;
                        end
                    end
                end
                
                S_COMPUTE: begin
                    // Coordinates computed combinationally, wait 1 cycle
                    // Check if we can reuse pixels from previous output pixel
                    // Reuse condition: same row (src_y unchanged) and src_x incremented by 1
                    can_reuse <= prev_valid && 
                                 (src_x_int == prev_src_x_int + 16'd1) && 
                                 (src_y_int == prev_src_y_int);
                    
                    read_pending <= 1'b0;
                    sdram_read <= 1'b0;
                    sdram_write <= 1'b0;
                    
                    if (prev_valid && 
                        (src_x_int == prev_src_x_int + 16'd1) && 
                        (src_y_int == prev_src_y_int)) begin
                        // Reuse: p01->p00, p11->p10, only fetch new p01 and p11
                        p00 <= p01;
                        p10 <= p11;
                        fetch_phase <= 2'd1;  // Start from phase 1 (fetch p01)
                        perf_pixel_reuse <= perf_pixel_reuse + 1;
                    end else begin
                        // No reuse: fetch all 4 pixels
                        fetch_phase <= 2'd0;
                    end
                    state <= S_FETCH;
                end
                
                S_FETCH: begin
                    // Fetch neighbor pixels sequentially
                    // With reuse: only fetch p01 (phase 1) and p11 (phase 3), skip p00 and p10
                    // Without reuse: fetch all 4 (phases 0,1,2,3)
                    //
                    // State machine for each pixel read:
                    //   1. Issue read request (sdram_read=1) with address
                    //   2. Wait for waitrequest to go low (request accepted)
                    //   3. Deassert sdram_read after accepted
                    //   4. Wait for readdatavalid
                    //   5. Store data and move to next phase
                    
                    if (!read_pending) begin
                        // Issue new read request
                        sdram_read <= 1'b1;
                        sdram_byteenable <= 2'b11;
                        
                        case (fetch_phase)
                            2'd0: sdram_address <= {addr_p00[31:1], 1'b0};
                            2'd1: sdram_address <= {addr_p01[31:1], 1'b0};
                            2'd2: sdram_address <= {addr_p10[31:1], 1'b0};
                            2'd3: sdram_address <= {addr_p11[31:1], 1'b0};
                        endcase
                        
                        // Request accepted when waitrequest is low
                        if (!sdram_waitrequest) begin
                            read_pending <= 1'b1;
                            sdram_read <= 1'b0;  // Deassert after accepted
                        end
                    end else begin
                        // Read request is pending, wait for data
                        sdram_read <= 1'b0;
                    end
                    
                    if (sdram_readdatavalid) begin
                        perf_mem_reads <= perf_mem_reads + 1;
                        read_pending <= 1'b0;  // Ready for next read
                        
                        // Store pixel (handle byte alignment)
                        case (fetch_phase)
                            2'd0: p00 <= addr_p00[0] ? sdram_readdata[15:8] : sdram_readdata[7:0];
                            2'd1: p01 <= addr_p01[0] ? sdram_readdata[15:8] : sdram_readdata[7:0];
                            2'd2: p10 <= addr_p10[0] ? sdram_readdata[15:8] : sdram_readdata[7:0];
                            2'd3: p11 <= addr_p11[0] ? sdram_readdata[15:8] : sdram_readdata[7:0];
                        endcase
                        
                        if (fetch_phase == 2'd3) begin
                            state <= S_PROCESS;
                            process_started <= 1'b0;
                            process_countdown <= 2'd3;  // Wait for pipeline
                        end else begin
                            // When reusing, skip from phase 1 to phase 3 (skip p10 fetch)
                            if (can_reuse && fetch_phase == 2'd1) begin
                                fetch_phase <= 2'd3;  // Skip phase 2 (p10 already set from p11_prev)
                            end else begin
                                fetch_phase <= fetch_phase + 1;
                            end
                        end
                    end
                end
                
                S_PROCESS: begin
                    // Ensure SDRAM signals are low during processing
                    sdram_read <= 1'b0;
                    sdram_write <= 1'b0;
                    
                    // Pack data for downscaler (only lane 0 for now)
                    p00_packed <= {24'd0, p00};
                    p01_packed <= {24'd0, p01};
                    p10_packed <= {24'd0, p10};
                    p11_packed <= {24'd0, p11};
                    frac_x_packed <= {{(LANES-1)*Q{1'b0}}, frac_x};
                    frac_y_packed <= {{(LANES-1)*Q{1'b0}}, frac_y};
                    
                    // Pulse valid for one cycle to start pipeline
                    if (!process_started) begin
                        pixels_valid <= 1'b1;
                        process_started <= 1'b1;
                    end else begin
                        pixels_valid <= 1'b0;
                    end
                    
                    // Count down pipeline latency
                    if (process_countdown > 0) begin
                        process_countdown <= process_countdown - 1;
                    end
                    
                    // Wait for result (or timeout via countdown)
                    if (result_valid || process_countdown == 0) begin
                        state <= S_WRITE;
                    end
                end
                
                S_WRITE: begin
                    // Write result pixel to SDRAM
                    // Issue write request and wait for acceptance
                    if (!write_pending) begin
                        sdram_write <= 1'b1;
                        sdram_address <= {addr_out[31:1], 1'b0};
                        sdram_byteenable <= addr_out[0] ? 2'b10 : 2'b01;
                        sdram_writedata <= addr_out[0] ? 
                                           {result_pixels[7:0], 8'd0} : {8'd0, result_pixels[7:0]};
                        
                        // Request accepted when waitrequest is low
                        if (!sdram_waitrequest) begin
                            write_pending <= 1'b1;
                            sdram_write <= 1'b0;
                            state <= S_NEXT;
                            perf_mem_writes <= perf_mem_writes + 1;
                        end
                    end
                end
                
                S_NEXT: begin
                    write_pending <= 1'b0;  // Reset for next pixel
                    sdram_read <= 1'b0;
                    sdram_write <= 1'b0;
                    progress <= progress + 1;
                    
                    // Save current source coordinates for potential reuse
                    prev_src_x_int <= src_x_int;
                    prev_src_y_int <= src_y_int;
                    prev_valid <= 1'b1;
                    
                    // Advance coordinates
                    if (out_x + 1 >= out_width[15:0]) begin
                        out_x <= 16'd0;
                        prev_valid <= 1'b0;  // Invalidate reuse on new row
                        if (out_y + 1 >= out_height[15:0]) begin
                            state <= S_DONE;
                        end else begin
                            out_y <= out_y + 1;
                            // If stepping mode, wait for step_once before next pixel
                            if (step_enable) begin
                                state <= S_WAIT_STEP;
                            end else begin
                                state <= S_COMPUTE;
                            end
                        end
                    end else begin
                        out_x <= out_x + 1;
                        // If stepping mode, wait for step_once before next pixel
                        if (step_enable) begin
                            state <= S_WAIT_STEP;
                        end else begin
                            state <= S_COMPUTE;
                        end
                    end
                end
                
                S_WAIT_STEP: begin
                    // Wait for step_once pulse to proceed to S_COMPUTE
                    sdram_read <= 1'b0;
                    sdram_write <= 1'b0;
                    pixels_valid <= 1'b0;
                    if (step_once || !step_enable) begin
                        state <= S_COMPUTE;
                    end
                end
                
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
    
    //=======================================================
    // Debug outputs
    //=======================================================
    assign dbg_fsm_state = state;
    assign dbg_out_x = out_x;
    assign dbg_out_y = out_y;
    assign dbg_src_x_int = src_x_int;
    assign dbg_src_y_int = src_y_int;
    assign dbg_frac_x = frac_x;
    assign dbg_frac_y = frac_y;
    assign dbg_p00 = p00;
    assign dbg_p01 = p01;
    assign dbg_p10 = p10;
    assign dbg_p11 = p11;
    assign dbg_out_pixel = result_pixels[7:0];
    assign dbg_lane_index = 4'd0;

endmodule
