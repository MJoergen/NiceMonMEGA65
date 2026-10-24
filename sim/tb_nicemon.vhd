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
--    holds the steps that niceemu prints for the program (G_*_STEPS). The
--    microsecond counter holds the cycle counter's count over the cycles
--    per microsecond, as the two stop in the same cycle, and its high word
--    is 0. The clock is 90 MHz, so the check fails if G_CLOCK_HZ does not
--    reach perf.vhd, whose default is 100 MHz. Each program
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
--    It writes and reads the board's registers (LEDs, RGB levels, display
--    segments), which go out, and reads the buttons and switches; the
--    read-only words and those that are not registers take no write.
--    Then G_COUNTERS_FILE reads through the core's data bus what the CLI
--    reads elsewhere: the fetch statistics, which the start cleared and the
--    program stops, so FS_CYCLES is small, the FS_HIST words sum to it, and
--    with the multi-cycle core FS_HIST[0] is all of it; the microsecond
--    counter, right after the cycle counter; the LEDs, which it writes; and
--    the buttons and switches. The start kept the screen's and the board's
--    registers.
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
-- 14. A reset while G_ECHO_FILE runs: the CLI prints its banner, the core
--    boots from the ROM again, and the screen's and the board's registers
--    are cleared.
--
-- The core's input FIFO has 16 bytes here, so that step 6 is short, and the
-- RAM, the ROM, and the screen are small, so that the clearing is.
--
-- The UART runs at a tenth of the clock rate, so that the test is fast.
-- G_NICE says which core runs, for the check that only the multi-cycle core
-- passes.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.textio.all;
   use std.env.all;

entity tb_nicemon is
   generic (
      G_HELLO_FILE     : string;
      G_ROM_FILE       : string;
      G_ECHO_FILE      : string;
      G_FIFO_FILE      : string;
      G_DEVICES_FILE   : string;
      G_EMU_FILE       : string;
      G_RESERVED_FILE  : string;
      G_EOF_FILE       : string;
      G_COUNTERS_FILE  : string;
      -- The core, pipeline or multi, as NICE selects it
      G_NICE           : string;
      -- The steps that niceemu counts for hello, emu, and reserved
      G_HELLO_STEPS    : natural;
      G_EMU_STEPS      : natural;
      G_RESERVED_STEPS : natural
   );
end entity tb_nicemon;

architecture simulation of tb_nicemon is

   -- The Nexys4DDR's clock, not the default of perf.vhd, so that the
   -- microsecond counter shows that G_CLOCK_HZ reaches it
   constant C_CLOCK_HZ : natural := 90_000_000;
   constant C_PERIOD   : time    := 1 sec / C_CLOCK_HZ;
   constant C_BAUDRATE : natural := 9_000_000;
   constant C_BIT_TIME : time    := (C_CLOCK_HZ / C_BAUDRATE) * C_PERIOD;
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

   signal brd_led  : std_logic_vector(15 downto 0);
   signal brd_rgb0 : std_logic_vector(11 downto 0);
   signal brd_rgb1 : std_logic_vector(11 downto 0);
   signal brd_seg  : std_logic_vector(63 downto 0);
   signal brd_btn  : std_logic_vector(4 downto 0)  := "00000";
   signal brd_sw   : std_logic_vector(15 downto 0) := X"0000";

   signal rx_str : string(1 to 4096);
   signal rx_len : natural := 0;

