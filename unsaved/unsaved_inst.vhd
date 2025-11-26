	component unsaved is
		port (
			clk_clk         : in std_logic := 'X'; -- clk
			reset_reset_n   : in std_logic := 'X'; -- reset_n
			clk_0_clk       : in std_logic := 'X'; -- clk
			reset_0_reset_n : in std_logic := 'X'  -- reset_n
		);
	end component unsaved;

	u0 : component unsaved
		port map (
			clk_clk         => CONNECTED_TO_clk_clk,         --     clk.clk
			reset_reset_n   => CONNECTED_TO_reset_reset_n,   --   reset.reset_n
			clk_0_clk       => CONNECTED_TO_clk_0_clk,       --   clk_0.clk
			reset_0_reset_n => CONNECTED_TO_reset_0_reset_n  -- reset_0.reset_n
		);

