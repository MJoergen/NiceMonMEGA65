-- Tests the NiceMon system (src/nicemon.vhd) through its UART, as the host
-- tool does: it loads programs through the debug link (PROTOCOL.md), runs
-- them on the core, and checks what comes back.
--
-- THEORY OF OPERATION
-- p_main sends bytes to the UART with send(), and checks the UART output
-- with expect(). p_uart_rx decodes the UART output into rx_str. command()
-- turns a line like "R FFFFFFF0" or "W 00000100 12345678" into the request
-- of the link, and checks its answer, so that the steps read as a session.
-- The steps:
--
-- 1. The link's reset notice, and the ROM, which holds G_ROM_FILE: the
--    core boots from it at reset, prints its greeting, and halts, which the
--    stop notice tells. Its stack is in the RAM, at the top of the memory,
--    for a push to the ROM is lost. The ROM is at 0, read only, with the
--    RAM above it; bit 3 of the control register hides it, and shows it
--    again; and the core boots from it again when it is started with the
--    ROM shown. From then on the ROM is hidden, as the tools hide it, so
--    the RAM is at 0 as in the emulator.
-- 2. Load G_HELLO_FILE with W requests, and read its first word back.
-- 3. The control register: the core is held in reset.
-- 4. Start the core. It prints "Hello, NICE!" and halts, and the stop
--    notice comes after its output: the control register shows the halted
--    flag, the halt reason is HALT, and the instruction counter holds the
--    steps that niceemu prints for the program. Each program after it ends
--    with the stop notice too.
-- 5. Hold the core, load G_ECHO_FILE, and start it. It echoes the bytes it
--    receives until a '.', which checks the UART input of the core: every
--    byte from 0x80 to 0xFF, 0xFF escaped both ways, and a byte with a bad
--    stop bit, which must be dropped without losing the bytes after it.
-- 6. Hold the core, load G_FIFO_FILE, and start it. It waits before it
--    echoes, so the 17 bytes sent meanwhile pile up in the core's input
--    FIFO. The FIFO keeps the first 16 and loses the 17th, so a '.' sent
--    after them is echoed right after the 16th.
-- 7. Use the math unit through the link.
-- 8. Hold the core, load G_DEVICES_FILE, and run it. It uses the math unit,
--    the performance counters, and the timer, whose interrupts it counts,
--    and leaves the results in memory, which the link reads back after the
--    core has halted. The link reads and writes the timer too.
-- 9. Hold the core, load G_EMU_FILE, and run it. It writes the screen,
--    memory in the I/O range, and the read counter, and sets R5. The link
--    reads them back, and the registers, with the values that
--    "niceemu -d" prints for the same program. The math unit was reset
--    when the core started. The link writes and reads the screen's
--    registers, which go out to the display.
-- 10. Clear the memory: what the programs left is gone, and the core is
--    held.
-- 11. Load G_RESERVED_FILE, and run it. It halts on a reserved control
--    word, which the halt reason and the stop notice show, after the steps
--    of niceemu.
-- 12. Load G_EOF_FILE, and run it. It echoes its input until the input ends,
--    which a break on the UART does, and halts with 0x200 in R1. A break
--    while the core is held is ignored.
-- 13. The keyboard input, a stream of bytes as kbd_ascii.vhd sends them:
--    bytes typed while the core is held are dropped, and G_FIFO_FILE again,
--    with more bytes typed than its FIFO holds. None is lost, for the
--    keyboard waits.
-- 14. The requests of the link: R and W of several words, and of none, P,
--    an unknown tag, and a request that stops in the middle, which is
--    dropped after 10 ms.
-- 15. Run control, with G_DEBUG_FILE, a loop: a pause requested while the
--    core is held stops it before its first instruction; steps; a
--    breakpoint, which stops the core again only after it has gone round
--    the loop; watchpoints for a write and a read; the trace of the steps;
--    a pause of the running core, and the info register.
--
-- The core's input FIFO has 16 bytes here, so that step 6 is short, and the
-- RAM, the ROM, the screen, and the trace are small, so that the clearing
-- is.
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
      G_EOF_FILE      : string;
      G_DEBUG_FILE    : string
   );
