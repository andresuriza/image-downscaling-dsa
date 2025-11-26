module performance_counters #(
    parameter int LANES = 8
)(
    input  logic clk,
    input  logic rst_n,
    
    // Event inputs
    input  logic computation_cycle,
    input  logic memory_read,
    input  logic memory_write,
    input  logic simd_operation,
    input  logic sequential_operation,
    
    // Control
    input  logic clear_counters,
    
    // Output counters
    output logic [63:0] total_cycles,
    output logic [63:0] compute_cycles,
    output logic [63:0] memory_reads,
    output logic [63:0] memory_writes,
    output logic [63:0] total_flops,
    output logic [63:0] simd_throughput,
    output logic [63:0] sequential_throughput
);

    // Cycle counters
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_cycles <= '0;
            compute_cycles <= '0;
            memory_reads <= '0;
            memory_writes <= '0;
            total_flops <= '0;
        end else if (clear_counters) begin
            total_cycles <= '0;
            compute_cycles <= '0;
            memory_reads <= '0;
            memory_writes <= '0;
            total_flops <= '0;
        end else begin
            total_cycles <= total_cycles + 1;
            
            if (computation_cycle) begin
                compute_cycles <= compute_cycles + 1;
                // Each SIMD operation does 4 multiplications and 3 additions per lane
                total_flops <= total_flops + (LANES * 7);
            end
            
            if (memory_read) memory_reads <= memory_reads + 1;
            if (memory_write) memory_writes <= memory_writes + 1;
        end
    end
    
    // Throughput calculation
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            simd_throughput <= '0;
            sequential_throughput <= '0;
        end else begin
            // Calculate pixels per cycle
            if (compute_cycles > 0) begin
                simd_throughput <= (total_cycles > 0) ? 
                    (memory_writes * 64'd1000) / total_cycles : '0;
            end
        end
    end

endmodule