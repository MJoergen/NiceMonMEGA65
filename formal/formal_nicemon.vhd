-- The whole system, nicemon.vhd, with its checks (G_FORMAL), for
-- SymbiYosys. Every input is free, and so are the core, nice_core_formal.vhd,
-- and the debug link, debug_link_formal.vhd, so the solver makes every
-- request that a core or the link may make, and sends every byte on the
-- UART and the keyboard at any time.
-- The sizes are small: 16 words of RAM, a FIFO of 4 bytes, and a UART bit
-- of 2 cycles. Only the ratio matters to the UART, but nice_cpu's perf.vhd
-- needs a clock of 1 MHz or more for its microsecond counter, so the clock
-- is 2 MHz and the UART runs at 1 Mbaud.
-- G_ROM_FILE gives the system a ROM of 4 words, rom.bin, or none when it
-- is empty, and G_BOARD_IO gives it the board's registers at
-- 0xFFFFFF90-9F, with free buttons and switches. G_SD_SLOTS gives it the
-- SD card controller at 0xFFFFFFA0-AF, in the boards' configuration,
-- without G_SD_HOLD_ACK, with free card pins.
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
      G_CPU_RUN_AT_RESET : boolean;
      G_ROM_FILE         : string               := "";
      G_BOARD_IO         : boolean              := false;
      G_SD_SLOTS         : natural range 0 to 2 := 0
   );
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;
      uart_rxd_i  : in  std_logic;
      kbd_valid_i : in  std_logic;
      kbd_data_i  : in  std_logic_vector(7 downto 0);
      brd_btn_i   : in  std_logic_vector(4 downto 0);
      brd_sw_i    : in  std_logic_vector(15 downto 0);
      sd_dat0_i   : in  std_logic_vector(1 downto 0);
      sd_cd_n_i   : in  std_logic_vector(1 downto 0);
      sd_wp_i     : in  std_logic_vector(1 downto 0)
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
   signal brd_led      : std_logic_vector(15 downto 0);
   signal brd_rgb0     : std_logic_vector(11 downto 0);
   signal brd_rgb1     : std_logic_vector(11 downto 0);
   signal brd_seg      : std_logic_vector(63 downto 0);
   signal sd_clk       : std_logic_vector(1 downto 0);
   signal sd_cmd       : std_logic_vector(1 downto 0);
   signal sd_dat3      : std_logic_vector(1 downto 0);
   signal sd_pwr_n     : std_logic;

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
         G_ROM_FILE         => G_ROM_FILE,
         G_ROM_ADDR_BITS    => 2,
         G_CPU_RUN_AT_RESET => G_CPU_RUN_AT_RESET,
         G_BOARD_IO         => G_BOARD_IO,
         G_SD_SLOTS         => G_SD_SLOTS,
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
         scr_offs_o     => scr_offs,
         brd_led_o      => brd_led,
         brd_rgb0_o     => brd_rgb0,
         brd_rgb1_o     => brd_rgb1,
         brd_seg_o      => brd_seg,
         brd_btn_i      => brd_btn_i,
         brd_sw_i       => brd_sw_i,
         sd_clk_o       => sd_clk,
         sd_cmd_o       => sd_cmd,
         sd_dat3_o      => sd_dat3,
         sd_dat0_i      => sd_dat0_i,
         sd_cd_n_i      => sd_cd_n_i,
         sd_wp_i        => sd_wp_i,
         sd_pwr_n_o     => sd_pwr_n
      ); -- i_nicemon

end architecture synthesis;
