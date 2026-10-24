-- The whole system, nicemon.vhd, with its checks (G_FORMAL), for
-- SymbiYosys. Every input is free, and so are the core, nice_core_formal.vhd,
-- and the debug link, debug_link_formal.vhd, so the solver makes every
-- request that a core or the link may make, and sends every byte on the
-- UART and the keyboard at any time.
-- The sizes are small: 16 words of RAM, no ROM, a FIFO of 4 bytes, and a
-- UART bit of 2 cycles, from a clock of 2 MHz and a baud rate of 1 MHz. The
-- clock is not 2 Hz, as nice_cpu's perf wants 1 MHz or more for its
-- microsecond counter.
--
-- THEORY OF OPERATION
-- With G_CPU_RUN_AT_RESET the core runs the program in the RAM from reset,
-- and the link may hold it at any time. Without it the core is held, and
-- the link owns the bus, so the solver makes requests that read and write
-- memory and devices, and starts the core. The checks themselves are in
-- nicemon.vhd, where they see its signals.
--
-- RESET
-- The first cycle is a reset.

library ieee;
   use ieee.std_logic_1164.all;

entity formal_nicemon is
   generic (
      G_CPU_RUN_AT_RESET : boolean
   );
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;
      uart_rxd_i  : in  std_logic;
      kbd_valid_i : in  std_logic;
      kbd_data_i  : in  std_logic_vector(7 downto 0)
   );
end entity formal_nicemon;

architecture synthesis of formal_nicemon is

   signal uart_txd     : std_logic;
   signal kbd_ready    : std_logic;
   signal running      : std_logic;
   signal scr_we       : std_logic;
   signal scr_addr     : std_logic_vector(10 downto 0);
   signal scr_data     : std_logic_vector(31 downto 0);
   signal scr_ctl_we   : std_logic;
   signal scr_cur_x    : std_logic_vector(6 downto 0);
   signal scr_cur_y    : std_logic_vector(4 downto 0);
   signal scr_cur_mode : std_logic_vector(2 downto 0);
   signal scr_offs     : std_logic_vector(10 downto 0);

begin

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;


   i_nicemon : entity work.nicemon
      generic map (
         G_CLOCK_HZ         => 2_000_000,
         G_UART_BAUDRATE    => 1_000_000,
         G_RAM_ADDR_BITS    => 4,
         G_SCR_ADDR_BITS    => 11,
         G_RX_FIFO_BITS     => 2,
         G_ROM_ADDR_BITS    => 2,
         G_CPU_RUN_AT_RESET => G_CPU_RUN_AT_RESET,
         G_FORMAL           => true
      )
      port map (
         clk_i          => clk_i,
         rst_i          => rst_i,
         uart_rxd_i     => uart_rxd_i,
         uart_txd_o     => uart_txd,
         kbd_valid_i    => kbd_valid_i,
         kbd_ready_o    => kbd_ready,
         kbd_data_i     => kbd_data_i,
         running_o      => running,
         scr_we_o       => scr_we,
         scr_addr_o     => scr_addr,
         scr_data_o     => scr_data,
         scr_ctl_we_o   => scr_ctl_we,
         scr_cur_x_o    => scr_cur_x,
         scr_cur_y_o    => scr_cur_y,
         scr_cur_mode_o => scr_cur_mode,
         scr_offs_o     => scr_offs
      ); -- i_nicemon

end architecture synthesis;
