-- Tests the NiceMon system (src/nicemon.vhd) through its UART, as a user at
-- a terminal would: it loads programs with the CLI, runs them on the core,
-- and checks what comes back.
--
-- THEORY OF OPERATION
-- p_main sends lines to the UART with send(), and checks the UART output
-- with expect(). p_uart_rx decodes the UART output into rx_str. The steps:
--
-- 1. The CLI's banner after reset, and the ROM, which holds G_ROM_FILE: the
--    core boots from it at reset, prints its greeting, and halts. Its stack
--    is in the RAM, at the top of the memory, for a push to the ROM is lost.
--    The ROM is at 0, read only, with the RAM above it; bit 3 of the
--    control register hides it, and shows it again; and the core boots from
--    it again when it is started with the ROM shown. From then on the ROM
--    is hidden, as the tools hide it, so the RAM is at 0 as in the
--    emulator.
-- 2. Load G_HELLO_FILE with W commands, and read its first word back.
-- 3. The control register: the core is held in reset.
-- 4. Start the core. It prints "Hello, NICE!" and halts, and the CLI gets
--    the UART back and prints the halt message: the control register shows
--    the halted flag, the halt reason is HALT, and the instruction counter
--    holds the steps that niceemu prints for the program. Each program
--    after it ends with the halt message too.
-- 5. Hold the core, load G_ECHO_FILE, and start it. It echoes the bytes it
--    receives until a '.', which checks the UART input of the core: every
--    byte from 0x80 to 0xFF, and a byte with a bad stop bit, which must be
--    dropped without losing the bytes after it.
-- 6. Hold the core, load G_FIFO_FILE, and start it. It waits before it
--    echoes, so the 17 bytes sent meanwhile pile up in the core's input
--    FIFO. The FIFO keeps the first 16 and loses the 17th, so a '.' sent
--    after them is echoed right after the 16th.
-- 7. Use the math unit from the CLI.
-- 8. Hold the core, load G_DEVICES_FILE, and run it. It uses the math unit,
--    the performance counters, and the timer, whose interrupts it counts,
--    and leaves the results in memory, which the CLI reads back after the
--    core has halted. The CLI reads and writes the timer too.
-- 9. Hold the core, load G_EMU_FILE, and run it. It writes the screen,
--    memory in the I/O range, and the read counter, and sets R5. The CLI
--    reads them back, and the registers, with the values that
--    "niceemu -d" prints for the same program. The math unit was reset
--    when the core started. The CLI writes and reads the screen's
--    registers, which go out to the display.
-- 10. Clear the memory: what the programs left is gone, and the core is
--    held.
-- 11. Load G_RESERVED_FILE, and run it. It halts on a reserved control
--    word, which the halt reason shows, after the steps of niceemu.
-- 12. Load G_EOF_FILE, and run it. It echoes its input until the input ends,
--    which a break on the UART does, and halts with 0x200 in R1. A break
--    while the CLI has the UART is ignored.
-- 13. The keyboard input, a stream of bytes as kbd_ascii.vhd sends them: a
--    command for the CLI, typed on the keyboard, and G_FIFO_FILE again,
--    with more bytes typed than its FIFO holds. None is lost, for the
--    keyboard waits.
--
-- The core's input FIFO has 16 bytes here, so that step 6 is short, and the
-- RAM, the ROM, and the screen are small, so that the clearing is.
--
-- The UART runs at a tenth of the clock rate, so that the test is fast.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.textio.all;
   use std.env.all;

entity tb_nicemon is
   generic (
      G_HELLO_FILE    : string;
      G_ROM_FILE      : string;
      G_ECHO_FILE     : string;
      G_FIFO_FILE     : string;
      G_DEVICES_FILE  : string;
      G_EMU_FILE      : string;
      G_RESERVED_FILE : string;
      G_EOF_FILE      : string
   );
end entity tb_nicemon;

