-- Runs the NiceMon system with its UART on a pseudo-terminal of the host
-- (pty.c), so that tools/nicemon.py, load.py, and run.py can be used with
-- the simulation as with the board: give them --port sim/build/nicemon.pty.
-- It runs until it is stopped.
--
-- THEORY OF OPERATION
-- p_to_board polls the pseudo-terminal for a byte from the tool, and sends
-- each one to the UART input as a frame. p_from_board decodes the UART
-- output, and writes each byte to the pseudo-terminal. The system has the
-- board's memory sizes, and no ROM unless G_ROM_FILE is given. Its clock
-- is 10 MHz and its UART runs at a tenth of that, so that the bytes come
-- quickly; the time the tools wait is real time, not simulated time.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity tb_cosim is
   generic (
      G_ROM_FILE : string := ""
   );
end entity tb_cosim;

architecture simulation of tb_cosim is

   constant C_CLOCK_HZ : natural := 10_000_000;
   constant C_BAUDRATE : natural := 1_000_000;
   constant C_BIT_TIME : time    := 1 us;

   function pty_open return integer is
   begin
      report "pty_open: not linked"
         severity failure;
      return -1;
   end function pty_open;

   attribute foreign of pty_open : function is "VHPIDIRECT ./libpty.so pty_open";

   function pty_read return integer is
   begin
      return -1;
   end function pty_read;

   attribute foreign of pty_read : function is "VHPIDIRECT ./libpty.so pty_read";

   function pty_write(c : integer) return integer is
   begin
      return 0;
   end function pty_write;

   attribute foreign of pty_write : function is "VHPIDIRECT ./libpty.so pty_write";

   signal clk     : std_logic;
   signal rst     : std_logic := '1';
   signal uart_rx : std_logic := '1';
   signal uart_tx : std_logic;
   signal opened  : boolean   := false;

begin

   p_clk : process
   begin
      clk <= '1', '0' after 50 ns;
      wait for 100 ns;
   end process p_clk;

   p_rst : process
   begin
      assert pty_open = 0
         report "tb_cosim: no pseudo-terminal"
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
         running_o      => open,
         scr_we_o       => open,
         scr_addr_o     => open,
         scr_data_o     => open,
         scr_ctl_we_o   => open,
         scr_cur_x_o    => open,
         scr_cur_y_o    => open,
         scr_cur_mode_o => open,
         scr_offs_o     => open
      ); -- i_nicemon

   p_to_board : process
      variable c_v    : integer;
      variable byte_v : std_logic_vector(7 downto 0);
   begin
      wait until opened;
      loop
         c_v := pty_read;
         if c_v < 0 then
            wait for 10 * C_BIT_TIME;
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
      r_v := pty_write(to_integer(byte_v));
   end process p_from_board;

end architecture simulation;
