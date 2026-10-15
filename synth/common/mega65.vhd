-- The part of the top level that is the same on all MEGA65 boards: the clock
-- and reset, the UART pins, and the NiceMon system.

library ieee;
   use ieee.std_logic_1164.all;

entity mega65 is
   generic (
      G_INIT_FILE : string := ""
   );
   port (
      clk_i          : in  std_logic; -- 100 MHz
      reset_button_i : in  std_logic; -- active high
      uart_rxd_i     : in  std_logic;
      uart_txd_o     : out std_logic;
      led_o          : out std_logic  -- on while the core runs
   );
end entity mega65;

architecture synthesis of mega65 is

   constant C_CLOCK_HZ : natural := 50_000_000;

   signal clk     : std_logic;
   signal rst     : std_logic;
   signal rxd     : std_logic_vector(1 downto 0) := "11";
   signal txd     : std_logic;
   signal running : std_logic;

   -- The output registers start at the idle level of their pins. A flip-flop
   -- with no initial value configures as 0, which would hold the UART output
   -- low, a break, until the MMCM locks and the clock runs.
   signal txd_reg : std_logic := '1';
   signal led_reg : std_logic := '0';

begin

   i_clk_rst : entity work.clk_rst
      port map (
         sys_clk_i      => clk_i,
         reset_button_i => reset_button_i,
         clk_o          => clk,
         rst_o          => rst
      ); -- i_clk_rst

   -- Synchronise the UART input, and register the outputs.
   p_io : process (clk)
   begin
      if rising_edge(clk) then
         rxd        <= rxd(0) & uart_rxd_i;
         txd_reg <= txd;
         led_reg <= running;
      end if;
   end process p_io;

   uart_txd_o <= txd_reg;
   led_o      <= led_reg;

   i_nicemon : entity work.nicemon
      generic map (
         G_CLOCK_HZ      => C_CLOCK_HZ,
         G_UART_BAUDRATE => 115_200,
         G_RAM_ADDR_BITS => 16,
         G_INIT_FILE     => G_INIT_FILE
      )
      port map (
         clk_i      => clk,
         rst_i      => rst,
         uart_rxd_i => rxd(1),
         uart_txd_o => txd,
         running_o  => running
      ); -- i_nicemon

end architecture synthesis;
