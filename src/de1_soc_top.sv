// Top-level module for the DE1-SoC board
module de1_soc_top (
    // Main clock and reset
    input logic CLOCK_50,
    input logic [0:0] KEY, // Use KEY[0] as active-low reset

    // SDRAM Interface
    output logic [12:0] DRAM_ADDR,
    output logic [1:0]  DRAM_BA,
    output logic        DRAM_CAS_N,
    output logic        DRAM_CKE,
    output logic        DRAM_CLK,
    output logic        DRAM_CS_N,
    inout  logic [15:0] DRAM_DQ,
    output logic [1:0]  DRAM_DQM,
    output logic        DRAM_RAS_N,
    output logic        DRAM_WE_N
);

    // Internal logic signals
    logic sys_clk;
    logic sys_rst_n;

    // Assign clock and active-low reset
    assign sys_clk = CLOCK_50;
    assign sys_rst_n = KEY[0];

    // Instantiate the Platform Designer system
    mi_sdram u0 (
        .clk_clk                             (sys_clk),
        .reset_reset_n                       (sys_rst_n),
        
        // SDRAM Connections - Corrected based on your generated file
        .sdram_wire_addr_addr                (DRAM_ADDR),
        .sdram_wire_addr_ba                  (DRAM_BA),
        .sdram_wire_addr_cas_n               (DRAM_CAS_N),
        .sdram_wire_addr_cke                 (DRAM_CKE),
        .sdram_wire_addr_cs_n                (DRAM_CS_N),
        .sdram_wire_addr_dq                  (DRAM_DQ),
        .sdram_wire_addr_dqm                 (DRAM_DQM),
        .sdram_wire_addr_ras_n               (DRAM_RAS_N),
        .sdram_wire_addr_we_n                (DRAM_WE_N),
        // Assuming the clock output was exported as clk_0_clk based on your paste
        .clk_0_clk                           (DRAM_CLK), 
        
        // Connections to our custom logic (fpga_top_bram)
        .fpga_logic_master_address           (avs_address),
        .fpga_logic_master_read              (avs_read),
        .fpga_logic_master_readdata          (avs_readdata),
        .fpga_logic_master_write             (avs_write),
        .fpga_logic_master_writedata         (avs_writedata),
        .fpga_logic_master_waitrequest       (avs_waitrequest),
        .fpga_logic_master_burstcount        (avs_burstcount),
        .fpga_logic_master_byteenable        (avs_byteenable),
        // Unused ports tied to default values
        .fpga_logic_master_readdatavalid     (),
        .fpga_logic_master_lock              (1'b0),
        .fpga_logic_master_debugaccess       (1'b0)
    );
	 
    // Wires to connect soc_system to our custom logic
    logic [31:0] avs_address;
    logic [3:0]  avs_burstcount;
    logic [7:0]  avs_byteenable;
    logic        avs_read;
    logic [63:0] avs_readdata;
    logic        avs_write;
    logic [63:0] avs_writedata;
    logic        avs_waitrequest;

    // Control signals for our logic
    logic start_processing; // This would be controlled by JTAG in a real scenario
    logic processing_done;
    logic processing_busy;

    // Instantiate our image processing logic
    fpga_top_bram image_processor (
        .clk(sys_clk),
        .rst_n(sys_rst_n),
        .start(start_processing),
        .done(processing_done),
        .busy(processing_busy),
        .avs_address(avs_address),
        .avs_read(avs_read),
        .avs_readdata(avs_readdata),
        .avs_write(avs_write),
        .avs_writedata(avs_writedata),
        .avs_waitrequest(avs_waitrequest)
        // Add default values for new ports if they were added to fpga_top_bram
        // For now, assuming they are not part of the module's port list.
    );

    // For now, let's tie the start signal high to begin processing immediately after reset.
    // In your final design, you would control this via JTAG.
    always_ff @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            start_processing <= 1'b0;
        end else begin
            start_processing <= 1'b1; // Start processing on the first clock after reset
        end
    end

endmodule
