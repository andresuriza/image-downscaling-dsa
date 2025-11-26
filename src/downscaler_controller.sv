module downscaler_controller #(
    parameter int LANES = 8
)(
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic step_en,           // Stepping mode enable
    input  logic step_advance,      // Advance one step
    input  logic [31:0] in_width,
    input  logic [31:0] in_height,
    input  logic [31:0] out_width,
    input  logic [31:0] out_height,
    output logic busy,
    output logic [31:0] progress,
    output logic [1:0] state,
    
    // Memory interface
    output logic mem_rd_en,
    output logic [31:0] mem_rd_addr,
    input  logic [LANES*8-1:0] mem_rd_data,
    
    // SIMD interface
    output logic simd_start,
    input  logic simd_done,
    output logic [LANES*8-1:0] p00_packed,
    output logic [LANES*8-1:0] p01_packed,
    output logic [LANES*8-1:0] p10_packed,
    output logic [LANES*8-1:0] p11_packed,
    output logic [LANES*8-1:0] frac_x_packed,
    output logic [LANES*8-1:0] frac_y_packed
);

    typedef enum logic [2:0] {
        IDLE = 3'b000,
        FETCH_PIXELS = 3'b001,
        WAIT_MEMORY = 3'b010,
        COMPUTE = 3'b011,
        WRITE_RESULT = 3'b100,
        DONE = 3'b101
    } state_t;
    
    state_t current_state, next_state;
    
    // Coordinates counters
    logic [31:0] out_x, out_y;
    logic [31:0] base_x, base_y;
    
    // Stepping control
    logic step_pending;
    logic step_granted;
    
    assign step_granted = step_en ? step_advance : 1'b1;
    
    // State register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_state <= IDLE;
            out_x <= '0;
            out_y <= '0;
            base_x <= '0;
            base_y <= '0;
            step_pending <= 1'b0;
        end else begin
            if (step_granted || !step_en) begin
                current_state <= next_state;
                step_pending <= 1'b0;
                
                // Update coordinates
                if (current_state == WRITE_RESULT) begin
                    if (base_x + LANES >= out_width) begin
                        base_x <= '0;
                        if (base_y >= out_height - 1) begin
                            base_y <= '0;
                        end else begin
                            base_y <= base_y + 1;
                        end
                    end else begin
                        base_x <= base_x + LANES;
                    end
                end
            end else if (step_advance) begin
                step_pending <= 1'b1;
            end
        end
    end
    
    // Next state logic
    always_comb begin
        next_state = current_state;
        case (current_state)
            IDLE: if (start) next_state = FETCH_PIXELS;
            FETCH_PIXELS: next_state = WAIT_MEMORY;
            WAIT_MEMORY: next_state = COMPUTE;
            COMPUTE: if (simd_done) next_state = WRITE_RESULT;
            WRITE_RESULT: begin
                if (base_y >= out_height - 1 && base_x + LANES >= out_width)
                    next_state = DONE;
                else
                    next_state = FETCH_PIXELS;
            end
            DONE: if (!start) next_state = IDLE;
        endcase
    end
    
    // Output logic
    assign busy = (current_state != IDLE && current_state != DONE);
    assign progress = (out_y * out_width) + out_x;
    assign state = current_state[1:0];
    
    // Memory control
    assign mem_rd_en = (current_state == FETCH_PIXELS);
    
    // SIMD control
    assign simd_start = (current_state == WAIT_MEMORY);
    
    // Coordinate calculation for current LANES
    // This would include logic to compute src coordinates and fractional parts
    // similar to your testbench but for hardware implementation
    
endmodule