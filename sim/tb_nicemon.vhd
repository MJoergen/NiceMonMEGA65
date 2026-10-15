-- Tests the NiceMon system (src/nicemon.vhd) through its UART, as a user at
-- a terminal would: it loads programs with the CLI, runs them on the core,
-- and checks what comes back.
--
-- THEORY OF OPERATION
-- p_main sends lines to the UART with send(), and checks the UART output
-- with expect(). p_uart_rx decodes the UART output into rx_str. The steps:
--
-- 1. The CLI's banner after reset.
-- 2. Load G_HELLO_FILE with W commands, and read its first word back.
-- 3. The control register: the core is held in reset.
-- 4. Start the core. It prints "Hello, NICE!" and halts, and the CLI gets
--    the UART back: the control register shows the halted flag.
-- 5. Hold the core, load G_ECHO_FILE, and start it. It echoes the bytes it
--    receives until a '.', which checks the UART input of the core: every
--    byte from 0x80 to 0xFF, and a byte with a bad stop bit, which must be
--    dropped without losing the bytes after it.
-- 6. Hold the core, load G_FIFO_FILE, and start it. It waits before it
--    echoes, so the 17 bytes sent meanwhile pile up in the core's input
--    FIFO. The FIFO keeps the first 16 and loses the 17th, so a '.' sent
--    after them is echoed right after the 16th.
-- 7. Use the math unit from the CLI.
-- 8. Hold the core, load G_DEVICES_FILE, and run it. It uses the math unit
--    and the performance counters, and leaves the results in memory, which
--    the CLI reads back after the core has halted.
-- 9. Hold the core, load G_EMU_FILE, and run it. It writes the screen,
--    memory in the I/O range, and the read counter, and sets R5. The CLI
--    reads them back, and the registers, with the values that
--    "niceemu -d" prints for the same program.
--
-- The UART runs at a tenth of the clock rate, so that the test is fast.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.textio.all;
   use std.env.all;

entity tb_nicemon is
   generic (
      G_HELLO_FILE   : string;
      G_ECHO_FILE    : string;
      G_FIFO_FILE    : string;
      G_DEVICES_FILE : string;
      G_EMU_FILE     : string
   );
end entity tb_nicemon;

architecture simulation of tb_nicemon is

   constant C_CLOCK_HZ : natural := 100_000_000;
   constant C_BAUDRATE : natural := 10_000_000;
   constant C_BIT_TIME : time    := (C_CLOCK_HZ / C_BAUDRATE) * 10 ns;
   -- Longer than the slowest answer
   constant C_TIMEOUT  : time    := 1 ms;

   constant C_CR   : character := character'val(13);
   constant C_LF   : character := character'val(10);
   constant C_CRLF : string    := C_CR & C_LF;

   signal clk     : std_logic;
   signal rst     : std_logic;
   signal uart_rx : std_logic := '1';
   signal uart_tx : std_logic;
   signal running : std_logic;

   signal rx_str : string(1 to 4096);
   signal rx_len : natural := 0;

