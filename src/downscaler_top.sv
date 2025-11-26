module downscaler_top #(
    parameter int LANES = 8,
    parameter int Q = 8
)(
    input  logic clk,
    input  logic rst_n,
    
    // Communication interface
    input  logic uart_rx,
    output logic uart_tx,
    
    // Control inputs
    input  logic [31:0] control_word,
    input  logic step_advance,
    
    // Status outputs
    output logic [31:0] status_word,
    output logic [63:0] performance_counters
);

    // Internal signals
    logic start_processing;
    logic system_busy;
    logic [1:0] operation_mode;
    logic [31:0] progress;
    logic [31:0] errors;
    
    // FSM state
    logic [2:0] fsm_state;
    
    // Performance counters
    logic [63:0] flops_counter;
    logic [63:0] reads_counter; 
    logic [63:0] writes_counter;
    
    // Instantiate controller
    downscaler_controller #(.LANES(LANES)) controller (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_processing),
        .step_en(control_word[1]),
        .step_advance(step_advance),
        .in_width(/* from registers */),
        .in_height(/* from registers */),
        .out_width(/* from registers */),
        .out_height(/* from registers */),
        .busy(system_busy),
        .progress(progress),
        .state(fsm_state)
        // ... other connections
    );
    
    // Instantiate SIMD downscaler
    simd_downscaler #(.LANES(LANES), .Q(Q)) downscaler (
        .clk(clk),
        .rst_n(rst_n),
        .start(/* from controller */),
        .busy(/* to controller */)
        // ... other connections
    );
    
    // Instantiate communication interface
    communication_interface #(.LANES(LANES)) comm_interface (
        .clk(clk),
        .rst_n(rst_n),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .start_processing(start_processing),
        .step_advance(step_advance),
        .status_word(status_word),
        .fsm_state(fsm_state),
        .system_busy(system_busy)
    );
    
    // Assign status word
    assign status_word = {
        16'b0,
        fsm_state,
        system_busy,
        (errors > 0),
        progress[7:0]
    };

endmodule