begin

   p_clk : process
   begin
      clk <= '1', '0' after C_PERIOD / 2;
      wait for C_PERIOD;
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
         G_CPU_RUN_AT_RESET => true,
         G_BOARD_IO         => true
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
         scr_offs_o     => scr_offs,
         brd_led_o      => brd_led,
         brd_rgb0_o     => brd_rgb0,
         brd_rgb1_o     => brd_rgb1,
         brd_seg_o      => brd_seg,
         brd_btn_i      => brd_btn,
         brd_sw_i       => brd_sw
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
      variable pos_v    : natural := 0;
      variable cycles_v : std_logic_vector(31 downto 0);
      variable micros_v : std_logic_vector(31 downto 0);
      variable word_v   : std_logic_vector(31 downto 0);
      variable fs_v     : std_logic_vector(31 downto 0);

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

      -- Sends an R command, and returns the word that the CLI prints.
      procedure read_word(addr : string; word : out std_logic_vector(31 downto 0)) is
         variable l_v : line;
      begin
         send("R " & addr & C_CR);
         if rx_len < pos_v + 8 then
            wait until rx_len >= pos_v + 8 for C_TIMEOUT;
         end if;
         assert rx_len >= pos_v + 8
            report "tb_nicemon: timeout, waiting for the answer to R " & addr
            severity failure;
         l_v := new string'(rx_str(pos_v + 1 to pos_v + 8));
         hread(l_v, word);
         deallocate(l_v);
         pos_v := pos_v + 8;
         expect(C_CRLF);
      end procedure read_word;

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
            if l'length > 0 then
               assert l'length = 17
                  report "tb_nicemon: " & name & " has a line that is not 'address word': '" & l.all & "'"
                  severity failure;
               if first_v then
                  first   := upper(l.all(10 to 17));
                  first_v := false;
               end if;
               command("W " & l.all, "OK");
            end if;
         end loop;
         file_close(f);
         assert not first_v
            report "tb_nicemon: " & name & " has no words"
            severity failure;
      end procedure load;

      -- A step count, as the R command prints it
      function steps(n : natural) return string is
      begin
         return to_hstring(to_stdlogicvector(n, 32));
      end function steps;

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
      command("R FFFFFF42", steps(G_HELLO_STEPS));
      command("R FFFFFF43", "00000000");
      -- The microsecond counter stopped with the cycle counter, so it holds
      -- the cycles over the cycles per microsecond
      read_word("FFFFFF40", cycles_v);
      read_word("FFFFFF44", micros_v);
      command("R FFFFFF45", "00000000");     -- the microseconds' high word
      report "tb_nicemon: " & to_hstring(micros_v) & " microseconds after " &
             to_hstring(cycles_v) & " cycles";
      assert to_integer(micros_v) = to_integer(cycles_v) / (C_CLOCK_HZ / 1_000_000)
         report "tb_nicemon: the microsecond counter does not match the cycle counter at " &
                natural'image(C_CLOCK_HZ) & " Hz"
         severity failure;

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
      command("R FFFFFF42", steps(G_EMU_STEPS));
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

      report "tb_nicemon: the board's devices";
      command("R FFFFFF90", "00000000");     -- all clear after reset
      command("W FFFFFF90 0000A5C3", "OK");
      command("W FFFFFF91 00000123", "OK");
      command("W FFFFFF92 00000FED", "OK");
      command("W FFFFFF93 76543210", "OK");
      command("W FFFFFF94 FEDCBA98", "OK");
      command("R FFFFFF90", "0000A5C3");
      command("R FFFFFF91", "00000123");
      command("R FFFFFF92", "00000FED");
      command("R FFFFFF93", "76543210");
      command("R FFFFFF94", "FEDCBA98");
      assert brd_led = X"A5C3" and brd_rgb0 = X"123" and brd_rgb1 = X"FED" and
             brd_seg = X"FEDCBA9876543210"
         report "tb_nicemon: the board's registers do not go out"
         severity failure;
      command("W FFFFFF91 0000FFFF", "OK");  -- bits above the levels are dropped
      command("R FFFFFF91", "00000FFF");
      brd_btn <= "10110";
      brd_sw  <= X"8001";
      wait for 100 ns;
      command("R FFFFFF95", "00000016");
      command("R FFFFFF96", "00008001");
      command("W FFFFFF95 0000001F", "OK");  -- read only
      command("W FFFFFF96 0000FFFF", "OK");
      command("R FFFFFF95", "00000016");
      command("R FFFFFF96", "00008001");
      command("W FFFFFF97 00000007", "OK");  -- not registers
      command("R FFFFFF97", "00000000");
      command("W FFFFFF9F 00000001", "OK");
      command("R FFFFFF9F", "00000000");
      command("R FFFFFF90", "0000A5C3");     -- the other words took no write
      brd_btn <= "00000";
      brd_sw  <= X"0000";
      wait for 100 ns;

      report "tb_nicemon: load " & G_COUNTERS_FILE;
      command("W FFFFFFF0 00000009", "OK");
      load(G_COUNTERS_FILE, first_v);
      command("W FFFFFF81 00000021", "OK");  -- the cursor's column
      brd_btn <= "01001";
      brd_sw  <= X"1234";
      wait for 100 ns;
      command("W FFFFFFF0 00000008", "OK");
      expect(C_HALT);
      command("R FFFFFFF0", "0000000A");
      -- The start cleared the fetch statistics, which counted since the
      -- CLI cleared them, and the program stopped them
      read_word("00000100", fs_v);
      report "tb_nicemon: " & to_hstring(fs_v) & " cycles of fetch statistics";
      assert fs_v /= 0 and fs_v < 64
         report "tb_nicemon: the start does not clear the fetch statistics, or they do not count"
         severity failure;
      -- The FS_HIST words sum to FS_CYCLES, which stays stopped
      command("R 00000102", to_hstring(fs_v));
      command("R FFFFFF51", to_hstring(fs_v));
      -- The multi-cycle core has no word in the buffer in any cycle
      if G_NICE = "multi" then
         command("R 00000101", to_hstring(fs_v));
      end if;
      command("R 00000103", "00000000");     -- FS_CTRL, stopped
      -- The microseconds, read right after the cycles
      read_word("00000104", cycles_v);
      read_word("00000105", micros_v);
      report "tb_nicemon: " & to_hstring(micros_v) & " microseconds after " &
             to_hstring(cycles_v) & " cycles, read by the core";
      assert micros_v /= 0 and
             (to_integer(micros_v) = to_integer(cycles_v) / (C_CLOCK_HZ / 1_000_000) or
              to_integer(micros_v) = to_integer(cycles_v) / (C_CLOCK_HZ / 1_000_000) + 1)
         report "tb_nicemon: the core reads a microsecond counter that does not match the cycle counter"
         severity failure;
      command("R 00000106", "00000000");     -- TIME_HI
      command("R 00000107", "00005A5A");     -- the LEDs, written by the core
      assert brd_led = X"5A5A"
         report "tb_nicemon: the core's write to the LEDs does not go out"
         severity failure;
      command("R 00000108", "00000009");     -- the buttons
      command("R 00000109", "00001234");     -- the switches
      -- A start does not clear the screen's and the board's registers
      command("R FFFFFF81", "00000021");
      command("R FFFFFF94", "FEDCBA98");
      brd_btn <= "00000";
      brd_sw  <= X"0000";
      wait for 100 ns;

      report "tb_nicemon: clear the memory";
      command("W FFFFFFF0 0000000D", "OK");
      command("R FFFFFFF0", "00000009");     -- held, not halted
      command("R 00000000", "00000000");
      command("R 00000110", "00000000");
      command("R FFFF0000", "00000000");     -- the screen
      command("R FFFF07CF", "00000000");
      command("R FFFFFF02", "00000000");     -- the top of the memory
      command("R FFFFFF81", "00000000");     -- the screen's registers, as at the start
      command("R FFFFFF82", "00000000");
      command("R FFFFFF85", "00000000");
      assert scr_cur_x = 0 and scr_cur_y = 0
         report "tb_nicemon: the clear does not reset the cursor"
         severity failure;
      command("R FFFFFF93", "76543210");     -- the board's registers are kept

      report "tb_nicemon: load " & G_RESERVED_FILE;
      load(G_RESERVED_FILE, first_v);
      command("W FFFFFFF0 00000008", "OK");
      expect(C_HALT);
      command("R FFFFFFF1", "00000002");     -- a reserved control word
      command("R FFFFFF42", steps(G_RESERVED_STEPS));
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

      report "tb_nicemon: a reset while the core runs";
      command("W FFFFFF81 00000021", "OK");
      command("W FFFFFF85 00000050", "OK");
      command("W FFFFFF90 0000A5C3", "OK");
      command("W FFFFFFF0 00000009", "OK");
      load(G_ECHO_FILE, first_v);
      command("W FFFFFFF0 00000008", "OK");
      send("ab");
      expect("ab");
      wait until rising_edge(clk);
      rst <= '1';
      wait for 100 ns;
      wait until rising_edge(clk);
      rst <= '0';
      -- The core boots from the ROM again
      expect(C_CRLF & "NICE" & C_CRLF & C_CRLF);
      expect("Hello from the ROM!" & C_LF & C_HALT);
      command("R FFFFFFF0", "00000002");
      command("R FFFFFF81", "00000000");     -- the screen's registers
      command("R FFFFFF85", "00000000");
      command("R FFFFFF90", "00000000");     -- the board's registers
      command("R FFFFFF94", "00000000");
      assert scr_cur_x = 0 and scr_offs = 0 and brd_led = 0 and brd_seg = 0
         report "tb_nicemon: the reset does not clear the screen's and the board's registers"
         severity failure;

      report "tb_nicemon: PASS";
      stop(0);
   end process p_main;

end architecture simulation;
