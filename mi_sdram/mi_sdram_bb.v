
module mi_sdram (
	clk_clk,
	clk_0_clk,
	fpga_logic_master_address,
	fpga_logic_master_burstcount,
	fpga_logic_master_read,
	fpga_logic_master_write,
	fpga_logic_master_waitrequest,
	fpga_logic_master_readdatavalid,
	fpga_logic_master_byteenable,
	fpga_logic_master_readdata,
	fpga_logic_master_writedata,
	fpga_logic_master_lock,
	fpga_logic_master_debugaccess,
	reset_reset_n,
	reset_0_reset_n,
	sdram_wire_addr_addr,
	sdram_wire_addr_ba,
	sdram_wire_addr_cas_n,
	sdram_wire_addr_cke,
	sdram_wire_addr_cs_n,
	sdram_wire_addr_dq,
	sdram_wire_addr_dqm,
	sdram_wire_addr_ras_n,
	sdram_wire_addr_we_n);	

	input		clk_clk;
	input		clk_0_clk;
	output	[37:0]	fpga_logic_master_address;
	output	[9:0]	fpga_logic_master_burstcount;
	output		fpga_logic_master_read;
	output		fpga_logic_master_write;
	input		fpga_logic_master_waitrequest;
	input		fpga_logic_master_readdatavalid;
	output	[3:0]	fpga_logic_master_byteenable;
	input	[31:0]	fpga_logic_master_readdata;
	output	[31:0]	fpga_logic_master_writedata;
	output		fpga_logic_master_lock;
	output		fpga_logic_master_debugaccess;
	input		reset_reset_n;
	input		reset_0_reset_n;
	output	[11:0]	sdram_wire_addr_addr;
	output	[1:0]	sdram_wire_addr_ba;
	output		sdram_wire_addr_cas_n;
	output		sdram_wire_addr_cke;
	output		sdram_wire_addr_cs_n;
	inout	[15:0]	sdram_wire_addr_dq;
	output	[1:0]	sdram_wire_addr_dqm;
	output		sdram_wire_addr_ras_n;
	output		sdram_wire_addr_we_n;
endmodule