end entity tb_nicemon;

architecture simulation of tb_nicemon is

   constant C_CLOCK_HZ : natural := 100_000_000;
   constant C_BAUDRATE : natural := 10_000_000;
   constant C_BIT_TIME : time    := (C_CLOCK_HZ / C_BAUDRATE) * 10 ns;
   -- Longer than the slowest answer
   constant C_TIMEOUT : time    := 1 ms;

   -- Longer than the link waits for the next byte of a request
   constant C_LINK_TIMEOUT : time := 11 ms;

   constant C_LF  : character := character'val(10);
   constant C_ESC : character := character'val(255);

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
         G_TRACE_BITS       => 4,
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

      -- Console bytes as the link sends and takes them: 0xFF doubled
      function esc(s : string) return string is
      begin
         for i in s'range loop
            if s(i) = C_ESC then
               return s(s'low to i) & C_ESC & esc(s(i + 1 to s'high));
            end if;
         end loop;
         return s;
      end function esc;

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

      -- The bytes of the UART output so far that have not been expected,
      -- in hex
      impure function got(n : natural) return string is
         variable l : line;
      begin
         for i in pos_v + 1 to minimum(rx_len, pos_v + n) loop
            write(l, to_hstring(to_slv(character'pos(rx_str(i)), 8)) & " ");
         end loop;
         if l = null then
            return "nothing";
         end if;
         return l.all;
      end function got;

      -- The next bytes of the UART output must be s.
      procedure expect(s : string) is
      begin
         if rx_len < pos_v + s'length then
            wait until rx_len >= pos_v + s'length for C_TIMEOUT;
         end if;
         assert rx_len >= pos_v + s'length
            report "tb_nicemon: timeout, waiting for """ & s & """, got " & got(s'length)
            severity failure;
         assert rx_str(pos_v + 1 to pos_v + s'length) = s
            report "tb_nicemon: expected """ & s & """, got " & got(s'length)
            severity failure;
         pos_v := pos_v + s'length;
      end procedure expect;

      -- Nothing more comes for a while.
      procedure expect_nothing is
      begin
         wait for 20 * 10 * C_BIT_TIME;
         assert rx_len = pos_v
            report "tb_nicemon: unexpected output " & got(16)
            severity failure;
      end procedure expect_nothing;

      function chr(n : natural) return character is
      begin
         return character'val(n);
      end function chr;

      -- A word, little-endian, as the link sends and takes it
      function le(w : std_logic_vector(31 downto 0)) return string is
      begin
         return chr(to_integer(w(7 downto 0))) & chr(to_integer(w(15 downto 8))) &
                chr(to_integer(w(23 downto 16))) & chr(to_integer(w(31 downto 24)));
      end function le;

      -- The header of a request: the address and the count
      function hdr(addr : std_logic_vector(31 downto 0); n : natural) return string is
      begin
         return le(addr) & chr(n mod 256) & chr(n / 256);
      end function hdr;

      -- Eight hex digits
      function hex(s : string) return std_logic_vector is
         variable res_v : std_logic_vector(31 downto 0);
         variable d_v   : natural;
      begin
         for i in 0 to 7 loop
            case s(s'low + i) is
               when '0' to '9' => d_v := character'pos(s(s'low + i)) - character'pos('0');
               when 'A' to 'F' => d_v := character'pos(s(s'low + i)) - character'pos('A') + 10;
               when others     => d_v := character'pos(s(s'low + i)) - character'pos('a') + 10;
            end case;
            res_v(31 - 4 * i downto 28 - 4 * i) := to_slv(d_v, 4);
         end loop;
         return res_v;
      end function hex;

      -- "R ADDR" with its answer, the word read, or "W ADDR DATA", with 8
      -- hex digits for each number, as the old command line took them
      procedure command(cmd : string; answer : string := "") is
      begin
         if cmd(cmd'low) = 'R' then
            send(C_ESC & "R" & hdr(hex(cmd(cmd'low + 2 to cmd'low + 9)), 1));
            expect(C_ESC & "r" & le(hex(answer)));
         else
            send(C_ESC & "W" & hdr(hex(cmd(cmd'low + 2 to cmd'low + 9)), 1) &
                 le(hex(cmd(cmd'low + 11 to cmd'low + 18))));
            expect(C_ESC & "k");
         end if;
      end procedure command;

      -- The stop notice, with its reason
      procedure expect_stop(why : natural) is
      begin
         expect(C_ESC & "h" & chr(why));
      end procedure expect_stop;

      -- Writes each word of the .bin file with a W request. Returns the
      -- first word, in hex.
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
                  first   := l.all(10 to 17);
                  first_v := false;
               end if;
               command("W " & l.all);
            end if;
         end loop;
         file_close(f);
      end procedure load;

      -- The first word of the .bin file, in hex
      impure function first_word(name : string) return string is
         file     f : text;
         variable l : line;
      begin
         file_open(f, name, read_mode);
         readline(f, l);
         file_close(f);
         return l.all(10 to 17);
      end function first_word;

      -- The word at addr of the .bin file
      impure function first_word_at(name : string; addr : natural) return std_logic_vector is
         file     f : text;
         variable l : line;
      begin
         file_open(f, name, read_mode);
         for i in 0 to addr loop
            readline(f, l);
         end loop;
         file_close(f);
         return hex(l.all(10 to 17));
      end function first_word_at;

      variable first_v : string(1 to 8);
      variable high_v  : string(1 to 128);

   begin
      rst <= '1';
      wait for 100 ns;
      wait until rising_edge(clk);
      rst <= '0';

      report "tb_nicemon: the reset notice, and the ROM";
      expect(C_ESC & "b" & chr(1));
      expect("Hello from the ROM!" & C_LF);
      expect_stop(16#81#);
      first_v := first_word(G_ROM_FILE);
      command("R FFFFFFF0", "00000002");     -- halted, the ROM shown
      command("R 00000000", first_v);        -- the ROM
      command("W 00000000 12345678");        -- dropped
      command("R 00000000", first_v);
      command("R 00000800", "00000000");     -- the RAM above the ROM
      command("W 00000800 12345678");
      command("R 00000800", "12345678");
      command("W FFFFFFF0 00000009");        -- hold the core, and hide the ROM
      command("R FFFFFFF0", "00000009");
      command("R 00000000", "00000000");     -- the RAM under the ROM
      command("W 00000000 ABCD1234");
      command("R 00000000", "ABCD1234");
      command("W FFFFFFF0 00000001");        -- the ROM shown again
      command("R 00000000", first_v);
      command("W FFFFFFF0 00000000");        -- the core boots from it again
      expect("Hello from the ROM!" & C_LF);
      expect_stop(16#81#);
      command("R FFFFFFF0", "00000002");
      command("W FFFFFFF0 00000009");        -- hidden from here on
      command("R 00000000", "ABCD1234");

      report "tb_nicemon: load " & G_HELLO_FILE;
      load(G_HELLO_FILE, first_v);
      command("R 00000000", first_v);
      command("R FFFFFFF0", "00000009");
      assert running = '0'
         report "tb_nicemon: the core runs while it is held"
         severity failure;

      report "tb_nicemon: run";
      command("W FFFFFFF0 00000008");
      expect("Hello, NICE!" & C_LF);
      expect_stop(16#81#);
      command("R FFFFFFF0", "0000000A");
      command("R FFFFFFF1", "00000001");     -- halted by HALT
      command("R FFFFFF12", "00000038");     -- 56 steps, as niceemu says
      command("R FFFFFF13", "00000000");

      report "tb_nicemon: load " & G_ECHO_FILE;
      command("W FFFFFFF0 00000009");
      load(G_ECHO_FILE, first_v);
      command("W FFFFFFF0 00000008");
      assert running = '1'
         report "tb_nicemon: the core does not run"
         severity failure;
      send("ab");
      expect("ab");
      -- Bytes with bit 7 set, and 0xFF, which is escaped both ways
      for i in high_v'range loop
         high_v(i) := character'val(127 + i);
      end loop;
      send(esc(high_v));
      expect(esc(high_v));
      -- A byte with a bad stop bit is dropped, and the bytes right after it
      -- arrive.
      send_byte('x', '0');
      wait for C_BIT_TIME;
      send("cd.");
      expect("cd.");
      expect_stop(16#81#);
      command("R FFFFFFF0", "0000000A");

      report "tb_nicemon: load " & G_FIFO_FILE;
      command("W FFFFFFF0 00000009");
      load(G_FIFO_FILE, first_v);
      command("W FFFFFFF0 00000008");
      send("0123456789abcdefX");
      expect("0123456789abcdef");
      send(".");
      expect(".");
      expect_stop(16#81#);
      command("R FFFFFFF0", "0000000A");

      report "tb_nicemon: the math unit from the link";
      command("W FFFFFF20 000003E8");        -- A = 1000
      command("W FFFFFF21 00000007");        -- B = 7
      command("R FFFFFF28", "0000008E");     -- A / B = 142
      command("R FFFFFF24", "00001B58");     -- A * B = 7000

      report "tb_nicemon: load " & G_DEVICES_FILE;
      command("W FFFFFFF0 00000009");
      load(G_DEVICES_FILE, first_v);
      command("W FFFFFFF0 00000008");
      expect_stop(16#81#);
      command("R FFFFFFF0", "0000000A");
      command("R 00000100", "0000008E");     -- 1000 / 7 = 142
      command("R 00000101", "00000006");     -- 1000 % 7 = 6
      command("R 00000102", "FFFFFF72");     -- -1000 / 7 = -142
      command("R 00000103", "FFFFE4A8");     -- -1000 * 7 = -7000
      command("R 00000104", "00000001");     -- instructions between two reads
      command("R 00000105", "00000003");     -- interrupts of the timer taken
      command("R FFFFFF40", "00000000");     -- the timer: stopped,
      command("R FFFFFF41", "00000000");
      command("R FFFFFF42", "000000F0");     -- with its vector
      command("W FFFFFF42 00000123");        -- the link writes the timer
      command("R FFFFFF42", "00000023");     -- bits 7..0 only

      report "tb_nicemon: load " & G_EMU_FILE;
      command("W FFFFFFF0 00000009");
      load(G_EMU_FILE, first_v);
      command("W FFFFFFF0 00000008");
      expect_stop(16#81#);
      command("R FFFFFFF0", "0000000A");
      command("R FFFFFF12", "0000000C");     -- 12 steps
      command("R FFFFFF20", "00000000");     -- the math unit's A, reset
      command("R FFFF0000", "00000041");     -- the screen
      command("R FFFF07CF", "00000042");
      command("R 00000000", first_v);        -- not overwritten by the screen
      command("R 00000110", "00001234");     -- memory at 0xFFFFFF02
      command("R FFFFFF02", "00001234");
      command("R 00000111", "00000002");     -- the read counter
      command("R FFFFFF01", "00000003");     -- the link's read does not count
      command("R FFFFFF01", "00000003");
      command("R FFFFFFE0", "00000000");     -- R0
      command("R FFFFFFE5", "0000CAFE");     -- R5
      command("R FFFFFFEE", "01000000");     -- R14, the status register
      command("R FFFFFFEF", "0000001B");     -- R15, after the HALT

      report "tb_nicemon: the screen's registers";
      command("W FFFFFF50 000000E0");        -- the cursor shown, blinking
      command("W FFFFFF51 0000004F");        -- column 79
      command("W FFFFFF52 00000018");        -- row 24
      command("W FFFFFF55 00000050");        -- the display offset, one row
      command("R FFFFFF50", "000000E0");
      command("R FFFFFF51", "0000004F");
      command("R FFFFFF52", "00000018");
      command("R FFFFFF55", "00000050");
      command("W FFFFFF53 00000001");        -- not a register
      command("R FFFFFF53", "00000000");
      command("R FFFFFF5F", "00000000");
      assert scr_cur_x = to_slv(79, 7) and scr_cur_y = to_slv(24, 5) and scr_cur_mode = "011"
         report "tb_nicemon: the cursor's registers do not go out"
         severity failure;
      assert scr_offs = 0
         report "tb_nicemon: the display offset goes out while not enabled"
         severity failure;
      command("W FFFFFF50 00000C50");        -- the offset enabled, a small cursor
      command("R FFFFFF50", "00000C50");
      assert scr_offs = 80 and scr_cur_mode = "101"
         report "tb_nicemon: the display offset does not go out"
         severity failure;
      command("W FFFFFF50 00000000");

      report "tb_nicemon: clear the memory";
      command("W FFFFFFF0 0000000D");
      command("R FFFFFFF0", "00000009");     -- held, not halted
      command("R 00000000", "00000000");
      command("R 00000110", "00000000");
      command("R FFFF0000", "00000000");     -- the screen
      command("R FFFF07CF", "00000000");
      command("R FFFFFF02", "00000000");     -- the top of the memory

      report "tb_nicemon: load " & G_RESERVED_FILE;
      load(G_RESERVED_FILE, first_v);
      command("W FFFFFFF0 00000008");
      expect_stop(16#82#);                   -- a reserved control word
      command("R FFFFFFF1", "00000002");
      command("R FFFFFF12", "00000006");     -- 6 steps
      command("R FFFFFFE1", "00000001");     -- R1
      command("R FFFFFFEF", "00000007");     -- R15

      report "tb_nicemon: load " & G_EOF_FILE;
      command("W FFFFFFF0 0000000D");
      load(G_EOF_FILE, first_v);
      send_break;                            -- the core is held, so ignored
      command("W FFFFFFF0 00000008");
      send("ab");
      expect("ab");
      send_break;
      expect_stop(16#81#);
      command("R FFFFFFE1", "00000200");     -- R1, the end of the input
      command("R FFFFFFF0", "0000000A");

      report "tb_nicemon: the keyboard";
      command("W FFFFFFF0 00000009");
      kbd_send("lost");                      -- dropped while the core is held
      load(G_FIFO_FILE, first_v);
      command("W FFFFFFF0 00000008");
      kbd_send("0123456789abcdefXYZ.");
      expect("0123456789abcdefXYZ.");
      expect_stop(16#81#);
      command("R FFFFFFF0", "0000000A");

      report "tb_nicemon: the requests of the link";
      command("W FFFFFFF0 00000009");
      send(C_ESC & "W" & hdr(X"00000200", 3) & le(X"11223344") & le(X"55667788") & le(X"FFFFFFFF"));
      expect(C_ESC & "k");
      send(C_ESC & "R" & hdr(X"00000200", 3));
      expect(C_ESC & "r" & le(X"11223344") & le(X"55667788") & le(X"FFFFFFFF"));
      send(C_ESC & "R" & hdr(X"00000200", 0));
      expect(C_ESC & "r");
      send(C_ESC & "W" & hdr(X"00000200", 0));
      expect(C_ESC & "k");
      send(C_ESC & "P" & hdr(X"00000201", 2));   -- the same word twice
      expect(C_ESC & "r" & le(X"55667788") & le(X"55667788"));
      send(C_ESC & "Z");                         -- an unknown tag is dropped
      command("R 00000200", "11223344");
      send(C_ESC & "W" & le(X"00000200"));       -- stops in the middle
      wait for C_LINK_TIMEOUT;
      expect_nothing;
      command("R 00000200", "11223344");

      report "tb_nicemon: run control, with " & G_DEBUG_FILE;
      command("W FFFFFFF0 0000000D");
      load(G_DEBUG_FILE, first_v);
      command("W FFFFFFF2 00000001");        -- a pause, while the core is held
      command("R FFFFFFF2", "00008102");     -- waiting, and the last stop a HALT
      command("W FFFFFFF0 00000008");
      expect_stop(16#01#);                   -- before the first instruction
      command("R FFFFFFF0", "00000018");     -- paused
      command("R FFFFFFF2", "00000101");
      command("R FFFFFFEF", "00000000");     -- R15
      assert running = '0'
         report "tb_nicemon: the core runs while it is paused"
         severity failure;
      command("W FFFFFFF3 00000001");        -- one step
      expect_stop(16#02#);
      command("R FFFFFFEF", "00000002");
      command("W FFFFFFF3 00000003");        -- three steps, to the jump
      expect_stop(16#02#);
      command("R FFFFFFEF", "00000008");
      command("R FFFFFFE1", "00000001");     -- R1
      command("R 00000100", "00000001");
      command("R FFFFFFF3", "00000000");     -- no steps left
      command("W FFFFFFF8 00000002");        -- breakpoint 0 at LOOP
      command("W FFFFFFFC 00000001");
      command("W FFFFFFF2 00000002");        -- go on
      expect_stop(16#10#);
      command("R FFFFFFEF", "00000002");
      command("R FFFFFFE1", "00000001");
      command("W FFFFFFF2 00000002");        -- not at once again, but next time
      expect_stop(16#10#);
      command("R FFFFFFE1", "00000002");
      command("W FFFFFFFC 00000000");        -- breakpoint 0 off
      command("W FFFFFFF9 00000100");        -- watchpoint 1 for a write of COUNT
      command("W FFFFFFFD 00000004");
      command("W FFFFFFF2 00000002");
      expect_stop(16#31#);                   -- after the write
      command("R FFFFFFEF", "00000006");
      command("R 00000100", "00000003");
      command("W FFFFFFFD 00000000");
      command("W FFFFFFFA 00000101");        -- watchpoint 2 for a read of WATCH
      command("W FFFFFFFE 00000002");
      command("W FFFFFFF2 00000002");
      expect_stop(16#22#);
      command("R FFFFFFEF", "00000008");
      command("W FFFFFFFE 00000000");
      -- The trace: steps 0 to 11 ran at 0, 2, 4, 6, 8, 2, 4, 6, 8, 2, 4, 6.
      command("R FFFFFFF4", "0000000C");
      command("W FFFFFFF4 0000000A");        -- from step 10
      send(C_ESC & "P" & hdr(X"FFFFFFF5", 6));
      expect(C_ESC & "r" & le(X"00000004") & le(first_word_at(G_DEBUG_FILE, 4)) & le(X"00000008") &
             le(X"00000006") & le(first_word_at(G_DEBUG_FILE, 6)) & le(X"00000000"));
      command("W FFFFFFF4 00000000");        -- the oldest
      send(C_ESC & "P" & hdr(X"FFFFFFF5", 3));
      expect(C_ESC & "r" & le(X"00000000") & le(first_word_at(G_DEBUG_FILE, 0)) & le(X"00000000"));
      -- A pause of the running core
      command("W FFFFFFF2 00000002");
      expect_nothing;
      assert running = '1'
         report "tb_nicemon: the core does not run"
         severity failure;
      command("R FFFFFFF2", "00002200");     -- running, the last stop's reason
      command("W FFFFFFF2 00000001");
      expect_stop(16#01#);
      command("R FFFFFFF2", "00000101");
      command("W FFFFFFF0 00000009");        -- holding ends the pause
      command("R FFFFFFF0", "00000009");
      command("R FFFFFFF6", "000C4401");     -- version 1, 4 breakpoints, 16 steps, 4K words

      report "tb_nicemon: PASS";
      stop(0);
   end process p_main;

end architecture simulation;
