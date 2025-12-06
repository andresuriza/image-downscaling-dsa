//=======================================================
// Accelerator CSR Bridge Unit Testbench
// Verifies register read/write, auto-clear bits, status
//=======================================================

`timescale 1ns/1ps

module accelerator_csr_bridge_tb;

    //=======================================================
    // Parameters
    //=======================================================
    parameter int LANES = 8;
    parameter int Q = 8;
    parameter int CLK_PERIOD = 20;
    
    //=======================================================
    // CSR Offsets (must match accelerator_csr_bridge.sv)
    //=======================================================
    localparam logic [11:0] CSR_CTRL         = 12'h000;
    localparam logic [11:0] CSR_STATUS       = 12'h004;
    localparam logic [11:0] CSR_IN_WIDTH     = 12'h008;
    localparam logic [11:0] CSR_IN_HEIGHT    = 12'h00C;
    localparam logic [11:0] CSR_OUT_WIDTH    = 12'h010;
    localparam logic [11:0] CSR_OUT_HEIGHT   = 12'h014;
    localparam logic [11:0] CSR_SCALE_Q8_8   = 12'h018;
    localparam logic [11:0] CSR_MODE         = 12'h01C;
    localparam logic [11:0] CSR_PROGRESS     = 12'h020;
    localparam logic [11:0] CSR_ERRORS       = 12'h024;
    localparam logic [11:0] CSR_PERF_FLOPS_LO  = 12'h040;
    localparam logic [11:0] CSR_PERF_FLOPS_HI  = 12'h044;
    localparam logic [11:0] CSR_PERF_READS_LO  = 12'h048;
    localparam logic [11:0] CSR_PERF_READS_HI  = 12'h04C;
    localparam logic [11:0] CSR_PERF_WRITES_LO = 12'h050;
    localparam logic [11:0] CSR_PERF_WRITES_HI = 12'h054;
    localparam logic [11:0] CSR_PERF_CYCLES_LO = 12'h058;
    localparam logic [11:0] CSR_PERF_CYCLES_HI = 12'h05C;
    localparam logic [11:0] CSR_IMG_IN_ADDR  = 12'h080;
    localparam logic [11:0] CSR_IMG_OUT_ADDR = 12'h084;
    localparam logic [11:0] CSR_DBG_STATE_X  = 12'h0A0;
    localparam logic [11:0] CSR_DBG_Y_SRCX   = 12'h0A4;
    localparam logic [11:0] CSR_DBG_SRCY_FRAC = 12'h0A8;
    localparam logic [11:0] CSR_DBG_NEIGHBORS = 12'h0AC;
    localparam logic [11:0] CSR_DBG_OUTPUT   = 12'h0B0;
    localparam logic [11:0] CSR_VERSION      = 12'h0FC;
    
    //=======================================================
    // DUT Signals
    //=======================================================
    logic        clk;
    logic        rst_n;
    
    // Avalon-MM Slave
    logic [11:0] avs_address;
    logic        avs_read;
    logic        avs_write;
    logic [31:0] avs_writedata;
    logic [3:0]  avs_byteenable;
    logic [31:0] avs_readdata;
    logic        avs_waitrequest;
    
    // Control outputs
    logic        acc_start;
    logic        acc_reset;
    logic [31:0] acc_in_width;
    logic [31:0] acc_in_height;
    logic [31:0] acc_out_width;
    logic [31:0] acc_out_height;
    logic [31:0] acc_scale_q8_8;
    logic [1:0]  acc_mode;
    
    // Status inputs
    logic        acc_busy;
    logic [31:0] acc_progress;
    logic [31:0] acc_errors;
    
    // Performance counters
    logic [63:0] acc_perf_flops;
    logic [63:0] acc_perf_mem_reads;
    logic [63:0] acc_perf_mem_writes;
    
    // Stepping
    logic        step_enable;
    logic        step_once;
    
    // DMA addresses
    logic [31:0] img_in_addr;
    logic [31:0] img_out_addr;
    
    // Debug inputs
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
    accelerator_csr_bridge #(
        .LANES(LANES),
        .Q(Q)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        
        .avs_address      (avs_address),
        .avs_read         (avs_read),
        .avs_write        (avs_write),
        .avs_writedata    (avs_writedata),
        .avs_byteenable   (avs_byteenable),
        .avs_readdata     (avs_readdata),
        .avs_waitrequest  (avs_waitrequest),
        
        .acc_start        (acc_start),
        .acc_reset        (acc_reset),
        .acc_in_width     (acc_in_width),
        .acc_in_height    (acc_in_height),
        .acc_out_width    (acc_out_width),
        .acc_out_height   (acc_out_height),
        .acc_scale_q8_8   (acc_scale_q8_8),
        .acc_mode         (acc_mode),
        
        .acc_busy         (acc_busy),
        .acc_progress     (acc_progress),
        .acc_errors       (acc_errors),
        
        .acc_perf_flops      (acc_perf_flops),
        .acc_perf_mem_reads  (acc_perf_mem_reads),
        .acc_perf_mem_writes (acc_perf_mem_writes),
        
        .step_enable      (step_enable),
        .step_once        (step_once),
        
        .img_in_addr      (img_in_addr),
        .img_out_addr     (img_out_addr),
        
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
        .dbg_lane_index   (dbg_lane_index)
    );
    
    //=======================================================
    // Tasks for Register Access
    //=======================================================
    task automatic write_reg(input logic [11:0] addr, input logic [31:0] data);
        @(posedge clk);
        avs_address <= addr;
        avs_write <= 1'b1;
        avs_writedata <= data;
        avs_byteenable <= 4'hF;
        @(posedge clk);
        while (avs_waitrequest) @(posedge clk);
        avs_write <= 1'b0;
        @(posedge clk);
    endtask
    
    task automatic read_reg(input logic [11:0] addr, output logic [31:0] data);
        @(posedge clk);
        avs_address <= addr;
        avs_read <= 1'b1;
        avs_byteenable <= 4'hF;
        @(posedge clk);
        while (avs_waitrequest) @(posedge clk);
        data = avs_readdata;
        avs_read <= 1'b0;
        @(posedge clk);
    endtask
    
    //=======================================================
    // Test: Default Values After Reset
    //=======================================================
    task automatic test_default_values();
        logic [31:0] rd_data;
        int errors;
        
        $display("\n[TEST] Default Values After Reset");
        errors = 0;
        
        read_reg(CSR_IN_WIDTH, rd_data);
        if (rd_data !== 32'd512) begin errors++; $display("  FAIL: IN_WIDTH default=%0d, expected=512", rd_data); end
        
        read_reg(CSR_IN_HEIGHT, rd_data);
        if (rd_data !== 32'd512) begin errors++; $display("  FAIL: IN_HEIGHT default=%0d, expected=512", rd_data); end
        
        read_reg(CSR_OUT_WIDTH, rd_data);
        if (rd_data !== 32'd256) begin errors++; $display("  FAIL: OUT_WIDTH default=%0d, expected=256", rd_data); end
        
        read_reg(CSR_OUT_HEIGHT, rd_data);
        if (rd_data !== 32'd256) begin errors++; $display("  FAIL: OUT_HEIGHT default=%0d, expected=256", rd_data); end
        
        read_reg(CSR_SCALE_Q8_8, rd_data);
        if (rd_data !== 32'h0080) begin errors++; $display("  FAIL: SCALE default=0x%08X, expected=0x0080", rd_data); end
        
        read_reg(CSR_MODE, rd_data);
        if (rd_data !== 32'd0) begin errors++; $display("  FAIL: MODE default=%0d, expected=0", rd_data); end
        
        read_reg(CSR_VERSION, rd_data);
        if (rd_data !== 32'h0001_0000) begin errors++; $display("  FAIL: VERSION=0x%08X, expected=0x00010000", rd_data); end
        
        if (errors == 0) begin
            $display("  PASS: All default values correct");
            test_pass_count++;
        end else begin
            $display("  FAIL: %0d default value errors", errors);
            test_fail_count++;
        end
    endtask
    
    //=======================================================
    // Test: Register Write/Read
    //=======================================================
    task automatic test_register_rw();
        logic [31:0] wr_data, rd_data;
        int errors;
        
        $display("\n[TEST] Register Write/Read");
        errors = 0;
        
        // Test each writable register
        wr_data = 32'd1024;
        write_reg(CSR_IN_WIDTH, wr_data);
        read_reg(CSR_IN_WIDTH, rd_data);
        if (rd_data !== wr_data) begin errors++; $display("  FAIL: IN_WIDTH"); end
        
        wr_data = 32'd768;
        write_reg(CSR_IN_HEIGHT, wr_data);
        read_reg(CSR_IN_HEIGHT, rd_data);
        if (rd_data !== wr_data) begin errors++; $display("  FAIL: IN_HEIGHT"); end
        
        wr_data = 32'd512;
        write_reg(CSR_OUT_WIDTH, wr_data);
        read_reg(CSR_OUT_WIDTH, rd_data);
        if (rd_data !== wr_data) begin errors++; $display("  FAIL: OUT_WIDTH"); end
        
        wr_data = 32'd384;
        write_reg(CSR_OUT_HEIGHT, wr_data);
        read_reg(CSR_OUT_HEIGHT, rd_data);
        if (rd_data !== wr_data) begin errors++; $display("  FAIL: OUT_HEIGHT"); end
        
        wr_data = 32'h00C0;  // 0.75 in Q8.8
        write_reg(CSR_SCALE_Q8_8, wr_data);
        read_reg(CSR_SCALE_Q8_8, rd_data);
        if (rd_data !== wr_data) begin errors++; $display("  FAIL: SCALE_Q8_8"); end
        
        wr_data = 32'h0001;  // Serial mode
        write_reg(CSR_MODE, wr_data);
        read_reg(CSR_MODE, rd_data);
        if (rd_data !== wr_data) begin errors++; $display("  FAIL: MODE"); end
        
        wr_data = 32'h0020_0000;
        write_reg(CSR_IMG_IN_ADDR, wr_data);
        read_reg(CSR_IMG_IN_ADDR, rd_data);
        if (rd_data !== wr_data) begin errors++; $display("  FAIL: IMG_IN_ADDR"); end
        
        wr_data = 32'h0030_0000;
        write_reg(CSR_IMG_OUT_ADDR, wr_data);
        read_reg(CSR_IMG_OUT_ADDR, rd_data);
        if (rd_data !== wr_data) begin errors++; $display("  FAIL: IMG_OUT_ADDR"); end
        
        if (errors == 0) begin
            $display("  PASS: All register R/W tests passed");
            test_pass_count++;
        end else begin
            $display("  FAIL: %0d register R/W errors", errors);
            test_fail_count++;
        end
    endtask
    
    //=======================================================
    // Test: Start Bit Auto-Clear
    //=======================================================
    task automatic test_start_autoclear();
        logic [31:0] rd_data;
        
        $display("\n[TEST] Start Bit Auto-Clear");
        
        // Write start bit
        write_reg(CSR_CTRL, 32'h0000_0001);
        
        // Check that acc_start pulsed
        if (acc_start !== 1'b1) begin
            $display("  FAIL: acc_start not asserted immediately");
            test_fail_count++;
            return;
        end
        
        // Wait one cycle
        @(posedge clk);
        @(posedge clk);
        
        // Check start bit cleared
        read_reg(CSR_CTRL, rd_data);
        if (rd_data[0] !== 1'b0) begin
            $display("  FAIL: Start bit not auto-cleared, CTRL=0x%08X", rd_data);
            test_fail_count++;
        end else begin
            $display("  PASS: Start bit auto-cleared correctly");
            test_pass_count++;
        end
    endtask
    
    //=======================================================
    // Test: Step Once Auto-Clear
    //=======================================================
    task automatic test_step_autoclear();
        logic [31:0] rd_data;
        
        $display("\n[TEST] Step Once Auto-Clear");
        
        // Enable stepping and trigger step
        write_reg(CSR_CTRL, 32'h0000_000C);  // step_enable + step_once
        
        // Check step_once asserted
        if (step_once !== 1'b1) begin
            $display("  FAIL: step_once not asserted immediately");
            test_fail_count++;
            return;
        end
        
        // Wait for auto-clear
        @(posedge clk);
        @(posedge clk);
        
        // Check step_once cleared but step_enable remains
        read_reg(CSR_CTRL, rd_data);
        if (rd_data[3] !== 1'b0) begin
            $display("  FAIL: step_once not auto-cleared");
            test_fail_count++;
        end else if (rd_data[2] !== 1'b1) begin
            $display("  FAIL: step_enable was incorrectly cleared");
            test_fail_count++;
        end else begin
            $display("  PASS: step_once auto-cleared, step_enable retained");
            test_pass_count++;
        end
    endtask
    
    //=======================================================
    // Test: Status Register (Read-Only)
    //=======================================================
    task automatic test_status_register();
        logic [31:0] rd_data;
        
        $display("\n[TEST] Status Register");
        
        // Set busy=1
        acc_busy = 1'b1;
        @(posedge clk);
        @(posedge clk);
        
        read_reg(CSR_STATUS, rd_data);
        if (rd_data[0] !== 1'b1) begin
            $display("  FAIL: busy bit not reflected, STATUS=0x%08X", rd_data);
            test_fail_count++;
            return;
        end
        
        // Clear busy
        acc_busy = 1'b0;
        @(posedge clk);
        @(posedge clk);
        @(posedge clk);
        
        read_reg(CSR_STATUS, rd_data);
        if (rd_data[0] !== 1'b0) begin
            $display("  FAIL: busy bit should be 0, STATUS=0x%08X", rd_data);
            test_fail_count++;
            return;
        end
        
        // Done flag should be set after busy falls
        if (rd_data[1] !== 1'b1) begin
            $display("  FAIL: done bit should be 1 after busy falls, STATUS=0x%08X", rd_data);
            test_fail_count++;
            return;
        end
        
        $display("  PASS: Status register reflects busy/done correctly");
        test_pass_count++;
    endtask
    
    //=======================================================
    // Test: Performance Counters (Read-Only)
    //=======================================================
    task automatic test_performance_counters();
        logic [31:0] rd_lo, rd_hi;
        
        $display("\n[TEST] Performance Counters");
        
        // Set test values
        acc_perf_flops = 64'h0000_0001_2345_6789;
        acc_perf_mem_reads = 64'hAAAA_BBBB_CCCC_DDDD;
        acc_perf_mem_writes = 64'h1111_2222_3333_4444;
        @(posedge clk);
        @(posedge clk);
        
        // Read FLOPS
        read_reg(CSR_PERF_FLOPS_LO, rd_lo);
        read_reg(CSR_PERF_FLOPS_HI, rd_hi);
        if (rd_lo !== 32'h2345_6789 || rd_hi !== 32'h0000_0001) begin
            $display("  FAIL: FLOPS counter mismatch");
            test_fail_count++;
            return;
        end
        
        // Read MEM_READS
        read_reg(CSR_PERF_READS_LO, rd_lo);
        read_reg(CSR_PERF_READS_HI, rd_hi);
        if (rd_lo !== 32'hCCCC_DDDD || rd_hi !== 32'hAAAA_BBBB) begin
            $display("  FAIL: MEM_READS counter mismatch");
            test_fail_count++;
            return;
        end
        
        // Read MEM_WRITES
        read_reg(CSR_PERF_WRITES_LO, rd_lo);
        read_reg(CSR_PERF_WRITES_HI, rd_hi);
        if (rd_lo !== 32'h3333_4444 || rd_hi !== 32'h1111_2222) begin
            $display("  FAIL: MEM_WRITES counter mismatch");
            test_fail_count++;
            return;
        end
        
        $display("  PASS: All performance counters read correctly");
        test_pass_count++;
    endtask
    
    //=======================================================
    // Test: Debug Registers (Read-Only)
    //=======================================================
    task automatic test_debug_registers();
        logic [31:0] rd_data;
        
        $display("\n[TEST] Debug Registers");
        
        // Set debug inputs
        dbg_fsm_state = 4'hA;
        dbg_out_x = 16'h1234;
        dbg_out_y = 16'h5678;
        dbg_src_x_int = 16'h9ABC;
        dbg_src_y_int = 16'hDEF0;
        dbg_frac_x = 8'h11;
        dbg_frac_y = 8'h22;
        dbg_p00 = 8'hAA;
        dbg_p01 = 8'hBB;
        dbg_p10 = 8'hCC;
        dbg_p11 = 8'hDD;
        dbg_out_pixel = 8'hEE;
        dbg_lane_index = 4'h3;
        @(posedge clk);
        @(posedge clk);
        
        // DBG_STATE_X: [31:28]=fsm_state, [15:0]=out_x
        read_reg(CSR_DBG_STATE_X, rd_data);
        if (rd_data[31:28] !== 4'hA || rd_data[15:0] !== 16'h1234) begin
            $display("  FAIL: DBG_STATE_X=0x%08X", rd_data);
            test_fail_count++;
            return;
        end
        
        // DBG_Y_SRCX: [31:16]=out_y, [15:0]=src_x_int
        read_reg(CSR_DBG_Y_SRCX, rd_data);
        if (rd_data[31:16] !== 16'h5678 || rd_data[15:0] !== 16'h9ABC) begin
            $display("  FAIL: DBG_Y_SRCX=0x%08X", rd_data);
            test_fail_count++;
            return;
        end
        
        // DBG_NEIGHBORS: [31:24]=p00, [23:16]=p01, [15:8]=p10, [7:0]=p11
        read_reg(CSR_DBG_NEIGHBORS, rd_data);
        if (rd_data !== 32'hAABBCCDD) begin
            $display("  FAIL: DBG_NEIGHBORS=0x%08X, expected=0xAABBCCDD", rd_data);
            test_fail_count++;
            return;
        end
        
        $display("  PASS: All debug registers read correctly");
        test_pass_count++;
    endtask
    
    //=======================================================
    // Test: Cycle Counter
    //=======================================================
    task automatic test_cycle_counter();
        logic [31:0] cycles1, cycles2;
        
        $display("\n[TEST] Cycle Counter");
        
        // Start busy to reset counter
        acc_busy = 1'b1;
        @(posedge clk);
        @(posedge clk);
        
        // Read initial
        read_reg(CSR_PERF_CYCLES_LO, cycles1);
        
        // Wait some cycles
        repeat(100) @(posedge clk);
        
        // Read again
        read_reg(CSR_PERF_CYCLES_LO, cycles2);
        
        if (cycles2 <= cycles1) begin
            $display("  FAIL: Cycle counter not incrementing");
            test_fail_count++;
            return;
        end
        
        $display("  PASS: Cycle counter increments while busy (%0d -> %0d)", cycles1, cycles2);
        test_pass_count++;
        
        // Stop busy
        acc_busy = 1'b0;
    endtask
    
    //=======================================================
    // Test: Control Output Signals
    //=======================================================
    task automatic test_control_outputs();
        int errors;
        
        $display("\n[TEST] Control Output Signals");
        errors = 0;
        
        // Write configuration
        write_reg(CSR_IN_WIDTH, 32'd128);
        write_reg(CSR_IN_HEIGHT, 32'd64);
        write_reg(CSR_SCALE_Q8_8, 32'h00A0);  // 0.625
        write_reg(CSR_MODE, 32'd1);  // Serial
        write_reg(CSR_IMG_IN_ADDR, 32'h0040_0000);
        write_reg(CSR_IMG_OUT_ADDR, 32'h0080_0000);
        @(posedge clk);
        @(posedge clk);
        
        // Check outputs
        if (acc_in_width !== 32'd128) begin errors++; $display("  FAIL: acc_in_width"); end
        if (acc_in_height !== 32'd64) begin errors++; $display("  FAIL: acc_in_height"); end
        if (acc_scale_q8_8 !== 32'h00A0) begin errors++; $display("  FAIL: acc_scale_q8_8"); end
        if (acc_mode !== 2'd1) begin errors++; $display("  FAIL: acc_mode"); end
        if (img_in_addr !== 32'h0040_0000) begin errors++; $display("  FAIL: img_in_addr"); end
        if (img_out_addr !== 32'h0080_0000) begin errors++; $display("  FAIL: img_out_addr"); end
        
        // Test reset output
        write_reg(CSR_CTRL, 32'h0000_0002);  // Set reset bit
        @(posedge clk);
        if (acc_reset !== 1'b1) begin errors++; $display("  FAIL: acc_reset not asserted"); end
        
        if (errors == 0) begin
            $display("  PASS: All control outputs correct");
            test_pass_count++;
        end else begin
            $display("  FAIL: %0d control output errors", errors);
            test_fail_count++;
        end
    endtask
    
    //=======================================================
    // Test: Invalid Address Read
    //=======================================================
    task automatic test_invalid_address();
        logic [31:0] rd_data;
        
        $display("\n[TEST] Invalid Address Read");
        
        read_reg(12'hFFF, rd_data);
        if (rd_data !== 32'hDEAD_BEEF) begin
            $display("  FAIL: Invalid address returned 0x%08X, expected 0xDEADBEEF", rd_data);
            test_fail_count++;
        end else begin
            $display("  PASS: Invalid address returns 0xDEADBEEF");
            test_pass_count++;
        end
    endtask
    
    //=======================================================
    // Main Test Sequence
    //=======================================================
    initial begin
        $display("\n");
        $display("=============================================");
        $display("  Accelerator CSR Bridge Unit Testbench");
        $display("=============================================");
        
        // Initialize
        rst_n = 1'b0;
        avs_address = 12'd0;
        avs_read = 1'b0;
        avs_write = 1'b0;
        avs_writedata = 32'd0;
        avs_byteenable = 4'hF;
        
        acc_busy = 1'b0;
        acc_progress = 32'd0;
        acc_errors = 32'd0;
        acc_perf_flops = 64'd0;
        acc_perf_mem_reads = 64'd0;
        acc_perf_mem_writes = 64'd0;
        
        dbg_fsm_state = 4'd0;
        dbg_out_x = 16'd0;
        dbg_out_y = 16'd0;
        dbg_src_x_int = 16'd0;
        dbg_src_y_int = 16'd0;
        dbg_frac_x = 8'd0;
        dbg_frac_y = 8'd0;
        dbg_p00 = 8'd0;
        dbg_p01 = 8'd0;
        dbg_p10 = 8'd0;
        dbg_p11 = 8'd0;
        dbg_out_pixel = 8'd0;
        dbg_lane_index = 4'd0;
        
        test_pass_count = 0;
        test_fail_count = 0;
        
        // Reset
        repeat(10) @(posedge clk);
        rst_n = 1'b1;
        repeat(5) @(posedge clk);
        
        // Run tests
        test_default_values();
        test_register_rw();
        test_start_autoclear();
        test_step_autoclear();
        test_status_register();
        test_performance_counters();
        test_debug_registers();
        test_cycle_counter();
        test_control_outputs();
        test_invalid_address();
        
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
        #1000000;
        $display("[TB] ERROR: Timeout!");
        $finish;
    end

endmodule
