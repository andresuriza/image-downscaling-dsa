module bit_exact_validator #(
    parameter int LANES = 8,
    parameter int Q = 8
)(
    input  logic clk,
    input  logic rst_n,
    
    // Hardware results
    input  logic [LANES*8-1:0] hw_results,
    input  logic hw_valid,
    
    // Reference results (from C++ model)
    input  logic [LANES*8-1:0] ref_results,
    input  logic ref_valid,
    
    // Control
    input  logic start_validation,
    output logic validation_done,
    output logic [31:0] error_count,
    output logic [31:0] total_compared
);

    logic [31:0] error_counter;
    logic [31:0] total_counter;
    logic validating;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            error_counter <= '0;
            total_counter <= '0;
            validating <= 1'b0;
            validation_done <= 1'b0;
        end else begin
            if (start_validation) begin
                validating <= 1'b1;
                validation_done <= 1'b0;
                error_counter <= '0;
                total_counter <= '0;
            end
            
            if (validating && hw_valid && ref_valid) begin
                total_counter <= total_counter + LANES;
                
                // Compare each lane
                for (int i = 0; i < LANES; i++) begin
                    if (hw_results[i*8 +: 8] !== ref_results[i*8 +: 8]) begin
                        error_counter <= error_counter + 1;
                    end
                end
                
                // Check if validation complete (based on your image size)
                if (total_counter >= (512*512)) begin
                    validating <= 1'b0;
                    validation_done <= 1'b1;
                end
            end
        end
    end
    
    assign error_count = error_counter;
    assign total_compared = total_counter;

endmodule