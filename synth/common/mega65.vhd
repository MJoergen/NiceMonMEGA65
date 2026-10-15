-- The part of the top level that is the same on all MEGA65 boards: the clock
-- and reset, the UART pins, the keyboard, and the NiceMon system. The
-- keyboard types into the same input as the UART. Its power LED is green, and
-- its drive LED is green while the core runs, like the user LED.

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
      kb_io0_o       : out std_logic; -- clock to the keyboard
      kb_io1_o       : out std_logic; -- data to the keyboard
      kb_io2_i       : in  std_logic; -- data from the keyboard
      led_o          : out std_logic  -- on while the core runs
   );
end entity mega65;

architecture synthesis of mega65 is

   constant C_CLOCK_HZ : natural := 50_000_000;

   signal clk     : std_logic;
   signal rst     : std_logic;
   signal rxd     : std_logic_vector(1 downto 0) := "11";
   attribute async_reg : string;
   attribute async_reg of rxd : signal is "TRUE";
   signal txd     : std_logic;
   signal running : std_logic;

   constant C_GREEN : std_logic_vector(23 downto 0) := X"00FF00";

   signal kbd_matrix : std_logic_vector(79 downto 0);
   signal kbd_valid  : std_logic;
   signal kbd_ready  : std_logic;
   signal kbd_data   : std_logic_vector(7 downto 0);
   signal drive_rgb  : std_logic_vector(23 downto 0);

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
         rxd     <= rxd(0) & uart_rxd_i;
         txd_reg <= txd;
         led_reg <= running;
      end if;
   end process p_io;

   uart_txd_o <= txd_reg;
   led_o      <= led_reg;

   drive_rgb <= C_GREEN when running = '1' else X"000000";

   i_kbd_m65 : entity work.kbd_m65
      generic map (
         G_CLOCK_HZ => C_CLOCK_HZ
      )
      port map (
         clk_i       => clk,
         rst_i       => rst,
         matrix_o    => kbd_matrix,
         power_rgb_i => C_GREEN,
         drive_rgb_i => drive_rgb,
         kb_clk_o    => kb_io0_o,
         kb_data_o   => kb_io1_o,
         kb_data_i   => kb_io2_i
      ); -- i_kbd_m65

   i_kbd_ascii : entity work.kbd_ascii
      generic map (
         G_CLOCK_HZ => C_CLOCK_HZ
      )
      port map (
         clk_i        => clk,
         rst_i        => rst,
         matrix_i     => kbd_matrix,
         data_valid_o => kbd_valid,
         data_ready_i => kbd_ready,
         data_o       => kbd_data
      ); -- i_kbd_ascii

   i_nicemon : entity work.nicemon
      generic map (
         G_CLOCK_HZ      => C_CLOCK_HZ,
         G_UART_BAUDRATE => 115_200,
         G_RAM_ADDR_BITS => 16,
         G_INIT_FILE     => G_INIT_FILE
      )
      port map (
         clk_i       => clk,
         rst_i       => rst,
         uart_rxd_i  => rxd(1),
         uart_txd_o  => txd,
         kbd_valid_i => kbd_valid,
         kbd_ready_o => kbd_ready,
         kbd_data_i  => kbd_data,
         running_o   => running
      ); -- i_nicemon

end architecture synthesis;