begin

   p_clk : process
   begin
      clk <= '1', '0' after 5 ns;
      wait for 10 ns;
   end process p_clk;


   i_nicemon : entity work.nicemon
      generic map (
         G_CLOCK_HZ      => C_CLOCK_HZ,
         G_UART_BAUDRATE => C_BAUDRATE,
         G_RAM_ADDR_BITS => 12
      )
      port map (
         clk_i      => clk,
         rst_i      => rst,
         uart_rxd_i => uart_rx,
         uart_txd_o => uart_tx,
         running_o  => running
      ); -- i_nicemon


   -- Decodes the UART output, 8-N-1, sampling in the middle of each bit.
   p_uart_rx : process
      variable byte_v : std_logic_vector(7 downto 0);
   begin
      wait until uart_tx = '0';
      wait for C_BIT_TIME / 2;
      for i in 0 to 7 loop
         wait for C_BIT_TIME;
         byte_v(i) := uart_tx;
      end loop;
      wait for C_BIT_TIME;
      assert uart_tx = '1'
         report "tb_nicemon: bad stop bit"
         severity failure;
      rx_str(rx_len + 1) <= character'val(to_integer(byte_v));
      rx_len             <= rx_len + 1;
   end process p_uart_rx;


   p_main : process
      variable pos_v : natural := 0;

      -- Sends one byte, with the stop bit given.
      procedure send_byte(c : character; stop_bit : std_logic := '1') is
         variable byte_v : std_logic_vector(7 downto 0);
      begin
         byte_v  := to_slv(character'pos(c), 8);
         uart_rx <= '0';
         wait for C_BIT_TIME;
         for b in 0 to 7 loop
            uart_rx <= byte_v(b);
            wait for C_BIT_TIME;
         end loop;
         uart_rx <= stop_bit;
         wait for C_BIT_TIME;
         uart_rx <= '1';
      end procedure send_byte;

      procedure send(s : string) is
      begin
         for i in s'range loop
            send_byte(s(i));
         end loop;
      end procedure send;

      -- The next characters of the UART output must be s.
      procedure expect(s : string) is
      begin
         if rx_len < pos_v + s'length then
            wait until rx_len >= pos_v + s'length for C_TIMEOUT;
         end if;
         assert rx_len >= pos_v + s'length
            report "tb_nicemon: timeout, waiting for """ & s & """, got """ &
                   rx_str(pos_v + 1 to rx_len) & """"
            severity failure;
         assert rx_str(pos_v + 1 to pos_v + s'length) = s
            report "tb_nicemon: expected """ & s & """, got """ &
                   rx_str(pos_v + 1 to pos_v + s'length) & """"
            severity failure;
         pos_v := pos_v + s'length;
      end procedure expect;

      procedure command(cmd : string; answer : string) is
      begin
         send(cmd & C_CR);
         expect(answer & C_CRLF);
      end procedure command;

      function upper(s : string) return string is
         variable res_v : string(1 to s'length) := s;
      begin
         for i in res_v'range loop
            if res_v(i) >= 'a' and res_v(i) <= 'f' then
               res_v(i) := character'val(character'pos(res_v(i)) - 32);
            end if;
         end loop;
         return res_v;
      end function upper;

      -- Writes each word of the .bin file with a W command. Returns the
      -- first word, as the R command prints it.
      procedure load(name : string; first : out string(1 to 8)) is
         file     f       : text;
         variable l       : line;
         variable first_v : boolean := true;
      begin
         file_open(f, name, read_mode);
         while not endfile(f) loop
            readline(f, l);
            if l'length = 17 then
               if first_v then
                  first   := upper(l.all(10 to 17));
                  first_v := false;
               end if;
               command("W " & l.all, "OK");
            end if;
         end loop;
         file_close(f);
      end procedure load;

      variable first_v : string(1 to 8);
      variable high_v  : string(1 to 128);

   begin
      rst <= '1';
      wait for 100 ns;
      wait until rising_edge(clk);
      rst <= '0';

      report "tb_nicemon: banner";
      expect(C_CRLF & "NICE" & C_CRLF & C_CRLF);

      report "tb_nicemon: load " & G_HELLO_FILE;
      load(G_HELLO_FILE, first_v);
      command("R 00000000", first_v);
      command("R FFFFFFF0", "00000001");
      assert running = '0'
         report "tb_nicemon: the core runs while it is held"
         severity failure;

      report "tb_nicemon: run";
      command("W FFFFFFF0 00000000", "OK");
      expect("Hello, NICE!" & C_LF);
      command("R FFFFFFF0", "00000002");

      report "tb_nicemon: load " & G_ECHO_FILE;
      command("W FFFFFFF0 00000001", "OK");
      load(G_ECHO_FILE, first_v);
      command("W FFFFFFF0 00000000", "OK");
      assert running = '1'
         report "tb_nicemon: the core does not run"
         severity failure;
      send("ab");
      expect("ab");
      -- Bytes with bit 7 set
      for i in high_v'range loop
         high_v(i) := character'val(127 + i);
      end loop;
      send(high_v);
      expect(high_v);
      -- A byte with a bad stop bit is dropped, and the bytes right after it
      -- arrive.
      send_byte('x', '0');
      wait for C_BIT_TIME;
      send("cd.");
      expect("cd.");
      command("R FFFFFFF0", "00000002");

      report "tb_nicemon: load " & G_FIFO_FILE;
      command("W FFFFFFF0 00000001", "OK");
      load(G_FIFO_FILE, first_v);
      command("W FFFFFFF0 00000000", "OK");
      send("0123456789abcdefX");
      expect("0123456789abcdef");
      send(".");
      expect(".");
      command("R FFFFFFF0", "00000002");

      report "tb_nicemon: the math unit from the CLI";
      command("W FFFFFF20 000003E8", "OK");  -- A = 1000
      command("W FFFFFF21 00000007", "OK");  -- B = 7
      command("R FFFFFF28", "0000008E");     -- A / B = 142
      command("R FFFFFF24", "00001B58");     -- A * B = 7000

      report "tb_nicemon: load " & G_DEVICES_FILE;
      command("W FFFFFFF0 00000001", "OK");
      load(G_DEVICES_FILE, first_v);
      command("W FFFFFFF0 00000000", "OK");
      -- The program takes far less time than one command.
      command("R FFFFFFF0", "00000002");
      command("R 00000100", "0000008E");     -- 1000 / 7 = 142
      command("R 00000101", "00000006");     -- 1000 % 7 = 6
      command("R 00000102", "FFFFFF72");     -- -1000 / 7 = -142
      command("R 00000103", "FFFFE4A8");     -- -1000 * 7 = -7000
      command("R 00000104", "00000001");     -- instructions between two reads

      report "tb_nicemon: load " & G_EMU_FILE;
      command("W FFFFFFF0 00000001", "OK");
      load(G_EMU_FILE, first_v);
      command("W FFFFFFF0 00000000", "OK");
      command("R FFFFFFF0", "00000002");
      command("R FFFF0000", "00000041");     -- the screen
      command("R FFFF07CF", "00000042");
      command("R 00000000", first_v);        -- not overwritten by the screen
      command("R 00000110", "00001234");     -- memory at 0xFFFFFF02
      command("R FFFFFF02", "00001234");
      command("R 00000111", "00000002");     -- the read counter
      command("R FFFFFF01", "00000003");     -- the CLI's read does not count
      command("R FFFFFF01", "00000003");
      command("R FFFFFFE0", "00000000");     -- R0
      command("R FFFFFFE5", "0000CAFE");     -- R5
      command("R FFFFFFEE", "01000000");     -- R14, the status register
      command("R FFFFFFEF", "0000001B");     -- R15, after the HALT

      report "tb_nicemon: PASS";
      stop(0);
   end process p_main;

end architecture simulation;