architecture simulation of tb_nicemon is

   constant C_CLOCK_HZ : natural := 100_000_000;
   constant C_BAUDRATE : natural := 10_000_000;
   constant C_BIT_TIME : time    := (C_CLOCK_HZ / C_BAUDRATE) * 10 ns;
   -- Longer than the slowest answer
   constant C_TIMEOUT : time    := 1 ms;

   constant C_CR   : character := character'val(13);
   constant C_LF   : character := character'val(10);
   constant C_CRLF : string    := C_CR & C_LF;
   -- What the CLI prints when the core halts
   constant C_HALT : string    := C_CRLF & "HALT" & C_CRLF;

   signal clk     : std_logic;
   signal rst     : std_logic;
   signal uart_rx : std_logic := '1';
   signal uart_tx : std_logic;
   signal running : std_logic;

   signal kbd_valid : std_logic := '0';
   signal kbd_ready : std_logic;
   signal kbd_data  : std_logic_vector(7 downto 0) := X"00";

   signal scr_ctl_we   : std_logic;
   signal scr_cur_x    : std_logic_vector(6 downto 0);
   signal scr_cur_y    : std_logic_vector(4 downto 0);
   signal scr_cur_mode : std_logic_vector(2 downto 0);
   signal scr_offs     : std_logic_vector(10 downto 0);

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
         G_CLOCK_HZ         => C_CLOCK_HZ,
         G_UART_BAUDRATE    => C_BAUDRATE,
         G_RAM_ADDR_BITS    => 12,
         G_SCR_ADDR_BITS    => 11,
         G_RX_FIFO_BITS     => 4,
         G_ROM_FILE         => G_ROM_FILE,
         G_ROM_ADDR_BITS    => 11,
         G_CPU_RUN_AT_RESET => true
      )
      port map (
         clk_i          => clk,
         rst_i          => rst,
         uart_rxd_i     => uart_rx,
         uart_txd_o     => uart_tx,
         kbd_valid_i    => kbd_valid,
         kbd_ready_o    => kbd_ready,
         kbd_data_i     => kbd_data,
         running_o      => running,
         scr_we_o       => open,
         scr_addr_o     => open,
         scr_data_o     => open,
         scr_ctl_we_o   => scr_ctl_we,
         scr_cur_x_o    => scr_cur_x,
         scr_cur_y_o    => scr_cur_y,
         scr_cur_mode_o => scr_cur_mode,
         scr_offs_o     => scr_offs
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

      -- A break: the line is low for longer than a frame.
      procedure send_break is
      begin
         uart_rx <= '0';
         wait for 12 * C_BIT_TIME;
         uart_rx <= '1';
         wait for C_BIT_TIME;
      end procedure send_break;

      procedure send(s : string) is
      begin
         for i in s'range loop
            send_byte(s(i));
         end loop;
      end procedure send;

      -- Types s on the keyboard: each byte waits until it is taken.
      procedure kbd_send(s : string) is
      begin
         for i in s'range loop
            wait until rising_edge(clk);
            kbd_data  <= to_slv(character'pos(s(i)), 8);
            kbd_valid <= '1';
            loop
               wait until rising_edge(clk);
               exit when kbd_ready = '1';
            end loop;
            kbd_valid <= '0';
         end loop;
      end procedure kbd_send;

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

      -- The first word of the .bin file, as the R command prints it
      impure function first_word(name : string) return string is
         file     f : text;
         variable l : line;
      begin
         file_open(f, name, read_mode);
         readline(f, l);
         file_close(f);
         return upper(l.all(10 to 17));
      end function first_word;

      variable first_v : string(1 to 8);
      variable high_v  : string(1 to 128);

   begin
      rst <= '1';
      wait for 100 ns;
      wait until rising_edge(clk);
      rst <= '0';

      report "tb_nicemon: banner, and the ROM";
      expect(C_CRLF & "NICE" & C_CRLF & C_CRLF);
      expect("Hello from the ROM!" & C_LF & C_HALT);
      first_v := first_word(G_ROM_FILE);
      command("R FFFFFFF0", "00000002");     -- halted, the ROM shown
      command("R 00000000", first_v);        -- the ROM
      command("W 00000000 12345678", "OK");  -- dropped
      command("R 00000000", first_v);
      command("R 00000800", "00000000");     -- the RAM above the ROM
      command("W 00000800 12345678", "OK");
      command("R 00000800", "12345678");
      command("W FFFFFFF0 00000009", "OK");  -- hold the core, and hide the ROM
      command("R FFFFFFF0", "00000009");
      command("R 00000000", "00000000");     -- the RAM under the ROM
      command("W 00000000 ABCD1234", "OK");
      command("R 00000000", "ABCD1234");
      command("W FFFFFFF0 00000001", "OK");  -- the ROM shown again
      command("R 00000000", first_v);
      command("W FFFFFFF0 00000000", "OK");  -- the core boots from it again
      expect("Hello from the ROM!" & C_LF & C_HALT);
      command("R FFFFFFF0", "00000002");
      command("W FFFFFFF0 00000009", "OK");  -- hidden from here on
      command("R 00000000", "ABCD1234");

      report "tb_nicemon: load " & G_HELLO_FILE;
      load(G_HELLO_FILE, first_v);
      command("R 00000000", first_v);
      command("R FFFFFFF0", "00000009");
      assert running = '0'
         report "tb_nicemon: the core runs while it is held"
         severity failure;

      report "tb_nicemon: run";
      command("W FFFFFFF0 00000008", "OK");
      expect("Hello, NICE!" & C_LF & C_HALT);
      command("R FFFFFFF0", "0000000A");
      command("R FFFFFFF1", "00000001");     -- halted by HALT
      command("R FFFFFF42", "00000038");     -- 56 steps, as niceemu says
      command("R FFFFFF43", "00000000");

      report "tb_nicemon: load " & G_ECHO_FILE;
      command("W FFFFFFF0 00000009", "OK");
      load(G_ECHO_FILE, first_v);
      command("W FFFFFFF0 00000008", "OK");
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
      expect("cd." & C_HALT);
      command("R FFFFFFF0", "0000000A");

      report "tb_nicemon: load " & G_FIFO_FILE;
      command("W FFFFFFF0 00000009", "OK");
      load(G_FIFO_FILE, first_v);
      command("W FFFFFFF0 00000008", "OK");
      send("0123456789abcdefX");
      expect("0123456789abcdef");
      send(".");
      expect("." & C_HALT);
      command("R FFFFFFF0", "0000000A");

      report "tb_nicemon: the math unit from the CLI";
      command("W FFFFFF20 000003E8", "OK");  -- A = 1000
      command("W FFFFFF21 00000007", "OK");  -- B = 7
      command("R FFFFFF28", "0000008E");     -- A / B = 142
      command("R FFFFFF24", "00001B58");     -- A * B = 7000

      report "tb_nicemon: load " & G_DEVICES_FILE;
      command("W FFFFFFF0 00000009", "OK");
      load(G_DEVICES_FILE, first_v);
      command("W FFFFFFF0 00000008", "OK");
      expect(C_HALT);
      command("R FFFFFFF0", "0000000A");
      command("R 00000100", "0000008E");     -- 1000 / 7 = 142
      command("R 00000101", "00000006");     -- 1000 % 7 = 6
      command("R 00000102", "FFFFFF72");     -- -1000 / 7 = -142
      command("R 00000103", "FFFFE4A8");     -- -1000 * 7 = -7000
      command("R 00000104", "00000001");     -- instructions between two reads
      command("R 00000105", "00000003");     -- interrupts of the timer taken
      command("R FFFFFF10", "00000000");     -- the timer: stopped,
      command("R FFFFFF11", "00000000");
      command("R FFFFFF12", "000000F0");     -- with its vector
      command("W FFFFFF12 00000123", "OK");  -- the CLI writes the timer
      command("R FFFFFF12", "00000023");     -- bits 7..0 only

      report "tb_nicemon: load " & G_EMU_FILE;
      command("W FFFFFFF0 00000009", "OK");
      load(G_EMU_FILE, first_v);
      command("W FFFFFFF0 00000008", "OK");
      expect(C_HALT);
      command("R FFFFFFF0", "0000000A");
      command("R FFFFFF42", "0000000C");     -- 12 steps
      command("R FFFFFF20", "00000000");     -- the math unit's A, reset
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

      report "tb_nicemon: the screen's registers";
      command("R FFFFFF50", "00000001");     -- the fetch statistics run
      command("W FFFFFF50 00000000", "OK");  -- stop them
      command("R FFFFFF50", "00000000");
      command("W FFFFFF50 00000003", "OK");  -- run, and clear
      command("R FFFFFF50", "00000001");
      command("W FFFFFF80 000000E0", "OK");  -- the cursor shown, blinking
      command("W FFFFFF81 0000004F", "OK");  -- column 79
      command("W FFFFFF82 00000018", "OK");  -- row 24
      command("W FFFFFF85 00000050", "OK");  -- the display offset, one row
      command("R FFFFFF80", "000000E0");
      command("R FFFFFF81", "0000004F");
      command("R FFFFFF82", "00000018");
      command("R FFFFFF85", "00000050");
      command("W FFFFFF83 00000001", "OK");  -- not a register
      command("R FFFFFF83", "00000000");
      command("R FFFFFF8F", "00000000");
      assert scr_cur_x = to_slv(79, 7) and scr_cur_y = to_slv(24, 5) and scr_cur_mode = "011"
         report "tb_nicemon: the cursor's registers do not go out"
         severity failure;
      assert scr_offs = 0
         report "tb_nicemon: the display offset goes out while not enabled"
         severity failure;
      command("W FFFFFF80 00000C50", "OK");  -- the offset enabled, a small cursor
      command("R FFFFFF80", "00000C50");
      assert scr_offs = 80 and scr_cur_mode = "101"
         report "tb_nicemon: the display offset does not go out"
         severity failure;
      command("W FFFFFF80 00000000", "OK");

      report "tb_nicemon: clear the memory";
      command("W FFFFFFF0 0000000D", "OK");
      command("R FFFFFFF0", "00000009");     -- held, not halted
      command("R 00000000", "00000000");
      command("R 00000110", "00000000");
      command("R FFFF0000", "00000000");     -- the screen
      command("R FFFF07CF", "00000000");
      command("R FFFFFF02", "00000000");     -- the top of the memory

      report "tb_nicemon: load " & G_RESERVED_FILE;
      load(G_RESERVED_FILE, first_v);
      command("W FFFFFFF0 00000008", "OK");
      expect(C_HALT);
      command("R FFFFFFF1", "00000002");     -- a reserved control word
      command("R FFFFFF42", "00000006");     -- 6 steps
      command("R FFFFFFE1", "00000001");     -- R1
      command("R FFFFFFEF", "00000007");     -- R15

      report "tb_nicemon: load " & G_EOF_FILE;
      command("W FFFFFFF0 0000000D", "OK");
      load(G_EOF_FILE, first_v);
      command("W FFFFFFF0 00000008", "OK");
      send("ab");
      expect("ab");
      send_break;
      expect(C_HALT);
      command("R FFFFFFE1", "00000200");     -- R1, the end of the input
      send_break;                            -- the CLI's, so ignored
      command("R FFFFFFF0", "0000000A");

      report "tb_nicemon: the keyboard";
      command("W FFFFFFF0 00000009", "OK");
      kbd_send("r fffffff0" & C_CR);
      expect("00000009" & C_CRLF);
      load(G_FIFO_FILE, first_v);
      kbd_send("w fffffff0 00000008" & C_CR);
      expect("OK" & C_CRLF);
      kbd_send("0123456789abcdefXYZ.");
      expect("0123456789abcdefXYZ.");
      expect(C_HALT);
      command("R FFFFFFF0", "0000000A");

      report "tb_nicemon: PASS";
      stop(0);
   end process p_main;

end architecture simulation;
