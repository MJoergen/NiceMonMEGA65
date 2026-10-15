-- The clock and reset of the MEGA65 boards. The board's 100 MHz clock drives
-- an MMCM that makes the 50 MHz system clock. The reset is held while the
-- MMCM is not locked, and while the reset button (active high) is pressed,
-- and for 2^20 cycles (21 ms) after both. So the UART output is idle for that
-- long before the CLI sends its banner, and a terminal that saw the pin
-- change during configuration has time to find the start of a character.
-- The MMCM's locked output and the button are synchronised to clk_o by two
-- registers each, as in MandelbrotMEGA65's clk_rst.vhd.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

library unisim;
   use unisim.vcomponents.all;

entity clk_rst is
   port (
      sys_clk_i      : in  std_logic; -- 100 MHz
      reset_button_i : in  std_logic; -- active high, asynchronous
      clk_o          : out std_logic; -- 50 MHz
      rst_o          : out std_logic  -- synchronous to clk_o
   );
end entity clk_rst;

architecture synthesis of clk_rst is

   signal clkfb     : std_logic;
   signal clkfb_buf : std_logic;
   signal clk_mmcm  : std_logic;
   signal locked    : std_logic;

   signal locked_sync : std_logic_vector(1 downto 0) := "00";
   signal button_sync : std_logic_vector(1 downto 0) := "11";
   signal counter     : std_logic_vector(19 downto 0) := (others => '1');

   -- The registers of the synchronisers
   attribute async_reg : string;
   attribute async_reg of locked_sync : signal is "true";
   attribute async_reg of button_sync : signal is "true";

begin

   -- The Xilinx primitives are components of unisim.vcomponents, and their
   -- generics and ports are named in upper case, as in Xilinx's documentation.
-- vsg_off
   i_mmcm : MMCME2_BASE
      generic map (
         CLKIN1_PERIOD    => 10.0,  -- 100 MHz
         DIVCLK_DIVIDE    => 1,
         CLKFBOUT_MULT_F  => 10.0,  -- VCO at 1000 MHz
         CLKOUT0_DIVIDE_F => 20.0   -- 50 MHz
      )
      port map (
         CLKIN1   => sys_clk_i,
         CLKFBIN  => clkfb_buf,
         CLKFBOUT => clkfb,
         CLKOUT0  => clk_mmcm,
         LOCKED   => locked,
         PWRDWN   => '0',
         RST      => '0'
      ); -- i_mmcm

   i_bufg_fb : BUFG
      port map (
         I => clkfb,
         O => clkfb_buf
      ); -- i_bufg_fb

   i_bufg_clk : BUFG
      port map (
         I => clk_mmcm,
         O => clk_o
      ); -- i_bufg_clk
-- vsg_on

   p_rst : process (clk_o)
   begin
      if rising_edge(clk_o) then
         locked_sync <= locked_sync(0) & locked;
         button_sync <= button_sync(0) & reset_button_i;
         if locked_sync(1) = '0' or button_sync(1) = '1' then
            counter <= (others => '1');
         elsif counter /= 0 then
            counter <= counter - 1;
         end if;
      end if;
   end process p_rst;

   rst_o <= '1' when counter /= 0 else '0';

end architecture synthesis;
