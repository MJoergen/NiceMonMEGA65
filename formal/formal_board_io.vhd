-- The board's devices (src/board_io.vhd), with their properties, for
-- SymbiYosys. Every input is free, so the solver writes and reads any word,
-- and presses any button, at any time. G_BOARD_IO is the task's: with the
-- registers, or without them; and so is G_I2C, with the I2C master, whose
-- lines are free too.
--
-- RESET
-- The first cycle is a reset.

library ieee;
   use ieee.std_logic_1164.all;

entity formal_board_io is
   generic (
      G_BOARD_IO : boolean := true;
      G_I2C      : boolean := false
   );
   port (
      clk_i   : in  std_logic;
      rst_i   : in  std_logic;
      stb_i   : in  std_logic;
      we_i    : in  std_logic;
      addr_i  : in  std_logic_vector(3 downto 0);
      wdata_i : in  std_logic_vector(31 downto 0);
      btn_i   : in  std_logic_vector(4 downto 0);
      sw_i    : in  std_logic_vector(15 downto 0);
      scl_i   : in  std_logic;
      sda_i   : in  std_logic
   );
end entity formal_board_io;

architecture synthesis of formal_board_io is

   signal rdata : std_logic_vector(31 downto 0);

begin

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;


   i_board_io : entity work.board_io
      generic map (
         G_BOARD_IO  => G_BOARD_IO,
         G_I2C       => G_I2C,
         G_RAM_WORDS => 16#20000#,
         G_FORMAL    => true
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         stb_i       => stb_i,
         we_i        => we_i,
         addr_i      => addr_i,
         wdata_i     => wdata_i,
         rdata_o     => rdata,
         led_o       => open,
         rgb0_o      => open,
         rgb1_o      => open,
         seg_o       => open,
         btn_i       => btn_i,
         sw_i        => sw_i,
         uart_baud_o => open,
         uart_div_o  => open,
         i2c_scl_o   => open,
         i2c_sda_o   => open,
         i2c_scl_i   => scl_i,
         i2c_sda_i   => sda_i
      ); -- i_board_io

end architecture synthesis;
