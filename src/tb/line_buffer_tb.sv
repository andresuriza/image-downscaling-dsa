//=======================================================
// Line Buffer Unit Testbench
// Verifies dual-row BRAM storage, write/read operations,
// neighbor pixel extraction, and boundary clamping
//=======================================================

`timescale 1ns/1ps

module line_buffer_tb;

    //=======================================================
    // Parameters
    //=======================================================
    parameter MAX_WIDTH = 64;
    parameter DATA_WIDTH = 8;
    parameter CLK_PERIOD = 20;
    
    //=======================================================
    // DUT Signals
    //=======================================================
    reg         clk;
    reg         rst_n;
    
    // Control
    reg         clear;
    reg  [31:0] image_width;
    
    // Write port
    reg         wr_en;
    reg         wr_row_sel;
    reg  [15:0] wr_col;
    reg  [DATA_WIDTH-1:0] wr_data;
    
    // Read port
    reg  [15:0] rd_col;
    wire [DATA_WIDTH-1:0] p00;
    wire [DATA_WIDTH-1:0] p01;
    wire [DATA_WIDTH-1:0] p10;
    wire [DATA_WIDTH-1:0] p11;
    wire        rd_valid;
    
    // Status
    wire        row0_valid;
    wire        row1_valid;
    wire [15:0] row0_y;
    wire [15:0] row1_y;
    
    //=======================================================
    // Test Control
    //=======================================================
    integer test_pass_count;
    integer test_fail_count;
    
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
    line_buffer #(
        .MAX_WIDTH(MAX_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        
        .clear      (clear),
        .image_width(image_width),
        
        .wr_en      (wr_en),
        .wr_row_sel (wr_row_sel),
        .wr_col     (wr_col),
        .wr_data    (wr_data),
        
        .rd_col     (rd_col),
        .p00        (p00),
        .p01        (p01),
        .p10        (p10),
        .p11        (p11),
        .rd_valid   (rd_valid),
        
        .row0_valid (row0_valid),
        .row1_valid (row1_valid),
        .row0_y     (row0_y),
        .row1_y     (row1_y)
    );
    
    //=======================================================
    // Test: Reset Behavior
    //=======================================================
    task test_reset;
        begin
            $display("\n[TEST] Reset Behavior");
            
            rst_n = 1'b0;
            repeat(5) @(posedge clk);
            
            if (row0_valid !== 1'b0 || row1_valid !== 1'b0) begin
                $display("  FAIL: row valid flags not cleared after reset");
                test_fail_count = test_fail_count + 1;
                disable test_reset;
            end
            
            if (rd_valid !== 1'b0) begin
                $display("  FAIL: rd_valid should be 0 after reset");
                test_fail_count = test_fail_count + 1;
                disable test_reset;
            end
            
            rst_n = 1'b1;
            repeat(3) @(posedge clk);
            
            $display("  PASS: Reset behavior correct");
            test_pass_count = test_pass_count + 1;
        end
    endtask
    
    //=======================================================
    // Test: Clear Signal
    //=======================================================
    task test_clear;
        integer i;
        begin
            $display("\n[TEST] Clear Signal");
            
            // First write some data to make rows valid
            image_width = 32'd8;
            
            // Write row0
            for (i = 0; i < 8; i = i + 1) begin
                wr_en = 1'b1;
                wr_row_sel = 1'b0;
                wr_col = i[15:0];
                wr_data = i[7:0];
                @(posedge clk);
            end
            wr_en = 1'b0;
            @(posedge clk);
            @(posedge clk);
            
            if (row0_valid !== 1'b1) begin
                $display("  FAIL: row0_valid should be 1 after writing row0");
                test_fail_count = test_fail_count + 1;
                disable test_clear;
            end
            
            // Clear
            clear = 1'b1;
            @(posedge clk);
            clear = 1'b0;
            @(posedge clk);
            
            if (row0_valid !== 1'b0) begin
                $display("  FAIL: row0_valid should be 0 after clear");
                test_fail_count = test_fail_count + 1;
                disable test_clear;
            end
            
            $display("  PASS: Clear signal works correctly");
            test_pass_count = test_pass_count + 1;
        end
    endtask
    
    //=======================================================
    // Test: Write and Read Row 0
    //=======================================================
    task test_write_read_row0;
        reg [7:0] expected, actual;
        integer errors;
        integer i;
        begin
            $display("\n[TEST] Write and Read Row 0");
            errors = 0;
            
            image_width = 32'd16;
            
            // Write pattern to row0
            for (i = 0; i < 16; i = i + 1) begin
                wr_en = 1'b1;
                wr_row_sel = 1'b0;  // Row 0
                wr_col = i[15:0];
                wr_data = (i * 10);  // Pattern: 0, 10, 20, 30, ...
                @(posedge clk);
            end
            wr_en = 1'b0;
            @(posedge clk);
            @(posedge clk);
            
            // Also write row1 to enable rd_valid
            for (i = 0; i < 16; i = i + 1) begin
                wr_en = 1'b1;
                wr_row_sel = 1'b1;  // Row 1
                wr_col = i[15:0];
                wr_data = (i * 10 + 5);
                @(posedge clk);
            end
            wr_en = 1'b0;
            @(posedge clk);
            @(posedge clk);
            
            // Read and verify
            for (i = 0; i < 15; i = i + 1) begin
                rd_col = i[15:0];
                @(posedge clk);
                
                expected = (i * 10);
                actual = p00;
                
                if (actual !== expected) begin
                    $display("  FAIL: p00[%0d] = %0d, expected %0d", i, actual, expected);
                    errors = errors + 1;
                end
                
                // Check p01 (next column)
                expected = ((i + 1) * 10);
                actual = p01;
                
                if (actual !== expected) begin
                    $display("  FAIL: p01[%0d] = %0d, expected %0d", i, actual, expected);
                    errors = errors + 1;
                end
            end
            
            if (errors == 0) begin
                $display("  PASS: Row 0 write/read correct");
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  FAIL: %0d read errors", errors);
                test_fail_count = test_fail_count + 1;
            end
        end
    endtask
    
    //=======================================================
    // Test: Write and Read Row 1
    //=======================================================
    task test_write_read_row1;
        reg [7:0] expected, actual;
        integer errors;
        integer i;
        begin
            $display("\n[TEST] Write and Read Row 1");
            errors = 0;
            
            image_width = 32'd16;
            clear = 1'b1;
            @(posedge clk);
            clear = 1'b0;
            @(posedge clk);
            
            // Write row0 first
            for (i = 0; i < 16; i = i + 1) begin
                wr_en = 1'b1;
                wr_row_sel = 1'b0;
                wr_col = i[15:0];
                wr_data = 8'hAA;
                @(posedge clk);
            end
            
            // Write pattern to row1
            for (i = 0; i < 16; i = i + 1) begin
                wr_en = 1'b1;
                wr_row_sel = 1'b1;  // Row 1
                wr_col = i[15:0];
                wr_data = (i * 5);  // Pattern: 0, 5, 10, 15, ...
                @(posedge clk);
            end
            wr_en = 1'b0;
            @(posedge clk);
            @(posedge clk);
            
            // Read and verify
            for (i = 0; i < 15; i = i + 1) begin
                rd_col = i[15:0];
                @(posedge clk);
                
                expected = (i * 5);
                actual = p10;  // Row 1, column i
                
                if (actual !== expected) begin
                    $display("  FAIL: p10[%0d] = %0d, expected %0d", i, actual, expected);
                    errors = errors + 1;
                end
                
                expected = ((i + 1) * 5);
                actual = p11;  // Row 1, column i+1
                
                if (actual !== expected) begin
                    $display("  FAIL: p11[%0d] = %0d, expected %0d", i, actual, expected);
                    errors = errors + 1;
                end
            end
            
            if (errors == 0) begin
                $display("  PASS: Row 1 write/read correct");
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  FAIL: %0d read errors", errors);
                test_fail_count = test_fail_count + 1;
            end
        end
    endtask
    
    //=======================================================
    // Test: Four Neighbor Pixels
    //=======================================================
    task test_four_neighbors;
        integer i;
        begin
            $display("\n[TEST] Four Neighbor Pixels");
            
            image_width = 32'd8;
            clear = 1'b1;
            @(posedge clk);
            clear = 1'b0;
            @(posedge clk);
            
            // Write known pattern:
            // Row 0: 10, 20, 30, 40, 50, 60, 70, 80
            // Row 1: 15, 25, 35, 45, 55, 65, 75, 85
            for (i = 0; i < 8; i = i + 1) begin
                wr_en = 1'b1;
                wr_row_sel = 1'b0;
                wr_col = i[15:0];
                wr_data = ((i + 1) * 10);
                @(posedge clk);
            end
            
            for (i = 0; i < 8; i = i + 1) begin
                wr_en = 1'b1;
                wr_row_sel = 1'b1;
                wr_col = i[15:0];
                wr_data = ((i + 1) * 10 + 5);
                @(posedge clk);
            end
            wr_en = 1'b0;
            @(posedge clk);
            @(posedge clk);
            
            // Read at column 2 -> should get pixels at (2,0), (3,0), (2,1), (3,1)
            rd_col = 16'd2;
            @(posedge clk);
            @(posedge clk);
            
            // p00 = row0[2] = 30, p01 = row0[3] = 40
            // p10 = row1[2] = 35, p11 = row1[3] = 45
            if (p00 !== 8'd30) begin
                $display("  FAIL: p00 = %0d, expected 30", p00);
                test_fail_count = test_fail_count + 1;
                disable test_four_neighbors;
            end
            if (p01 !== 8'd40) begin
                $display("  FAIL: p01 = %0d, expected 40", p01);
                test_fail_count = test_fail_count + 1;
                disable test_four_neighbors;
            end
            if (p10 !== 8'd35) begin
                $display("  FAIL: p10 = %0d, expected 35", p10);
                test_fail_count = test_fail_count + 1;
                disable test_four_neighbors;
            end
            if (p11 !== 8'd45) begin
                $display("  FAIL: p11 = %0d, expected 45", p11);
                test_fail_count = test_fail_count + 1;
                disable test_four_neighbors;
            end
            
            $display("  PASS: Four neighbors read correctly");
            test_pass_count = test_pass_count + 1;
        end
    endtask
    
    //=======================================================
    // Test: Boundary Clamping
    //=======================================================
    task test_boundary_clamping;
        integer i;
        begin
            $display("\n[TEST] Boundary Clamping");
            
            image_width = 32'd8;
            clear = 1'b1;
            @(posedge clk);
            clear = 1'b0;
            @(posedge clk);
            
            // Write data
            for (i = 0; i < 8; i = i + 1) begin
                wr_en = 1'b1;
                wr_row_sel = 1'b0;
                wr_col = i[15:0];
                wr_data = (i * 10);
                @(posedge clk);
            end
            for (i = 0; i < 8; i = i + 1) begin
                wr_en = 1'b1;
                wr_row_sel = 1'b1;
                wr_col = i[15:0];
                wr_data = (i * 10 + 100);
                @(posedge clk);
            end
            wr_en = 1'b0;
            @(posedge clk);
            @(posedge clk);
            
            // Read at last column (7) - p01 and p11 should clamp to column 7
            rd_col = 16'd7;
            @(posedge clk);
            @(posedge clk);
            
            // p00 = row0[7] = 70, p01 = row0[7] = 70 (clamped)
            if (p00 !== 8'd70) begin
                $display("  FAIL: p00 = %0d, expected 70", p00);
                test_fail_count = test_fail_count + 1;
                disable test_boundary_clamping;
            end
            if (p01 !== 8'd70) begin
                $display("  FAIL: p01 = %0d, expected 70 (clamped)", p01);
                test_fail_count = test_fail_count + 1;
                disable test_boundary_clamping;
            end
            
            // Read beyond width
            rd_col = 16'd10;  // Beyond width 8
            @(posedge clk);
            @(posedge clk);
            
            // Should clamp to last column
            if (p00 !== 8'd70) begin
                $display("  FAIL: p00 = %0d, expected 70 (clamped from column 10)", p00);
                test_fail_count = test_fail_count + 1;
                disable test_boundary_clamping;
            end
            
            $display("  PASS: Boundary clamping works correctly");
            test_pass_count = test_pass_count + 1;
        end
    endtask
    
    //=======================================================
    // Test: rd_valid Flag
    //=======================================================
    task test_rd_valid_flag;
        integer i;
        begin
            $display("\n[TEST] rd_valid Flag");
            
            image_width = 32'd8;
            clear = 1'b1;
            @(posedge clk);
            clear = 1'b0;
            @(posedge clk);
            @(posedge clk);
            
            // Initially both rows invalid
            if (rd_valid !== 1'b0) begin
                $display("  FAIL: rd_valid should be 0 before loading rows");
                test_fail_count = test_fail_count + 1;
                disable test_rd_valid_flag;
            end
            
            // Load only row 0
            for (i = 0; i < 8; i = i + 1) begin
                wr_en = 1'b1;
                wr_row_sel = 1'b0;
                wr_col = i[15:0];
                wr_data = 8'd0;
                @(posedge clk);
            end
            wr_en = 1'b0;
            @(posedge clk);
            @(posedge clk);
            
            if (row0_valid !== 1'b1) begin
                $display("  FAIL: row0_valid should be 1");
                test_fail_count = test_fail_count + 1;
                disable test_rd_valid_flag;
            end
            
            if (rd_valid !== 1'b0) begin
                $display("  FAIL: rd_valid should still be 0 (only row0 loaded)");
                test_fail_count = test_fail_count + 1;
                disable test_rd_valid_flag;
            end
            
            // Load row 1
            for (i = 0; i < 8; i = i + 1) begin
                wr_en = 1'b1;
                wr_row_sel = 1'b1;
                wr_col = i[15:0];
                wr_data = 8'd0;
                @(posedge clk);
            end
            wr_en = 1'b0;
            @(posedge clk);
            @(posedge clk);
            
            if (row1_valid !== 1'b1) begin
                $display("  FAIL: row1_valid should be 1");
                test_fail_count = test_fail_count + 1;
                disable test_rd_valid_flag;
            end
            
            if (rd_valid !== 1'b1) begin
                $display("  FAIL: rd_valid should be 1 (both rows loaded)");
                test_fail_count = test_fail_count + 1;
                disable test_rd_valid_flag;
            end
            
            $display("  PASS: rd_valid flag behavior correct");
            test_pass_count = test_pass_count + 1;
        end
    endtask
    
    //=======================================================
    // Test: Overwrite Row
    //=======================================================
    task test_row_overwrite;
        integer i;
        begin
            $display("\n[TEST] Row Overwrite");
            
            image_width = 32'd4;
            clear = 1'b1;
            @(posedge clk);
            clear = 1'b0;
            @(posedge clk);
            
            // Write initial data to row 0
            for (i = 0; i < 4; i = i + 1) begin
                wr_en = 1'b1;
                wr_row_sel = 1'b0;
                wr_col = i[15:0];
                wr_data = 8'hAA;
                @(posedge clk);
            end
            
            // Write row 1 to enable valid
            for (i = 0; i < 4; i = i + 1) begin
                wr_en = 1'b1;
                wr_row_sel = 1'b1;
                wr_col = i[15:0];
                wr_data = 8'hBB;
                @(posedge clk);
            end
            wr_en = 1'b0;
            @(posedge clk);
            @(posedge clk);
            
            // Verify initial data
            rd_col = 16'd0;
            @(posedge clk);
            if (p00 !== 8'hAA) begin
                $display("  FAIL: Initial p00 = 0x%02X, expected 0xAA", p00);
                test_fail_count = test_fail_count + 1;
                disable test_row_overwrite;
            end
            
            // Overwrite row 0 with new data
            for (i = 0; i < 4; i = i + 1) begin
                wr_en = 1'b1;
                wr_row_sel = 1'b0;
                wr_col = i[15:0];
                wr_data = 8'hCC;
                @(posedge clk);
            end
            wr_en = 1'b0;
            @(posedge clk);
            @(posedge clk);
            
            // Verify overwritten data
            rd_col = 16'd0;
            @(posedge clk);
            if (p00 !== 8'hCC) begin
                $display("  FAIL: Overwritten p00 = 0x%02X, expected 0xCC", p00);
                test_fail_count = test_fail_count + 1;
                disable test_row_overwrite;
            end
            
            $display("  PASS: Row overwrite works correctly");
            test_pass_count = test_pass_count + 1;
        end
    endtask
    
    //=======================================================
    // Main Test Sequence
    //=======================================================
    initial begin
        $display("\n");
        $display("=============================================");
        $display("  Line Buffer Unit Testbench");
        $display("  MAX_WIDTH=%0d, DATA_WIDTH=%0d", MAX_WIDTH, DATA_WIDTH);
        $display("=============================================");
        
        // Initialize signals
        rst_n = 1'b0;
        clear = 1'b0;
        image_width = 32'd8;
        wr_en = 1'b0;
        wr_row_sel = 1'b0;
        wr_col = 16'd0;
        wr_data = 8'd0;
        rd_col = 16'd0;
        
        test_pass_count = 0;
        test_fail_count = 0;
        
        // Reset
        repeat(10) @(posedge clk);
        rst_n = 1'b1;
        repeat(5) @(posedge clk);
        
        // Run tests
        test_reset;
        test_clear;
        test_write_read_row0;
        test_write_read_row1;
        test_four_neighbors;
        test_boundary_clamping;
        test_rd_valid_flag;
        test_row_overwrite;
        
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
        $display("[TB] ERROR: Global timeout!");
        $finish;
    end

endmodule
