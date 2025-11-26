module communication_interface #(
    parameter int LANES = 8
)(
    input  logic clk,
    input  logic rst_n,
    
    // JTAG/UART interface
    input  logic uart_rx,
    output logic uart_tx,
    input  logic [7:0] jtag_data_in,
    output logic [7:0] jtag_data_out,
    input  logic jtag_valid,
    output logic jtag_ready,
    
    // Control registers
    output logic [31:0] control_reg,
    output logic [31:0] status_reg,
    output logic [31:0] image_width,
    output logic [31:0] image_height,
    output logic [31:0] scale_factor,
    output logic [1:0] operation_mode,
    output logic step_advance,
    output logic start_processing,
    
    // Status inputs
    input  logic [31:0] progress_count,
    input  logic [31:0] error_count,
    input  logic [63:0] performance_flops,
    input  logic [63:0] performance_reads,
    input  logic [63:0] performance_writes,
    input  logic [2:0] fsm_state,
    input  logic system_busy
);

    // Register file
    logic [31:0] registers [0:31];
    
    // Command processing
    typedef enum logic [7:0] {
        CMD_READ_REG = 8'h01,
        CMD_WRITE_REG = 8'h02,
        CMD_START_PROC = 8'h03,
        CMD_STEP = 8'h04,
        CMD_READ_STATUS = 8'h05
    } command_t;
    
    // Map registers to outputs
    assign control_reg = registers[0];
    assign status_reg = registers[1];
    assign image_width = registers[2];
    assign image_height = registers[3];
    assign scale_factor = registers[4];
    assign operation_mode = registers[5][1:0];
    
    assign start_processing = registers[0][0];
    assign step_advance = registers[0][1];
    
    // Update status register
    always_comb begin
        registers[1] = {28'b0, fsm_state};
        if (system_busy) registers[1][7] = 1'b1;
        registers[1][8] = (error_count > 0);
    end
    
    // Command processing state machine
    // This would include UART/JTAG protocol handling
    // Simplified implementation
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Initialize registers
            for (int i = 0; i < 32; i++) begin
                registers[i] <= '0;
            end
        end else if (jtag_valid) begin
            // Process JTAG commands
            // This is a simplified version - implement full protocol
            case (jtag_data_in[7:6])
                2'b00: begin // Read register
                    // Implementation for register read
                end
                2'b01: begin // Write register
                    // Implementation for register write
                end
                2'b10: begin // Control command
                    case (jtag_data_in[5:0])
                        6'h01: registers[0][0] <= 1'b1; // Start
                        6'h02: registers[0][1] <= 1'b1; // Step
                    endcase
                end
            endcase
        end
    end

endmodule