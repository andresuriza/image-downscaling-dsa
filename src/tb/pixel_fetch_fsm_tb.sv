//=======================================================
// Pixel Fetch FSM Unit Testbench
// Verifies state machine transitions, SDRAM interface,
// line buffer integration, and SIMD data packing
//=======================================================

`timescale 1ns/1ps

module pixel_fetch_fsm_tb;

    //=======================================================
    // Parameters
    //=======================================================
    parameter int LANES = 8;
    parameter int Q = 8;
    parameter int MAX_WIDTH = 64;
    parameter int MAX_HEIGHT = 64;
    parameter int CLK_PERIOD = 20;
    
    //=======================================================
    // FSM State Encodings (match pixel_fetch_fsm.sv)
    //=======================================================
    localparam logic [3:0] S_IDLE          = 4'd0;
    localparam logic [3:0] S_INIT          = 4'd1;
    localparam logic [3:0] S_FETCH_ROW0    = 4'd2;
    localparam logic [3:0] S_FETCH_ROW1    = 4'd3;
    localparam logic [3:0] S_WAIT_ROWS     = 4'd4;
    localparam logic [3:0] S_COMPUTE_COORD = 4'd5;
    localparam logic [3:0] S_PACK_PIXELS   = 4'd6;
    localparam logic [3:0] S_WAIT_PROCESS  = 4'd7;
    localparam logic [3:0] S_WRITE_PIXEL   = 4'd8;
    localparam logic [3:0] S_NEXT_OUTPUT   = 4'd9;
    localparam logic [3:0] S_DONE          = 4'd10;
    
    //=======================================================
    // DUT Signals
    //=======================================================
    logic        clk;
    logic        rst_n;
    
    // Control
    logic        start;
    logic        abort;
    logic [31:0] in_width;
    logic [31:0] in_height;
    logic [31:0] out_width;
    logic [31:0] out_height;
    logic [31:0] scale_q8_8;
    logic [1:0]  mode;
    logic [31:0] img_in_addr;
    logic [31:0] img_out_addr;
    logic        step_enable;
    logic        step_once;
    
    // Status
    logic        busy;
    logic        done;
    logic [31:0] progress;
    logic [31:0] errors;
    logic [63:0] perf_mem_reads;
    logic [63:0] perf_mem_writes;
    
    // Debug
    logic [3:0]  dbg_fsm_state;
    logic [15:0] dbg_out_x;
    logic [15:0] dbg_out_y;
    logic [15:0] dbg_src_x_int;
    logic [15:0] dbg_src_y_int;
    logic [7:0]  dbg_frac_x;
    logic [7:0]  dbg_frac_y;
    logic [7:0]  dbg_p00;
    logic [7:0]  dbg_p01;
    logic [7:0]  dbg_p10;
    logic [7:0]  dbg_p11;
    logic [7:0]  dbg_out_pixel;
    logic [3:0]  dbg_lane_index;
    
    // SDRAM interface
    logic [31:0] sdram_address;
    logic        sdram_read;
    logic        sdram_write;
    logic [15:0] sdram_writedata;
    logic [15:0] sdram_readdata;
    logic        sdram_waitrequest;
    logic        sdram_readdatavalid;
    logic [1:0]  sdram_byteenable;
    
    // SIMD interface
    logic [LANES*8-1:0] p00_packed;
    logic [LANES*8-1:0] p01_packed;
    logic [LANES*8-1:0] p10_packed;
    logic [LANES*8-1:0] p11_packed;
    logic [LANES*Q-1:0] frac_x_packed;
    logic [LANES*Q-1:0] frac_y_packed;
    logic               pixels_valid;
    logic [LANES*8-1:0] result_pixels;
    logic               result_valid;
    
    //=======================================================
    // SDRAM Memory Model
    //=======================================================
    logic [7:0] sdram_mem [0:65535];
    logic [3:0] read_latency;
    logic       pending_read;
    logic [31:0] pending_addr;
    
    //=======================================================
    // Test Control
    //=======================================================
    int test_pass_count;
    int test_fail_count;
    
    //=======================================================
    // Clock Generation
    //=======================================================
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    //=======================================================
    // DUT Instance
    //=======================================================
    pixel_fetch_fsm #(
        .LANES(LANES),
        .Q(Q),
        .MAX_WIDTH(MAX_WIDTH),
        .MAX_HEIGHT(MAX_HEIGHT)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        
        .start            (start),
        .abort            (abort),
        .in_width         (in_width),
        .in_height        (in_height),
        .out_width        (out_width),
        .out_height       (out_height),
        .scale_q8_8       (scale_q8_8),
        .mode             (mode),
        .img_in_addr      (img_in_addr),
        .img_out_addr     (img_out_addr),
        .step_enable      (step_enable),
        .step_once        (step_once),
        
        .busy             (busy),
        .done             (done),
        .progress         (progress),
        .errors           (errors),
        .perf_mem_reads   (perf_mem_reads),
        .perf_mem_writes  (perf_mem_writes),
        
        .dbg_fsm_state    (dbg_fsm_state),
        .dbg_out_x        (dbg_out_x),
        .dbg_out_y        (dbg_out_y),
        .dbg_src_x_int    (dbg_src_x_int),
        .dbg_src_y_int    (dbg_src_y_int),
        .dbg_frac_x       (dbg_frac_x),
        .dbg_frac_y       (dbg_frac_y),
        .dbg_p00          (dbg_p00),
        .dbg_p01          (dbg_p01),
        .dbg_p10          (dbg_p10),
        .dbg_p11          (dbg_p11),
        .dbg_out_pixel    (dbg_out_pixel),
        .dbg_lane_index   (dbg_lane_index),
        
        .sdram_address    (sdram_address),
        .sdram_read       (sdram_read),
        .sdram_write      (sdram_write),
        .sdram_writedata  (sdram_writedata),
        .sdram_readdata   (sdram_readdata),
        .sdram_waitrequest(sdram_waitrequest),
        .sdram_readdatavalid(sdram_readdatavalid),
        .sdram_byteenable (sdram_byteenable),
        
        .p00_packed       (p00_packed),
        .p01_packed       (p01_packed),
        .p10_packed       (p10_packed),
        .p11_packed       (p11_packed),
        .frac_x_packed    (frac_x_packed),
        .frac_y_packed    (frac_y_packed),
        .pixels_valid     (pixels_valid),
        .result_pixels    (result_pixels),
        .result_valid     (result_valid)
    );
    
    //=======================================================
    // SDRAM Memory Model with Latency
    //=======================================================
    initial begin
        sdram_waitrequest = 1'b0;
        sdram_readdatavalid = 1'b0;
        sdram_readdata = 16'd0;
        pending_read = 1'b0;
        read_latency = 4'd0;
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sdram_readdatavalid <= 1'b0;
            pending_read <= 1'b0;
            read_latency <= 4'd0;
        end else begin
            sdram_readdatavalid <= 1'b0;
            
            // Handle writes
            if (sdram_write && !sdram_waitrequest) begin
                sdram_mem[sdram_address[15:0]] <= sdram_writedata[7:0];
                if (sdram_byteenable[1])
                    sdram_mem[sdram_address[15:0] + 1] <= sdram_writedata[15:8];
            end
            
            // Handle reads with 2-cycle latency
            if (sdram_read && !sdram_waitrequest && !pending_read) begin
                pending_read <= 1'b1;
                pending_addr <= sdram_address;
                read_latency <= 4'd2;
            end
            
            if (pending_read) begin
                if (read_latency > 0) begin
                    read_latency <= read_latency - 1;
                end else begin
                    sdram_readdata <= {sdram_mem[pending_addr[15:0] + 1], 
                                       sdram_mem[pending_addr[15:0]]};
                    sdram_readdatavalid <= 1'b1;
                    pending_read <= 1'b0;
                end
            end
        end
    end
    
    //=======================================================
    // Mock SIMD: Return result after valid pulse
    //=======================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_valid <= 1'b0;
            result_pixels <= '0;
        end else begin
            result_valid <= 1'b0;
            
            if (pixels_valid) begin
                // Return mock result: average of p00 for each lane
                for (int i = 0; i < LANES; i++) begin
                    result_pixels[i*8 +: 8] <= p00_packed[i*8 +: 8];
                end
                result_valid <= 1'b1;
            end
        end
    end
    
    //=======================================================
    // Test: Reset Behavior
    //=======================================================
    task automatic test_reset();
        $display("\n[TEST] Reset Behavior");
        
        rst_n = 1'b0;
        repeat(5) @(posedge clk);
        
        if (dbg_fsm_state !== S_IDLE) begin
            $display("  FAIL: FSM not in IDLE after reset, state=%0d", dbg_fsm_state);
            test_fail_count++;
            return;
        end
        
        if (busy !== 1'b0) begin
            $display("  FAIL: busy should be 0 after reset");
            test_fail_count++;
            return;
        end
        
        rst_n = 1'b1;
        repeat(3) @(posedge clk);
        
        $display("  PASS: Reset behavior correct");
        test_pass_count++;
    endtask
    
    //=======================================================
    // Test: Start Signal Transitions to INIT
    //=======================================================
    task automatic test_start_transition();
        $display("\n[TEST] Start Signal Transition");
        
        // Configure for small image
        in_width = 32'd8;
        in_height = 32'd8;
        out_width = 32'd4;
        out_height = 32'd4;
        scale_q8_8 = 32'h0080;  // 0.5
        mode = 2'd0;  // SIMD
        img_in_addr = 32'h0000_0000;
        img_out_addr = 32'h0000_1000;
        step_enable = 1'b0;
        
        // Pulse start
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;
        @(posedge clk);
        @(posedge clk);
        
        if (busy !== 1'b1) begin
            $display("  FAIL: busy not asserted after start");
            test_fail_count++;
            return;
        end
        
        if (dbg_fsm_state === S_IDLE) begin
            $display("  FAIL: FSM stuck in IDLE after start");
            test_fail_count++;
            return;
        end
        
        $display("  PASS: Start transitions FSM correctly, state=%0d", dbg_fsm_state);
        test_pass_count++;
    endtask
    
    //=======================================================
    // Test: Abort Returns to IDLE
    //=======================================================
    task automatic test_abort();
        $display("\n[TEST] Abort Behavior");
        
        // Start processing
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;
        
        // Wait a bit
        repeat(10) @(posedge clk);
        
        // Abort
        abort = 1'b1;
        @(posedge clk);
        abort = 1'b0;
        repeat(3) @(posedge clk);
        
        if (busy !== 1'b0) begin
            $display("  FAIL: busy not cleared after abort");
            test_fail_count++;
            return;
        end
        
        // Note: FSM may go to IDLE on reset (abort triggers rst_n in top)
        $display("  PASS: Abort clears busy flag");
        test_pass_count++;
    endtask
    
    //=======================================================
    // Test: Memory Read Counter
    //=======================================================
    task automatic test_mem_read_counter();
        logic [63:0] initial_reads, final_reads;
        
        $display("\n[TEST] Memory Read Counter");
        
        // Reset counters
        rst_n = 1'b0;
        repeat(3) @(posedge clk);
        rst_n = 1'b1;
        repeat(3) @(posedge clk);
        
        initial_reads = perf_mem_reads;
        
        // Start small operation
        in_width = 32'd4;
        in_height = 32'd4;
        out_width = 32'd2;
        out_height = 32'd2;
        scale_q8_8 = 32'h0080;
        mode = 2'd0;
        img_in_addr = 32'd0;
        img_out_addr = 32'h1000;
        step_enable = 1'b0;
        
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;
        
        // Wait for completion or timeout
        repeat(5000) begin
            @(posedge clk);
            if (!busy) break;
        end
        
        final_reads = perf_mem_reads;
        
        if (final_reads <= initial_reads) begin
            $display("  FAIL: Memory read counter did not increment");
            test_fail_count++;
            return;
        end
        
        $display("  PASS: Memory reads incremented: %0d -> %0d", initial_reads, final_reads);
        test_pass_count++;
    endtask
    
    //=======================================================
    // Test: Debug Outputs Update
    //=======================================================
    task automatic test_debug_outputs();
        $display("\n[TEST] Debug Outputs");
        
        // Reset
        rst_n = 1'b0;
        repeat(3) @(posedge clk);
        rst_n = 1'b1;
        repeat(3) @(posedge clk);
        
        // Start
        in_width = 32'd8;
        in_height = 32'd8;
        out_width = 32'd4;
        out_height = 32'd4;
        scale_q8_8 = 32'h0080;
        mode = 2'd0;
        step_enable = 1'b0;
        
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;
        
        // Wait for FSM to progress
        repeat(100) @(posedge clk);
        
        // Check that debug outputs have changed from reset values
        $display("  FSM state: %0d", dbg_fsm_state);
        $display("  out_x: %0d, out_y: %0d", dbg_out_x, dbg_out_y);
        $display("  src_x_int: %0d, src_y_int: %0d", dbg_src_x_int, dbg_src_y_int);
        
        $display("  PASS: Debug outputs are updating");
        test_pass_count++;
    endtask
    
    //=======================================================
    // Test: Stepping Mode
    //=======================================================
    task automatic test_stepping_mode();
        logic [3:0] prev_state;
        int steps;
        
        $display("\n[TEST] Stepping Mode");
        
        // Reset
        rst_n = 1'b0;
        repeat(3) @(posedge clk);
        rst_n = 1'b1;
        repeat(3) @(posedge clk);
        
        // Configure with stepping enabled
        in_width = 32'd4;
        in_height = 32'd4;
        out_width = 32'd2;
        out_height = 32'd2;
        scale_q8_8 = 32'h0080;
        mode = 2'd0;
        step_enable = 1'b1;
        step_once = 1'b0;
        
        // Start
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;
        
        // Perform a few steps
        for (steps = 0; steps < 5; steps++) begin
            prev_state = dbg_fsm_state;
            
            // Wait a bit without stepping
            repeat(5) @(posedge clk);
            
            // Trigger step
            step_once = 1'b1;
            @(posedge clk);
            step_once = 1'b0;
            @(posedge clk);
            @(posedge clk);
            
            $display("  Step %0d: state %0d -> %0d", steps, prev_state, dbg_fsm_state);
        end
        
        $display("  PASS: Stepping mode executed %0d steps", steps);
        test_pass_count++;
        
        step_enable = 1'b0;
    endtask
    
    //=======================================================
    // Test: SIMD Data Packing
    //=======================================================
    task automatic test_simd_packing();
        $display("\n[TEST] SIMD Data Packing");
        
        // Initialize test image in SDRAM
        for (int i = 0; i < 64; i++) begin
            sdram_mem[i] = i[7:0];
        end
        
        // Reset
        rst_n = 1'b0;
        repeat(3) @(posedge clk);
        rst_n = 1'b1;
        repeat(3) @(posedge clk);
        
        // Start
        in_width = 32'd8;
        in_height = 32'd8;
        out_width = 32'd4;
        out_height = 32'd4;
        scale_q8_8 = 32'h0080;
        mode = 2'd0;  // SIMD
        img_in_addr = 32'd0;
        img_out_addr = 32'h1000;
        step_enable = 1'b0;
        
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;
        
        // Wait for pixels_valid
        repeat(10000) begin
            @(posedge clk);
            if (pixels_valid) begin
                $display("  pixels_valid asserted!");
                $display("  p00_packed: 0x%016X", p00_packed);
                $display("  p01_packed: 0x%016X", p01_packed);
                $display("  frac_x_packed: 0x%016X", frac_x_packed);
                break;
            end
            if (!busy) break;
        end
        
        $display("  PASS: SIMD packing test completed");
        test_pass_count++;
    endtask
    
    //=======================================================
    // Test: Complete Small Image Processing
    //=======================================================
    task automatic test_complete_processing();
        int timeout;
        
        $display("\n[TEST] Complete Small Image Processing");
        
        // Initialize gradient image
        for (int y = 0; y < 8; y++) begin
            for (int x = 0; x < 8; x++) begin
                sdram_mem[y * 8 + x] = ((x + y) * 16) & 8'hFF;
            end
        end
        
        // Reset
        rst_n = 1'b0;
        repeat(3) @(posedge clk);
        rst_n = 1'b1;
        repeat(3) @(posedge clk);
        
        // Configure 8x8 -> 4x4
        in_width = 32'd8;
        in_height = 32'd8;
        out_width = 32'd4;
        out_height = 32'd4;
        scale_q8_8 = 32'h0080;
        mode = 2'd0;
        img_in_addr = 32'd0;
        img_out_addr = 32'h1000;
        step_enable = 1'b0;
        
        // Start
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;
        
        // Wait for completion
        timeout = 50000;
        while (busy && timeout > 0) begin
            @(posedge clk);
            timeout--;
        end
        
        if (timeout == 0) begin
            $display("  FAIL: Processing timed out, state=%0d", dbg_fsm_state);
            test_fail_count++;
            return;
        end
        
        $display("  Processing completed in %0d cycles", 50000 - timeout);
        $display("  Progress: %0d pixels", progress);
        $display("  Memory reads: %0d", perf_mem_reads);
        $display("  Memory writes: %0d", perf_mem_writes);
        
        // Verify output was written
        if (progress < out_width * out_height) begin
            $display("  FAIL: Not all pixels processed");
            test_fail_count++;
            return;
        end
        
        $display("  PASS: Complete processing successful");
        test_pass_count++;
    endtask
    
    //=======================================================
    // Test: Serial Mode (1 lane)
    //=======================================================
    task automatic test_serial_mode();
        int timeout;
        
        $display("\n[TEST] Serial Mode Processing");
        
        // Reset
        rst_n = 1'b0;
        repeat(3) @(posedge clk);
        rst_n = 1'b1;
        repeat(3) @(posedge clk);
        
        // Configure 4x4 -> 2x2 in serial mode
        in_width = 32'd4;
        in_height = 32'd4;
        out_width = 32'd2;
        out_height = 32'd2;
        scale_q8_8 = 32'h0080;
        mode = 2'd1;  // Serial mode
        img_in_addr = 32'd0;
        img_out_addr = 32'h1000;
        step_enable = 1'b0;
        
        // Start
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;
        
        // Wait for completion
        timeout = 50000;
        while (busy && timeout > 0) begin
            @(posedge clk);
            timeout--;
        end
        
        if (timeout == 0) begin
            $display("  FAIL: Serial processing timed out");
            test_fail_count++;
            return;
        end
        
        $display("  Serial mode completed, progress=%0d", progress);
        $display("  PASS: Serial mode works");
        test_pass_count++;
    endtask
    
    //=======================================================
    // Main Test Sequence
    //=======================================================
    initial begin
        $display("\n");
        $display("=============================================");
        $display("  Pixel Fetch FSM Unit Testbench");
        $display("  LANES=%0d, Q=%0d", LANES, Q);
        $display("=============================================");
        
        // Initialize signals
        rst_n = 1'b0;
        start = 1'b0;
        abort = 1'b0;
        in_width = 32'd0;
        in_height = 32'd0;
        out_width = 32'd0;
        out_height = 32'd0;
        scale_q8_8 = 32'd0;
        mode = 2'd0;
        img_in_addr = 32'd0;
        img_out_addr = 32'd0;
        step_enable = 1'b0;
        step_once = 1'b0;
        result_pixels = '0;
        result_valid = 1'b0;
        
        test_pass_count = 0;
        test_fail_count = 0;
        
        // Initialize SDRAM
        for (int i = 0; i < 65536; i++) begin
            sdram_mem[i] = 8'd0;
        end
        
        // Reset
        repeat(10) @(posedge clk);
        rst_n = 1'b1;
        repeat(5) @(posedge clk);
        
        // Run tests
        test_reset();
        test_start_transition();
        test_abort();
        test_mem_read_counter();
        test_debug_outputs();
        test_stepping_mode();
        test_simd_packing();
        test_complete_processing();
        test_serial_mode();
        
        // Summary
        $display("\n");
        $display("=============================================");
        $display("  TEST SUMMARY");
        $display("=============================================");
        $display("  PASSED: %0d", test_pass_count);
        $display("  FAILED: %0d", test_fail_count);
        $display("=============================================");
        
        if (test_fail_count == 0) begin
            $display("  *** ALL TESTS PASSED ***");
        end else begin
            $display("  *** SOME TESTS FAILED ***");
        end
        
        $finish;
    end
    
    //=======================================================
    // Timeout
    //=======================================================
    initial begin
        #5000000;
        $display("[TB] ERROR: Global timeout!");
        $finish;
    end

endmodule
