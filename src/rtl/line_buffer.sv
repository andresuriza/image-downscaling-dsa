//=======================================================
// Line Buffer - Dual-port BRAM for caching image scanlines
// Stores 2 consecutive rows for bilinear interpolation
//
// Parameters inherited from downscaler_top
//=======================================================

module line_buffer #(
    parameter int MAX_WIDTH  = 2048,    // Maximum image width (from top)
    parameter int DATA_WIDTH = 8        // Bits per pixel (from top)
) (
    input  logic        clk,
    input  logic        rst_n,
    
    //=======================================================
    // Control Interface
    //=======================================================
    input  logic        clear,              // Clear buffer state
    input  logic [31:0] image_width,        // Actual image width
    
    //=======================================================
    // Write Port (from SDRAM fetch)
    //=======================================================
    input  logic        wr_en,
    input  logic        wr_row_sel,         // 0 = row0, 1 = row1
    input  logic [15:0] wr_col,             // Column address
    input  logic [DATA_WIDTH-1:0] wr_data,
    
    //=======================================================
    // Read Port (to pixel packer)
    // Provides 4 neighbor pixels for bilinear interpolation
    //=======================================================
    input  logic [15:0] rd_col,             // Base column (x0)
    output logic [DATA_WIDTH-1:0] p00,      // row0[x0]
    output logic [DATA_WIDTH-1:0] p01,      // row0[x1]
    output logic [DATA_WIDTH-1:0] p10,      // row1[x0]
    output logic [DATA_WIDTH-1:0] p11,      // row1[x1]
    output logic        rd_valid,           // Read data valid
    
    //=======================================================
    // Status
    //=======================================================
    output logic        row0_valid,         // Row 0 fully loaded
    output logic        row1_valid,         // Row 1 fully loaded
    output logic [15:0] row0_y,             // Y coordinate of row0
    output logic [15:0] row1_y              // Y coordinate of row1
);

    //=======================================================
    // BRAM Storage - 2 rows x MAX_WIDTH
    //=======================================================
    (* ramstyle = "M10K" *) logic [DATA_WIDTH-1:0] row0_mem [0:MAX_WIDTH-1];
    (* ramstyle = "M10K" *) logic [DATA_WIDTH-1:0] row1_mem [0:MAX_WIDTH-1];
    
    //=======================================================
    // Row tracking
    //=======================================================
    logic [15:0] row0_count;    // Pixels written to row0
    logic [15:0] row1_count;    // Pixels written to row1
    logic [15:0] reg_row0_y;
    logic [15:0] reg_row1_y;
    logic        reg_row0_valid;
    logic        reg_row1_valid;
    
    // Clamp image width to MAX_WIDTH
    logic [15:0] effective_width;
    assign effective_width = (image_width > MAX_WIDTH) ? MAX_WIDTH[15:0] : image_width[15:0];
    
    //=======================================================
    // Write Logic
    //=======================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row0_count <= 16'd0;
            row1_count <= 16'd0;
            reg_row0_valid <= 1'b0;
            reg_row1_valid <= 1'b0;
            reg_row0_y <= 16'd0;
            reg_row1_y <= 16'd0;
        end else if (clear) begin
            row0_count <= 16'd0;
            row1_count <= 16'd0;
            reg_row0_valid <= 1'b0;
            reg_row1_valid <= 1'b0;
            reg_row0_y <= 16'd0;
            reg_row1_y <= 16'd0;
        end else if (wr_en) begin
            if (!wr_row_sel) begin
                // Writing to row0
                row0_mem[wr_col] <= wr_data;
                if (wr_col == effective_width - 1) begin
                    reg_row0_valid <= 1'b1;
                    row0_count <= 16'd0;
                end else begin
                    row0_count <= row0_count + 1;
                end
            end else begin
                // Writing to row1
                row1_mem[wr_col] <= wr_data;
                if (wr_col == effective_width - 1) begin
                    reg_row1_valid <= 1'b1;
                    row1_count <= 16'd0;
                end else begin
                    row1_count <= row1_count + 1;
                end
            end
        end
    end
    
    //=======================================================
    // Read Logic - Combinational for low latency
    // Returns 4 neighbors: (x0,y0), (x0+1,y0), (x0,y1), (x0+1,y1)
    //=======================================================
    logic [15:0] x0_clamped, x1_clamped;
    
    always_comb begin
        // Clamp x coordinates
        x0_clamped = (rd_col >= effective_width) ? effective_width - 1 : rd_col;
        x1_clamped = (rd_col + 1 >= effective_width) ? effective_width - 1 : rd_col + 1;
        
        // Read 4 neighbors
        p00 = row0_mem[x0_clamped];
        p01 = row0_mem[x1_clamped];
        p10 = row1_mem[x0_clamped];
        p11 = row1_mem[x1_clamped];
        
        // Valid when both rows are loaded
        rd_valid = reg_row0_valid && reg_row1_valid;
    end
    
    //=======================================================
    // Status outputs
    //=======================================================
    assign row0_valid = reg_row0_valid;
    assign row1_valid = reg_row1_valid;
    assign row0_y = reg_row0_y;
    assign row1_y = reg_row1_y;

    //=======================================================
    // Row Y coordinate tracking (set externally via control)
    //=======================================================
    // These will be updated by the pixel_fetch_fsm
    
endmodule
