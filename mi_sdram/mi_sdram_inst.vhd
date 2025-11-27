	component mi_sdram is
		port (
			clk_clk                         : in    std_logic                     := 'X';             -- clk
			clk_0_clk                       : in    std_logic                     := 'X';             -- clk
			fpga_logic_master_address       : out   std_logic_vector(37 downto 0);                    -- address
			fpga_logic_master_burstcount    : out   std_logic_vector(9 downto 0);                     -- burstcount
			fpga_logic_master_read          : out   std_logic;                                        -- read
			fpga_logic_master_write         : out   std_logic;                                        -- write
			fpga_logic_master_waitrequest   : in    std_logic                     := 'X';             -- waitrequest
			fpga_logic_master_readdatavalid : in    std_logic                     := 'X';             -- readdatavalid
			fpga_logic_master_byteenable    : out   std_logic_vector(3 downto 0);                     -- byteenable
			fpga_logic_master_readdata      : in    std_logic_vector(31 downto 0) := (others => 'X'); -- readdata
			fpga_logic_master_writedata     : out   std_logic_vector(31 downto 0);                    -- writedata
			fpga_logic_master_lock          : out   std_logic;                                        -- lock
			fpga_logic_master_debugaccess   : out   std_logic;                                        -- debugaccess
			reset_reset_n                   : in    std_logic                     := 'X';             -- reset_n
			reset_0_reset_n                 : in    std_logic                     := 'X';             -- reset_n
			sdram_wire_addr_addr            : out   std_logic_vector(11 downto 0);                    -- addr
			sdram_wire_addr_ba              : out   std_logic_vector(1 downto 0);                     -- ba
			sdram_wire_addr_cas_n           : out   std_logic;                                        -- cas_n
			sdram_wire_addr_cke             : out   std_logic;                                        -- cke
			sdram_wire_addr_cs_n            : out   std_logic;                                        -- cs_n
			sdram_wire_addr_dq              : inout std_logic_vector(15 downto 0) := (others => 'X'); -- dq
			sdram_wire_addr_dqm             : out   std_logic_vector(1 downto 0);                     -- dqm
			sdram_wire_addr_ras_n           : out   std_logic;                                        -- ras_n
			sdram_wire_addr_we_n            : out   std_logic                                         -- we_n
		);
	end component mi_sdram;

	u0 : component mi_sdram
		port map (
			clk_clk                         => CONNECTED_TO_clk_clk,                         --               clk.clk
			clk_0_clk                       => CONNECTED_TO_clk_0_clk,                       --             clk_0.clk
			fpga_logic_master_address       => CONNECTED_TO_fpga_logic_master_address,       -- fpga_logic_master.address
			fpga_logic_master_burstcount    => CONNECTED_TO_fpga_logic_master_burstcount,    --                  .burstcount
			fpga_logic_master_read          => CONNECTED_TO_fpga_logic_master_read,          --                  .read
			fpga_logic_master_write         => CONNECTED_TO_fpga_logic_master_write,         --                  .write
			fpga_logic_master_waitrequest   => CONNECTED_TO_fpga_logic_master_waitrequest,   --                  .waitrequest
			fpga_logic_master_readdatavalid => CONNECTED_TO_fpga_logic_master_readdatavalid, --                  .readdatavalid
			fpga_logic_master_byteenable    => CONNECTED_TO_fpga_logic_master_byteenable,    --                  .byteenable
			fpga_logic_master_readdata      => CONNECTED_TO_fpga_logic_master_readdata,      --                  .readdata
			fpga_logic_master_writedata     => CONNECTED_TO_fpga_logic_master_writedata,     --                  .writedata
			fpga_logic_master_lock          => CONNECTED_TO_fpga_logic_master_lock,          --                  .lock
			fpga_logic_master_debugaccess   => CONNECTED_TO_fpga_logic_master_debugaccess,   --                  .debugaccess
			reset_reset_n                   => CONNECTED_TO_reset_reset_n,                   --             reset.reset_n
			reset_0_reset_n                 => CONNECTED_TO_reset_0_reset_n,                 --           reset_0.reset_n
			sdram_wire_addr_addr            => CONNECTED_TO_sdram_wire_addr_addr,            --   sdram_wire_addr.addr
			sdram_wire_addr_ba              => CONNECTED_TO_sdram_wire_addr_ba,              --                  .ba
			sdram_wire_addr_cas_n           => CONNECTED_TO_sdram_wire_addr_cas_n,           --                  .cas_n
			sdram_wire_addr_cke             => CONNECTED_TO_sdram_wire_addr_cke,             --                  .cke
			sdram_wire_addr_cs_n            => CONNECTED_TO_sdram_wire_addr_cs_n,            --                  .cs_n
			sdram_wire_addr_dq              => CONNECTED_TO_sdram_wire_addr_dq,              --                  .dq
			sdram_wire_addr_dqm             => CONNECTED_TO_sdram_wire_addr_dqm,             --                  .dqm
			sdram_wire_addr_ras_n           => CONNECTED_TO_sdram_wire_addr_ras_n,           --                  .ras_n
			sdram_wire_addr_we_n            => CONNECTED_TO_sdram_wire_addr_we_n             --                  .we_n
		);

