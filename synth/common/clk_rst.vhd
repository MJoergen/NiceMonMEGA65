-- The clock and reset of the boards. The board's 100 MHz clock drives an MMCM
-- whose VCO runs at 100 MHz * G_MULTIPLY, and which makes the system clock,
-- the VCO's frequency / G_DIVIDE: 1000 MHz / 10 = 100 MHz on the MEGA65, and
-- 900 MHz / 10 = 90 MHz on the Nexys4DDR, whose FPGA is a slower speed
-- grade. The pipelined core meets 100 MHz on the MEGA65 with little to
-- spare, so recheck the timing after a change to nice_cpu.
-- The reset is held while the MMCM is not locked, and while the reset
-- button is pressed (G_BUTTON_LEVEL is its level then), and for 2^20 cycles
-- (10 ms at 100 MHz, 12 ms at 90 MHz) after both. So the UART output is idle
-- for that long before the link sends its `b01`, and a terminal that saw the
-- pin change during configuration has time to find the start of a character.
-- The MMCM's locked output and the button are synchronized to clk_o by two
-- registers each, as in MandelbrotMEGA65's clk_rst.vhd. The button is not
-- inverted before the first register, so that it can be an IOB flop whatever
-- its polarity.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

library unisim;
   use unisim.vcomponents.all;

entity clk_rst is
   generic (
      G_MULTIPLY     : real      := 10.0;
      G_DIVIDE       : real      := 10.0;
      G_BUTTON_LEVEL : std_logic := '1' -- level of reset_button_i when pressed
   );
   port (
      sys_clk_i      : in  std_logic; -- 100 MHz
      reset_button_i : in  std_logic; -- asynchronous
      clk_o          : out std_logic; -- 100 MHz * G_MULTIPLY / G_DIVIDE
      rst_o          : out std_logic  -- synchronous to clk_o
   );
end entity clk_rst;

architecture synthesis of clk_rst is

   signal clkfb     : std_logic;
   signal clkfb_buf : std_logic;
   signal clk_mmcm  : std_logic;
   signal locked    : std_logic;

   signal locked_sync : std_logic_vector(1 downto 0) := "00";
   signal button_sync : std_logic_vector(1 downto 0) := (others => G_BUTTON_LEVEL);
   signal counter     : std_logic_vector(19 downto 0) := (others => '1');
   signal rst         : std_logic := '1';

   -- The registers of the synchronizers
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
         CLKFBOUT_MULT_F  => G_MULTIPLY,
         CLKOUT0_DIVIDE_F => G_DIVIDE
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
         if locked_sync(1) = '0' or button_sync(1) = G_BUTTON_LEVEL then
            counter <= (others => '1');
         elsif counter /= 0 then
            counter <= counter - 1;
         end if;

         -- A register, as the reset reaches most of the design
         rst <= '1' when counter /= 0 else '0';
      end if;
   end process p_rst;

   rst_o <= rst;

end architecture synthesis;
