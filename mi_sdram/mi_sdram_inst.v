	mi_sdram u0 (
		.clk_clk                         (<connected-to-clk_clk>),                         //               clk.clk
		.fpga_logic_master_address       (<connected-to-fpga_logic_master_address>),       // fpga_logic_master.address
		.fpga_logic_master_burstcount    (<connected-to-fpga_logic_master_burstcount>),    //                  .burstcount
		.fpga_logic_master_read          (<connected-to-fpga_logic_master_read>),          //                  .read
		.fpga_logic_master_write         (<connected-to-fpga_logic_master_write>),         //                  .write
		.fpga_logic_master_waitrequest   (<connected-to-fpga_logic_master_waitrequest>),   //                  .waitrequest
		.fpga_logic_master_readdatavalid (<connected-to-fpga_logic_master_readdatavalid>), //                  .readdatavalid
		.fpga_logic_master_byteenable    (<connected-to-fpga_logic_master_byteenable>),    //                  .byteenable
		.fpga_logic_master_readdata      (<connected-to-fpga_logic_master_readdata>),      //                  .readdata
		.fpga_logic_master_writedata     (<connected-to-fpga_logic_master_writedata>),     //                  .writedata
		.fpga_logic_master_lock          (<connected-to-fpga_logic_master_lock>),          //                  .lock
		.fpga_logic_master_debugaccess   (<connected-to-fpga_logic_master_debugaccess>),   //                  .debugaccess
		.reset_reset_n                   (<connected-to-reset_reset_n>),                   //             reset.reset_n
		.reset_0_reset_n                 (<connected-to-reset_0_reset_n>),                 //           reset_0.reset_n
		.clk_0_clk                       (<connected-to-clk_0_clk>),                       //             clk_0.clk
		.sdram_wire_addr_addr            (<connected-to-sdram_wire_addr_addr>),            //   sdram_wire_addr.addr
		.sdram_wire_addr_ba              (<connected-to-sdram_wire_addr_ba>),              //                  .ba
		.sdram_wire_addr_cas_n           (<connected-to-sdram_wire_addr_cas_n>),           //                  .cas_n
		.sdram_wire_addr_cke             (<connected-to-sdram_wire_addr_cke>),             //                  .cke
		.sdram_wire_addr_cs_n            (<connected-to-sdram_wire_addr_cs_n>),            //                  .cs_n
		.sdram_wire_addr_dq              (<connected-to-sdram_wire_addr_dq>),              //                  .dq
		.sdram_wire_addr_dqm             (<connected-to-sdram_wire_addr_dqm>),             //                  .dqm
		.sdram_wire_addr_ras_n           (<connected-to-sdram_wire_addr_ras_n>),           //                  .ras_n
		.sdram_wire_addr_we_n            (<connected-to-sdram_wire_addr_we_n>)             //                  .we_n
	);

