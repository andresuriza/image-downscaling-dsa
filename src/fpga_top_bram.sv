// Top-level module for FPGA synthesis with SDRAM interface
module fpga_top_bram (
    // Clock and Reset
    input logic clk,
    input logic rst_n,

    // JTAG/Host Interface (for controlling the process)
    input logic start,
    output logic done,
    output logic busy,

    // Avalon Memory-Mapped Interface for SDRAM
    output logic [31:0] avs_address,
    output logic [3:0]  avs_burstcount,
    output logic [7:0]  avs_byteenable,
    output logic        avs_read,
    input  logic [63:0] avs_readdata,
    output logic        avs_write,
    output logic [63:0] avs_writedata,
    input  logic        avs_waitrequest
);

    // Parameters for a 512x512 -> 256x256 downscale
    localparam IN_W = 512;
    localparam IN_H = 512;
    localparam OUT_W = 256;
    localparam OUT_H = 256;
    localparam LANES = 8;
    localparam Q = 8;

    // Base addresses for images in SDRAM (assumes 64-bit aligned data)
    localparam IMG_IN_BASE_ADDR  = 32'h00000000;
    localparam IMG_OUT_BASE_ADDR = 32'h00040000; // Place output image after input image

    // Wires for DUT interface
    logic [31:0] in_width_w, in_height_w;
    logic [31:0] out_width_w, out_height_w;
    logic [31:0] scale_q8_8_w;
    logic [1:0]  mode_w;
    logic        dut_busy_w;
    logic [LANES*8-1:0] p00_w, p01_w, p10_w, p11_w;
    logic [LANES*Q-1:0] fracx_w, fracy_w;
    logic [LANES*8-1:0] out_vec_w;
    logic        out_valid_w;

    // Instantiate the downscaler
    simd_downscaler #(.LANES(LANES), .Q(Q)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start),
        .in_width(in_width_w), .in_height(in_height_w),
        .out_width(out_width_w), .out_height(out_height_w),
        .scale_q8_8(scale_q8_8_w),
        .mode(mode_w),
        .busy(dut_busy_w),
        .progress(), .errors(), .perf_flops(), .perf_mem_reads(), .perf_mem_writes(), // Unused outputs
        .p00_packed(p00_w),
        .p01_packed(p01_w),
        .p10_packed(p10_w),
        .p11_packed(p11_w),
        .frac_x_packed(fracx_w),
        .frac_y_packed(fracy_w),
        .out_pixels_packed(out_vec_w),
        .out_valid(out_valid_w)
    );

    // --- Control Logic ---
    assign in_width_w  = IN_W;
    assign in_height_w = IN_H;
    assign out_width_w = OUT_W;
    assign out_height_w = OUT_H;
    assign mode_w = 0; // SIMD mode
    assign scale_q8_8_w = ((IN_W - 1) * 256) / (OUT_W - 1);
    
    // FSM to drive the DUT and SDRAM interfaces
    typedef enum logic [2:0] {
        IDLE,
        READ_PIXELS,
        WAIT_READ_DATA,
        CALCULATE,
        WRITE_PIXELS,
        FINISH
    } state_t;
    state_t state, next_state;

    integer out_pixel_idx;
    integer read_pixel_idx;

    // State machine for overall control
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            out_pixel_idx <= 0;
            read_pixel_idx <= 0;
        end else begin
            state <= next_state;
            // Update counters based on state transitions
            if (next_state == READ_PIXELS) begin
                read_pixel_idx <= read_pixel_idx + LANES;
            end
            if (out_valid_w) begin
                out_pixel_idx <= out_pixel_idx + LANES;
            end
            if (next_state == IDLE) begin
                 out_pixel_idx <= 0;
                 read_pixel_idx <= 0;
            end
        end
    end

    // --- Data Path and SDRAM Interface Logic ---
    // This section is simplified and needs to be fully implemented
    // It requires a careful state machine to handle Avalon bus transactions.
    
    // For now, let's stub out the main logic.
    // A complete implementation will require more states to handle memory latency.
    always_comb begin
        next_state = state;
        done = 0;
        busy = (state != IDLE && state != FINISH);

        // Default assignments for Avalon bus
        avs_address = 0;
        avs_read = 0;
        avs_write = 0;
        avs_writedata = 0;
        avs_burstcount = 4'd1; // Read one 64-bit word at a time
        avs_byteenable = 8'hFF; // Enable all 8 bytes

        // Reset pixel data to avoid latches
        p00_w = 0; p01_w = 0; p10_w = 0; p11_w = 0;
        fracx_w = 0; fracy_w = 0;

        case(state)
            IDLE: begin
                if (start) begin
                    next_state = READ_PIXELS;
                end
            end
            READ_PIXELS: begin
                // State to calculate addresses and issue reads for the next set of pixels
                // This is a simplified example. A real implementation would need to handle
                // the case where x1 and y1 cross row boundaries and require more reads.
                // For now, we assume we can get all necessary pixels in one go.
                // In reality, this state would set up addresses for multiple reads.
                next_state = WAIT_READ_DATA;
            end
            WAIT_READ_DATA: begin
                // Wait for avs_readdata to be valid
                if (!avs_waitrequest) begin
                    // Process the read data here
                    // This is where you would unpack avs_readdata into p00_w, p01_w, etc.
                    next_state = CALCULATE;
                end
            end
            CALCULATE: begin
                // Data is ready, let the DUT process it
                // The DUT will assert out_valid_w when done
                if (out_valid_w) begin
                    next_state = WRITE_PIXELS;
                end
            end
            WRITE_PIXELS: begin
                // Write the result from out_vec_w to SDRAM
                avs_write = 1;
                avs_address = IMG_OUT_BASE_ADDR + (out_pixel_idx * 8); // Assuming 64-bit writes
                avs_writedata = out_vec_w;

                if (!avs_waitrequest) begin
                    if (out_pixel_idx + LANES >= OUT_W * OUT_H) begin
                        next_state = FINISH;
                    end else begin
                        next_state = READ_PIXELS;
                    end
                end
            end
            FINISH: begin
                done = 1;
                next_state = IDLE;
            end
        endcase
    end

endmodule
