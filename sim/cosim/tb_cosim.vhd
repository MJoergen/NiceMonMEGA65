-- Runs the system with its debug UART on a TCP port of 127.0.0.1
-- (cosim.c), so that the tools drive the RTL as they drive the board:
-- tools/run.py --cosim PORT, and likewise load.py. It runs until it is
-- stopped.
--
-- THEORY OF OPERATION
-- p_to_board polls cosim.c for a byte from the host and sends each one to
-- the UART input as a frame, 8-N-1. The end of the host's bytes, a
-- half-close or a close of its connection, is sent as a break, the line
-- low for longer than a frame, which ends the program's input as on the
-- board. While no byte has come, it polls again after a frame's time.
-- p_from_board decodes the UART output and hands each byte to cosim.c.
--
-- The system has the board's sizes, and no ROM unless G_ROM_FILE is given.
-- The clock is 10 MHz and the UART runs at 1 Mbaud, 10 cycles per bit, so
-- that the bytes come as quickly as the UART takes them. The simulation
-- runs far slower than real time, but the host's bytes arrive back to
-- back in simulated time. So the link's timeout of DEBUG.md §5, 100 ms
-- between two bytes, is 100 ms of simulated time, which a slow host
-- never reaches.
--
-- RESET
-- The system is reset for the first microsecond, and its b notice goes to
-- no host. Later connections reset nothing.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity tb_cosim is
   generic (
      -- The TCP port, or 0 for any free one, which cosim.c prints
      G_PORT     : natural := 0;
      G_ROM_FILE : string  := ""
   );
end entity tb_cosim;

architecture simulation of tb_cosim is

   constant C_CLOCK_HZ : natural := 10_000_000;
   constant C_PERIOD   : time    := 1 sec / C_CLOCK_HZ;
   constant C_BAUDRATE : natural := 1_000_000;
   constant C_BIT_TIME : time    := (C_CLOCK_HZ / C_BAUDRATE) * C_PERIOD;

   function cosim_open (tcp_port : integer) return integer is
   begin
      report "tb_cosim: cosim_open is not linked"
         severity failure;
      return -1;
   end function cosim_open;

   attribute foreign of cosim_open : function is "VHPIDIRECT ./libcosim.so cosim_open";

   function cosim_read return integer is
   begin
      return -1;
   end function cosim_read;

   attribute foreign of cosim_read : function is "VHPIDIRECT ./libcosim.so cosim_read";

   function cosim_write (c : integer) return integer is
   begin
      return 0;
   end function cosim_write;

   attribute foreign of cosim_write : function is "VHPIDIRECT ./libcosim.so cosim_write";

   signal clk     : std_logic;
   signal rst     : std_logic := '1';
   signal uart_rx : std_logic := '1';
   signal uart_tx : std_logic;
   signal opened  : boolean   := false;

begin

   p_clk : process
   begin
      clk <= '1', '0' after C_PERIOD / 2;
      wait for C_PERIOD;
   end process p_clk;

   p_rst : process
   begin
      assert cosim_open(G_PORT) = 0
         report "tb_cosim: cannot listen on port " & natural'image(G_PORT)
         severity failure;
      opened <= true;
      wait for 1 us;
      rst    <= '0';
      wait;
   end process p_rst;


   i_nicemon : entity work.nicemon
      generic map (
         G_CLOCK_HZ      => C_CLOCK_HZ,
         G_UART_BAUDRATE => C_BAUDRATE,
         G_ROM_FILE      => G_ROM_FILE
      )
      port map (
         clk_i          => clk,
         rst_i          => rst,
         uart_rxd_i     => uart_rx,
         uart_txd_o     => uart_tx,
         kbd_valid_i    => '0',
         kbd_ready_o    => open,
         kbd_data_i     => X"00",
         running_o      => open,
         scr_we_o       => open,
         scr_addr_o     => open,
         scr_data_o     => open,
         scr_ctl_we_o   => open,
         scr_cur_x_o    => open,
         scr_cur_y_o    => open,
         scr_cur_mode_o => open,
         scr_offs_o     => open,
         brd_led_o      => open,
         brd_rgb0_o     => open,
         brd_rgb1_o     => open,
         brd_seg_o      => open
      ); -- i_nicemon


   p_to_board : process
      variable c_v    : integer;
      variable byte_v : std_logic_vector(7 downto 0);
   begin
      wait until opened;
      loop
         c_v := cosim_read;
         if c_v = -1 then
            wait for 10 * C_BIT_TIME;
         elsif c_v = -2 then
            uart_rx <= '0';
            wait for 12 * C_BIT_TIME;
            uart_rx <= '1';
            wait for C_BIT_TIME;
         else
            byte_v  := to_slv(c_v, 8);
            uart_rx <= '0';
            wait for C_BIT_TIME;
            for b in 0 to 7 loop
               uart_rx <= byte_v(b);
               wait for C_BIT_TIME;
            end loop;
            uart_rx <= '1';
            wait for C_BIT_TIME;
         end if;
      end loop;
   end process p_to_board;


   p_from_board : process
      variable byte_v : std_logic_vector(7 downto 0);
      variable r_v    : integer;
   begin
      wait until uart_tx = '0';
      wait for C_BIT_TIME / 2;
      for i in 0 to 7 loop
         wait for C_BIT_TIME;
         byte_v(i) := uart_tx;
      end loop;
      wait for C_BIT_TIME;
      r_v := cosim_write(to_integer(byte_v));
   end process p_from_board;

end architecture simulation;
