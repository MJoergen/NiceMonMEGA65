-- Tests the NiceMon system (src/nicemon.vhd) through its UART, as a host
-- on the debug link of nice_cpu/doc/DEBUG.md would: it loads programs with
-- W packets, runs them on the core, and checks the console bytes and the
-- packets that come back.
--
-- PASS AND FAIL
-- Each check is an assert or a report with severity failure, which stops
-- GHDL with a nonzero exit status. The test ends with stop(0), so only a
-- run that passes every check exits with 0, and sim/Makefile prints PASS
-- for that and FAIL, with the log, for anything else. The step counts that
-- steps 4, 9, and 11 check are the generics G_HELLO_STEPS, G_EMU_STEPS,
-- and G_RESERVED_STEPS, which sim/Makefile sets from STEPS_HELLO,
-- STEPS_EMU, and STEPS_RESERVED. "make -C sim check-steps" runs the same
-- programs in niceemu and compares its counts with those.
--
-- THEORY OF OPERATION
-- p_main sends packets and console bytes to the UART. p_uart_rx decodes the
-- UART output, and splits it as a host does: the console bytes go to
-- con_str, with ESC ESC as 0xFF, and each packet to pkt_str, from its tag
-- to its checksum and an LF. expect_con() checks the console bytes, and
-- wr(), check(), and expect_pkt() the packets. The checksums come from
-- pkt(), which the examples of DEBUG.md §8, worked out by hand there, check
-- first. A program that halts quickly may send its `h` before the `k` of
-- the write that started it; wr() keeps it for expect_halt(). The steps:
--
-- 1. The link's `b05` after reset, and the ROM, which holds G_ROM_FILE: the
--    core boots from it at reset, prints its greeting, and halts. Its stack
--    is in the RAM, at the top of the memory, for a push to the ROM is lost.
--    The ROM is at 0, read only, with the RAM above it; bit 3 of the
--    control register hides it, and shows it again; and the core boots from
--    it again when it is started with the ROM shown. From then on the ROM
--    is hidden, as the tools hide it, so the RAM is at 0 as in the
--    emulator. The version register reads 5, and the free space 16, the
--    whole FIFO.
-- 2. Load G_HELLO_FILE with W packets, and read its first word back.
-- 3. The control register: the core is held in reset.
-- 4. Start the core. It prints "Hello, NICE!" and halts, and the link sends
--    `h01`: the control register shows the halted flag, the halt reason is
--    HALT, and the instruction counter holds the steps that niceemu prints
--    for the program (G_*_STEPS). The microsecond counter holds the cycle
--    counter's count over the cycles per microsecond, as the two stop in
--    the same cycle, and its high word is 0. The clock is 90 MHz, so the
--    check fails if G_CLOCK_HZ does not reach perf.vhd, whose default is
--    100 MHz.
-- 5. Hold the core, load G_ECHO_FILE, and start it. It echoes the bytes it
--    receives until a '.', which checks the console both ways: every byte
--    from 0x80 to 0xFF, 0xFF as ESC ESC, and a byte with a bad stop bit,
--    which must be dropped without losing the bytes after it. While it
--    runs, the link reads its debug registers, and a read of memory gets
--    `e02`. Then a pause: the link sends `p`, before or after the `k` of
--    its write. While the core is paused, bit 4 of the control register
--    reads 1, the link reads the memory and R15, which points into the
--    program, the cycle counter and the running output stop, and a console
--    byte waits in the FIFO. When the core goes on, it echoes the byte.
-- 6. Hold the core, load G_FIFO_FILE, and start it. It waits before it
--    echoes, so the 17 bytes sent meanwhile pile up in the core's input
--    FIFO. The FIFO keeps the first 16, and the link drops the 17th and
--    sends `o`, so a '.' sent after them is echoed right after the 16th.
-- 7. Use the math unit from the link.
-- 8. Hold the core, load G_DEVICES_FILE, and run it. It uses the math unit,
--    the performance counters, and the timer, whose interrupts it counts,
--    and leaves the results in memory, which the link reads back after the
--    core has halted. The link reads and writes the timer too.
-- 9a. Hold the core, load G_EMU_FILE, and run it. It writes the screen,
--    memory in the I/O range, and the read counter, and sets R5. The link
--    reads them back, and the registers, with the values that
--    "niceemu -d" prints for the same program. The math unit was reset
--    when the core started.
-- 9b. The link's reads of the console and the read counter return 0, and
--    its writes to them are dropped: G_COUNT_FILE, run next, reads the count that G_EMU_FILE left, as a start keeps it.
--    The fetch statistics still run, but stopped at the halt: two reads of
--    FS_CYCLES are equal. The link writes and reads the screen's
--    registers, which go out to the display.
--    It writes and reads the board's registers (LEDs, RGB levels, display
--    segments), which go out, and reads the buttons and switches; the
--    read-only words and those that are not registers take no write.
-- 9c. Then G_COUNTERS_FILE reads through the core's data bus what the link
--    reads elsewhere: the fetch statistics, which the start cleared and the
--    program stops, so FS_CYCLES is small, the FS_HIST words sum to it, and
--    with the multi-cycle core FS_HIST[0] is all of it; the microsecond
--    counter, right after the cycle counter; the LEDs, which it writes; and
--    the buttons and switches. The start kept the screen's and the board's
--    registers.
-- 10. Clear the memory: what the programs left is gone, and the core is
--    held. The clear ends the halt, so bit 1 and the halt reason read 0
--    (link version 5).
-- 11. Load G_RESERVED_FILE, and run it. It halts on a reserved control
--    word, which the halt reason and `h02` show, after the steps of niceemu.
-- 12. Load G_BREAK_FILE, with breakpoint 0 at the address of its label READ,
--    an instruction that reads memory, and 1 at V3, the first of its
--    interrupt routine, and start it. The core stops at READ, the link
--    sends `x00`, bit 4 reads 1, and the stop register holds 0x100. A go on
--    stops at V3 with `x01`. Then, with the breakpoints disabled, a go on
--    runs it to its halt, and the stop register reads 0. A start stops at
--    READ again, and the clear before step 13 ends the stop.
-- 13. Load G_EOF_FILE, and run it. It echoes its input until the line's
--    input ends, which a break on the UART does, and halts with 0x200 in
--    R1. Console bytes sent after the halt are dropped.
-- 14. The keyboard input, a stream of bytes as kbd_m65_ascii.vhd sends them:
--    bytes typed while the core is held are dropped, and G_FIFO_FILE again,
--    with more bytes typed than its FIFO holds. None is lost, for the
--    keyboard waits. Then G_FIFO_FILE once more, with a break on the UART
--    while it runs: the host's bytes after the break are dropped, and the
--    keys still reach the program, which reads on at 0x200 and echoes
--    them (nice_cpu's SYSTEM.md §5).
-- 15. A reset while G_ECHO_FILE runs: the link sends `b05`, the core boots
--    from the ROM again, and the screen's and the board's registers and the
--    breakpoints are cleared.
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
      G_COUNT_FILE     : string;
      G_RESERVED_FILE  : string;
      G_EOF_FILE       : string;
      G_COUNTERS_FILE  : string;
      G_BREAK_FILE     : string;
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

   signal brd_led  : std_logic_vector(15 downto 0);
   signal brd_rgb0 : std_logic_vector(11 downto 0);
   signal brd_rgb1 : std_logic_vector(11 downto 0);
   signal brd_seg  : std_logic_vector(63 downto 0);
   signal brd_btn  : std_logic_vector(4 downto 0)  := "00000";
   signal brd_sw   : std_logic_vector(15 downto 0) := X"0000";

   -- The console bytes, and the packets, each from its tag to its checksum
   -- and an LF
   signal con_str : string(1 to 4096);
   signal con_len : natural := 0;
   signal pkt_str : string(1 to 65536);
   signal pkt_len : natural := 0;

   -- The checksum of DEBUG.md §2, in two hex digits
   function cksum(s : string) return string is
      variable sum_v : natural := 0;
   begin
      for i in s'range loop
         sum_v := (sum_v + character'pos(s(i))) mod 256;
      end loop;
      return to_hstring(to_slv(sum_v, 8));
   end function cksum;

   -- A packet, from its tag to its checksum
   function pkt(tag : character; payload : string) return string is
   begin
      return tag & payload & "#" & cksum(tag & payload);
   end function pkt;

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


   -- Decodes the UART output, 8-N-1, sampling in the middle of each bit,
   -- and splits it into console bytes and packets.
   p_uart_rx : process
      variable byte_v : std_logic_vector(7 downto 0);
      variable c_v    : character;
      -- 0: console bytes, 1: after ESC, 2: in a packet, 3 and 4: the
      -- checksum's digits
      variable st_v  : natural range 0 to 4 := 0;
      variable buf_v : string(1 to 65536);
      variable n_v   : natural              := 0;
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
      c_v := character'val(to_integer(byte_v));

      case st_v is
         when 0 =>
            if c_v = C_ESC then
               st_v := 1;
            else
               con_str(con_len + 1) <= c_v;
               con_len              <= con_len + 1;
            end if;
         when 1 =>
            if c_v = C_ESC then
               con_str(con_len + 1) <= C_ESC;
               con_len              <= con_len + 1;
               st_v                 := 0;
            else
               assert (c_v >= 'a' and c_v <= 'z') or (c_v >= 'A' and c_v <= 'Z')
                  report "tb_nicemon: ESC and a byte that is neither ESC nor a letter"
                  severity failure;
               buf_v(1) := c_v;
               n_v      := 1;
               st_v     := 2;
            end if;
         when others =>
            assert c_v /= C_ESC
               report "tb_nicemon: ESC inside a packet"
               severity failure;
            n_v        := n_v + 1;
            buf_v(n_v) := c_v;
            if st_v = 2 and c_v = '#' then
               st_v := 3;
            elsif st_v = 3 then
               st_v := 4;
            elsif st_v = 4 then
               pkt_str(pkt_len + 1 to pkt_len + n_v + 1) <= buf_v(1 to n_v) & C_LF;
               pkt_len                                   <= pkt_len + n_v + 1;
               st_v                                      := 0;
            end if;
      end case;
   end process p_uart_rx;


   -- The steps of the test, one after another, are long by nature.
   -- vsg_off length_003
   p_main : process
      variable con_pos_v : natural := 0;
      variable pkt_pos_v : natural := 0;
      -- An `h` that came before the answer that wr() waited for
      variable halt_v   : line;
      variable cycles_v : std_logic_vector(31 downto 0);
      variable micros_v : std_logic_vector(31 downto 0);
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

      -- Console bytes, with 0xFF as ESC ESC
      procedure send_con(s : string) is
      begin
         for i in s'range loop
            if s(i) = C_ESC then
               send_byte(C_ESC);
            end if;
            send_byte(s(i));
         end loop;
      end procedure send_con;

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

      -- The next console bytes must be s.
      procedure expect_con(s : string) is
      begin
         if con_len < con_pos_v + s'length then
            wait until con_len >= con_pos_v + s'length for C_TIMEOUT;
         end if;
         assert con_len >= con_pos_v + s'length
            report "tb_nicemon: timeout, waiting for """ & s & """, got """ &
                   con_str(con_pos_v + 1 to con_len) & """"
            severity failure;
         assert con_str(con_pos_v + 1 to con_pos_v + s'length) = s
            report "tb_nicemon: expected """ & s & """, got """ &
                   con_str(con_pos_v + 1 to con_pos_v + s'length) & """"
            severity failure;
         con_pos_v := con_pos_v + s'length;
      end procedure expect_con;

      -- The next packet
      procedure next_pkt(p : out line; what : string) is
         variable end_v : natural;
      begin
         if pkt_len = pkt_pos_v then
            wait until pkt_len > pkt_pos_v for C_TIMEOUT;
         end if;
         assert pkt_len > pkt_pos_v
            report "tb_nicemon: timeout, waiting for " & what
            severity failure;
         end_v := pkt_pos_v + 1;
         while pkt_str(end_v) /= C_LF loop
            end_v := end_v + 1;
         end loop;
         -- Indexed from 1
         p         := new string(1 to end_v - 1 - pkt_pos_v);
         p.all     := pkt_str(pkt_pos_v + 1 to end_v - 1);
         pkt_pos_v := end_v;
      end procedure next_pkt;

      -- The next packet must be s.
      procedure expect_pkt(s : string) is
         variable p_v : line;
      begin
         next_pkt(p_v, s);
         assert p_v.all = s
            report "tb_nicemon: expected the packet " & s & ", got " & p_v.all
            severity failure;
         deallocate(p_v);
      end procedure expect_pkt;

      -- The answer to a request, which must be s. An `h` before it is kept.
      procedure expect_answer(s : string) is
         variable p_v : line;
      begin
         loop
            next_pkt(p_v, s);
            exit when p_v.all(1) /= 'h';
            assert halt_v = null
               report "tb_nicemon: two halt notices, " & halt_v.all & " and " & p_v.all
               severity failure;
            halt_v := p_v;
         end loop;
         assert p_v.all = s
            report "tb_nicemon: expected the answer " & s & ", got " & p_v.all
            severity failure;
         deallocate(p_v);
      end procedure expect_answer;

      -- Writes the control register, and checks the answer and the notice
      -- of the stop that follows, `p` or `x`, which come in either order.
      procedure wr_stop(data : string; notice : string) is
         variable a_v : line;
         variable b_v : line;
      begin
         send(C_ESC & pkt('W', "FFFFFFF00001" & data));
         next_pkt(a_v, "the answer to the write");
         next_pkt(b_v, "the notice " & notice);
         assert (a_v.all = pkt('k', "FFFFFFF00001") and b_v.all = notice) or
                (b_v.all = pkt('k', "FFFFFFF00001") and a_v.all = notice)
            report "tb_nicemon: expected the k and " & notice & ", got " &
                   a_v.all & " and " & b_v.all
            severity failure;
         deallocate(a_v);
         deallocate(b_v);
      end procedure wr_stop;

      -- Writes the control register with a pause, and checks the answer and
      -- the `p` notice.
      procedure wr_pause(data : string) is
      begin
         wr_stop(data, "p#70");
      end procedure wr_pause;

      -- The halt notice, with its reason in two hex digits
      procedure expect_halt(reason : string) is
      begin
         if halt_v = null then
            expect_pkt(pkt('h', reason));
         else
            assert halt_v.all = pkt('h', reason)
               report "tb_nicemon: expected the halt notice " & pkt('h', reason) &
                      ", got " & halt_v.all
               severity failure;
            deallocate(halt_v);
         end if;
      end procedure expect_halt;

      -- Writes one word, and checks the answer.
      procedure wr(addr : string; data : string) is
      begin
         send(C_ESC & pkt('W', addr & "0001" & data));
         expect_answer(pkt('k', addr & "0001"));
      end procedure wr;

      -- Reads one word.
      procedure read_word(addr : string; word : out std_logic_vector(31 downto 0)) is
         variable p_v : line;
         variable l_v : line;
      begin
         send(C_ESC & pkt('R', addr & "0001"));
         loop
            next_pkt(p_v, "the answer to R " & addr);
            exit when p_v.all(1) /= 'h';
            halt_v := p_v;
         end loop;
         assert p_v'length = 24 and p_v.all(1 to 13) = "r" & addr & "0001"
            report "tb_nicemon: expected the answer to R " & addr & ", got " & p_v.all
            severity failure;
         assert p_v.all = pkt('r', p_v.all(2 to 21))
            report "tb_nicemon: a bad checksum in " & p_v.all
            severity failure;
         l_v := new string'(p_v.all(14 to 21));
         hread(l_v, word);
         deallocate(l_v);
         deallocate(p_v);
      end procedure read_word;

      -- Reads one word, which must be data.
      procedure check(addr : string; data : string) is
         variable word_v : std_logic_vector(31 downto 0);
      begin
         read_word(addr, word_v);
         assert to_hstring(word_v) = data
            report "tb_nicemon: R " & addr & " gives " & to_hstring(word_v) & ", not " & data
            severity failure;
      end procedure check;

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

      -- Writes each word of the .bin file with a W packet. Returns the
      -- first word, as an r answer has it.
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
               wr(upper(l.all(1 to 8)), upper(l.all(10 to 17)));
            end if;
         end loop;
         file_close(f);
         assert not first_v
            report "tb_nicemon: " & name & " has no words"
            severity failure;
      end procedure load;

      -- A step count, as an r answer has it
      function steps(n : natural) return string is
      begin
         return to_hstring(to_stdlogicvector(n, 32));
      end function steps;

      -- The first word of the .bin file, as an r answer has it
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

      -- The examples of DEBUG.md §8, whose checksums are worked out by hand
      assert pkt('W', "0000010000021122334455667788") = "W0000010000021122334455667788#E2" and
             pkt('k', "000001000002") = "k000001000002#AE" and
             pkt('R', "000001000001") = "R000001000001#94" and
             pkt('r', "00000100000111223344") = "r00000100000111223344#48" and
             pkt('b', "05") = "b05#C7" and pkt('h', "01") = "h01#C9" and
             pkt('e', "5202") = "e5202#2E" and
             pkt('W', "FFFFFFF0000100000009") = "WFFFFFFF0000100000009#BB" and
             pkt('k', "FFFFFFF00001") = "kFFFFFFF00001#46"
         report "tb_nicemon: pkt() does not give the packets of DEBUG.md §8"
         severity failure;

      report "tb_nicemon: b05, and the ROM";
      expect_pkt("b05#C7");
      expect_con("Hello from the ROM!" & C_LF);
      expect_halt("01");
      first_v := first_word(G_ROM_FILE);
      check("FFFFFFF0", "00000002");         -- halted, the ROM shown
      check("FFFFFFF2", "00000005");         -- the version
      check("FFFFFFF3", "00000010");         -- the free space: 16 bytes
      check("00000000", first_v);            -- the ROM
      wr("00000000", "12345678");            -- dropped
      check("00000000", first_v);
      check("00000800", "00000000");         -- the RAM above the ROM
      wr("00000800", "12345678");
      check("00000800", "12345678");
      wr("FFFFFFF0", "00000009");            -- hold the core, and hide the ROM
      check("FFFFFFF0", "0000000B");         -- held, and still halted until a start
      check("00000000", "00000000");         -- the RAM under the ROM
      wr("00000000", "ABCD1234");
      check("00000000", "ABCD1234");
      wr("FFFFFFF0", "00000001");            -- the ROM shown again
      check("00000000", first_v);
      wr("FFFFFFF0", "00000000");            -- the core boots from it again
      expect_con("Hello from the ROM!" & C_LF);
      expect_halt("01");
      check("FFFFFFF0", "00000002");
      wr("FFFFFFF0", "00000009");            -- hidden from here on
      check("00000000", "ABCD1234");

      report "tb_nicemon: load " & G_HELLO_FILE;
      load(G_HELLO_FILE, first_v);
      check("00000000", first_v);
      check("FFFFFFF0", "0000000B");
      assert running = '0'
         report "tb_nicemon: the core runs while it is held"
         severity failure;

      report "tb_nicemon: run";
      wr("FFFFFFF0", "00000008");
      expect_con("Hello, NICE!" & C_LF);
      expect_halt("01");
      check("FFFFFFF0", "0000000A");
      check("FFFFFFF1", "00000001");         -- halted by HALT
      check("FFFFFF42", steps(G_HELLO_STEPS));
      check("FFFFFF43", "00000000");
      -- The microsecond counter stopped with the cycle counter, so it holds
      -- the cycles over the cycles per microsecond
      read_word("FFFFFF40", cycles_v);
      read_word("FFFFFF44", micros_v);
      check("FFFFFF45", "00000000");         -- the microseconds' high word
      report "tb_nicemon: " & to_hstring(micros_v) & " microseconds after " &
             to_hstring(cycles_v) & " cycles";
      assert to_integer(micros_v) = to_integer(cycles_v) / (C_CLOCK_HZ / 1_000_000)
         report "tb_nicemon: the microsecond counter does not match the cycle counter at " &
                natural'image(C_CLOCK_HZ) & " Hz"
         severity failure;

      report "tb_nicemon: load " & G_ECHO_FILE;
      wr("FFFFFFF0", "00000009");
      load(G_ECHO_FILE, first_v);
      wr("FFFFFFF0", "00000008");
      assert running = '1'
         report "tb_nicemon: the core does not run"
         severity failure;
      send_con("ab");
      expect_con("ab");
      -- While the program runs, the link reaches its debug registers only.
      check("FFFFFFF0", "00000008");
      check("FFFFFFF3", "00000010");
      send(C_ESC & pkt('R', "000001000001"));
      expect_answer("e5202#2E");
      send(C_ESC & pkt('W', "00000100000100000000"));
      expect_answer(pkt('e', "5702"));
      -- A pause, which gives the link the memory and R0-R15
      wr_pause("00000018");
      check("FFFFFFF0", "00000018");
      assert running = '0'
         report "tb_nicemon: the core runs while it is paused"
         severity failure;
      check("00000000", first_v);
      read_word("FFFFFFEF", cycles_v);
      assert cycles_v < X"00000020"
         report "tb_nicemon: R15 is " & to_hstring(cycles_v) & " while paused"
         severity failure;
      read_word("FFFFFF40", cycles_v);
      check("FFFFFF40", to_hstring(cycles_v));
      send_con("y");
      wait for 40 * C_BIT_TIME;
      assert con_len = con_pos_v
         report "tb_nicemon: the core echoed while it was paused"
         severity failure;
      check("FFFFFFF3", "0000000F");
      wr("FFFFFFF0", "00000008");
      expect_con("y");
      check("FFFFFFF0", "00000008");
      -- Bytes with bit 7 set, and 0xFF as ESC ESC both ways
      for i in high_v'range loop
         high_v(i) := character'val(127 + i);
      end loop;
      send_con(high_v);
      expect_con(high_v);
      -- A byte with a bad stop bit is dropped, and the bytes right after it
      -- arrive.
      send_byte('x', '0');
      wait for C_BIT_TIME;
      send_con("cd.");
      expect_con("cd.");
      expect_halt("01");
      check("FFFFFFF0", "0000000A");

      report "tb_nicemon: load " & G_FIFO_FILE;
      wr("FFFFFFF0", "00000009");
      load(G_FIFO_FILE, first_v);
      wr("FFFFFFF0", "00000008");
      send_con("0123456789abcdefX");
      expect_pkt("o#6F");
      expect_con("0123456789abcdef");
      send_con(".");
      expect_con(".");
      expect_halt("01");
      check("FFFFFFF0", "0000000A");

      report "tb_nicemon: the math unit from the link";
      wr("FFFFFF20", "000003E8");            -- A = 1000
      wr("FFFFFF21", "00000007");            -- B = 7
      check("FFFFFF28", "0000008E");         -- A / B = 142
      check("FFFFFF24", "00001B58");         -- A * B = 7000

      report "tb_nicemon: load " & G_DEVICES_FILE;
      wr("FFFFFFF0", "00000009");
      load(G_DEVICES_FILE, first_v);
      wr("FFFFFFF0", "00000008");
      expect_halt("01");
      check("FFFFFFF0", "0000000A");
      check("00000100", "0000008E");         -- 1000 / 7 = 142
      check("00000101", "00000006");         -- 1000 % 7 = 6
      check("00000102", "FFFFFF72");         -- -1000 / 7 = -142
      check("00000103", "FFFFE4A8");         -- -1000 * 7 = -7000
      check("00000104", "00000001");         -- instructions between two reads
      check("00000105", "00000003");         -- interrupts of the timer taken
      check("FFFFFF10", "00000000");         -- the timer: stopped,
      check("FFFFFF11", "00000000");
      check("FFFFFF12", "000000F0");         -- with its vector
      wr("FFFFFF12", "00000123");            -- the link writes the timer
      check("FFFFFF12", "00000023");         -- bits 7..0 only

      report "tb_nicemon: load " & G_EMU_FILE;
      wr("FFFFFFF0", "00000009");
      load(G_EMU_FILE, first_v);
      wr("FFFFFFF0", "00000008");
      expect_halt("01");
      check("FFFFFFF0", "0000000A");
      check("FFFFFF42", steps(G_EMU_STEPS));
      check("FFFFFF20", "00000000");         -- the math unit's A, reset
      check("FFFF0000", "00000041");         -- the screen
      check("FFFF07CF", "00000042");
      check("00000000", first_v);            -- not overwritten by the screen
      check("00000110", "00001234");         -- memory at 0xFFFFFF02
      check("FFFFFF02", "00001234");
      check("00000111", "00000002");         -- the read counter, as the program read it
      check("FFFFFFE0", "00000000");         -- R0
      check("FFFFFFE5", "0000CAFE");         -- R5
      check("FFFFFFEE", "01000000");         -- R14, the status register
      check("FFFFFFEF", "0000001B");         -- R15, after the HALT
      -- The link's reads of the console and the read counter return 0, and
      -- its writes to them are dropped (DEBUG.md §3).
      check("FFFFFF00", "00000000");
      check("FFFFFF01", "00000000");
      wr("FFFFFF00", "00000041");
      wr("FFFFFF01", "00000055");

      report "tb_nicemon: load " & G_COUNT_FILE;
      wr("FFFFFFF0", "00000009");
      load(G_COUNT_FILE, first_v);
      wr("FFFFFFF0", "00000008");
      expect_halt("01");
      check("00000100", "00000003");         -- the count that emu.nasm left
      expect_con("");
      assert con_len = con_pos_v
         report "tb_nicemon: the link's write to the console reached the UART"
         severity failure;

      report "tb_nicemon: the screen's registers";
      check("FFFFFF50", "00000001");         -- the fetch statistics run
      read_word("FFFFFF51", fs_v);           -- but not after the halt
      wait for 1 us;
      check("FFFFFF51", to_hstring(fs_v));
      wr("FFFFFF50", "00000000");            -- stop them
      check("FFFFFF50", "00000000");
      wr("FFFFFF50", "00000003");            -- run, and clear
      check("FFFFFF50", "00000001");
      wr("FFFFFF80", "000000E0");            -- the cursor shown, blinking
      wr("FFFFFF81", "0000004F");            -- column 79
      wr("FFFFFF82", "00000018");            -- row 24
      wr("FFFFFF85", "00000050");            -- the display offset, one row
      check("FFFFFF80", "000000E0");
      check("FFFFFF81", "0000004F");
      check("FFFFFF82", "00000018");
      check("FFFFFF85", "00000050");
      wr("FFFFFF83", "00000001");            -- not a register
      check("FFFFFF83", "00000000");
      check("FFFFFF8F", "00000000");
      assert scr_cur_x = to_slv(79, 7) and scr_cur_y = to_slv(24, 5) and scr_cur_mode = "011"
         report "tb_nicemon: the cursor's registers do not go out"
         severity failure;
      assert scr_offs = 0
         report "tb_nicemon: the display offset goes out while not enabled"
         severity failure;
      wr("FFFFFF80", "00000C50");            -- the offset enabled, a small cursor
      check("FFFFFF80", "00000C50");
      assert scr_offs = 80 and scr_cur_mode = "101"
         report "tb_nicemon: the display offset does not go out"
         severity failure;
      wr("FFFFFF80", "00000000");

      report "tb_nicemon: the board's devices";
      check("FFFFFF90", "00000000");         -- all clear after reset
      wr("FFFFFF90", "0000A5C3");
      wr("FFFFFF91", "00000123");
      wr("FFFFFF92", "00000FED");
      wr("FFFFFF93", "76543210");
      wr("FFFFFF94", "FEDCBA98");
      check("FFFFFF90", "0000A5C3");
      check("FFFFFF91", "00000123");
      check("FFFFFF92", "00000FED");
      check("FFFFFF93", "76543210");
      check("FFFFFF94", "FEDCBA98");
      assert brd_led = X"A5C3" and brd_rgb0 = X"123" and brd_rgb1 = X"FED" and
             brd_seg = X"FEDCBA9876543210"
         report "tb_nicemon: the board's registers do not go out"
         severity failure;
      wr("FFFFFF91", "0000FFFF");            -- bits above the levels are dropped
      check("FFFFFF91", "00000FFF");
      brd_btn <= "10110";
      brd_sw  <= X"8001";
      wait for 100 ns;
      check("FFFFFF95", "00000016");
      check("FFFFFF96", "00008001");
      wr("FFFFFF95", "0000001F");            -- read only
      wr("FFFFFF96", "0000FFFF");
      check("FFFFFF95", "00000016");
      check("FFFFFF96", "00008001");
      wr("FFFFFF97", "00000007");            -- not registers
      check("FFFFFF97", "00000000");
      wr("FFFFFF9F", "00000001");
      check("FFFFFF9F", "00000000");
      check("FFFFFF90", "0000A5C3");         -- the other words took no write
      brd_btn <= "00000";
      brd_sw  <= X"0000";
      wait for 100 ns;

      report "tb_nicemon: load " & G_COUNTERS_FILE;
      wr("FFFFFFF0", "00000009");
      load(G_COUNTERS_FILE, first_v);
      wr("FFFFFF81", "00000021");            -- the cursor's column
      brd_btn <= "01001";
      brd_sw  <= X"1234";
      wait for 100 ns;
      wr("FFFFFFF0", "00000008");
      expect_halt("01");
      check("FFFFFFF0", "0000000A");
      -- The start cleared the fetch statistics, which counted since the
      -- link cleared them, and the program stopped them
      read_word("00000100", fs_v);
      report "tb_nicemon: " & to_hstring(fs_v) & " cycles of fetch statistics";
      assert fs_v /= 0 and fs_v < 64
         report "tb_nicemon: the start does not clear the fetch statistics, or they do not count"
         severity failure;
      -- The FS_HIST words sum to FS_CYCLES, which stays stopped
      check("00000102", to_hstring(fs_v));
      check("FFFFFF51", to_hstring(fs_v));
      -- The multi-cycle core has no word in the buffer in any cycle
      if G_NICE = "multi" then
         check("00000101", to_hstring(fs_v));
      end if;
      check("00000103", "00000000");         -- FS_CTRL, stopped
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
      check("00000106", "00000000");         -- TIME_HI
      check("00000107", "00005A5A");         -- the LEDs, written by the core
      assert brd_led = X"5A5A"
         report "tb_nicemon: the core's write to the LEDs does not go out"
         severity failure;
      check("00000108", "00000009");         -- the buttons
      check("00000109", "00001234");         -- the switches
      -- A start does not clear the screen's and the board's registers
      check("FFFFFF81", "00000021");
      check("FFFFFF94", "FEDCBA98");
      brd_btn <= "00000";
      brd_sw  <= X"0000";
      wait for 100 ns;

      report "tb_nicemon: clear the memory";
      wr("FFFFFFF0", "0000000D");
      check("FFFFFFF0", "00000009");         -- held: the clear ends the halt
      check("FFFFFFF1", "00000000");         -- and its reason
      check("00000000", "00000000");
      check("00000110", "00000000");
      check("FFFF0000", "00000000");         -- the screen
      check("FFFF07CF", "00000000");
      check("FFFFFF02", "00000000");         -- the top of the memory
      check("FFFFFF81", "00000000");         -- the screen's registers, as at the start
      check("FFFFFF82", "00000000");
      check("FFFFFF85", "00000000");
      assert scr_cur_x = 0 and scr_cur_y = 0
         report "tb_nicemon: the clear does not reset the cursor"
         severity failure;
      check("FFFFFF93", "76543210");         -- the board's registers are kept

      report "tb_nicemon: load " & G_RESERVED_FILE;
      load(G_RESERVED_FILE, first_v);
      wr("FFFFFFF0", "00000008");
      expect_halt("02");                     -- a reserved control word
      check("FFFFFFF1", "00000002");
      check("FFFFFF42", steps(G_RESERVED_STEPS));
      check("FFFFFFE1", "00000001");         -- R1
      check("FFFFFFEF", "00000007");         -- R15

      report "tb_nicemon: load " & G_BREAK_FILE;
      wr("FFFFFFF0", "0000000D");
      check("FFFFFFF5", "00000004");         -- four breakpoints
      load(G_BREAK_FILE, first_v);
      wr("FFFFFFF8", "0000000C");            -- 0 at READ
      wr("FFFFFFF9", "00000013");            -- 1 at V3
      wr("FFFFFFF4", "00000003");
      check("FFFFFFF4", "00000003");
      wr_stop("00000008", pkt('x', "00"));
      check("FFFFFFF0", "00000018");         -- paused
      check("FFFFFFEF", "0000000C");         -- R15
      check("FFFFFFF6", "00000100");         -- the stop
      wr_stop("00000008", pkt('x', "01"));
      check("FFFFFFEF", "00000013");
      check("FFFFFFF6", "00000101");
      wr("FFFFFFF4", "00000000");
      wr("FFFFFFF0", "00000008");
      expect_halt("01");
      check("FFFFFFF6", "00000000");
      check("FFFFFFE7", "00001234");         -- R7, from the routine
      wr("FFFFFFF4", "00000001");            -- start again, to READ
      wr("FFFFFFF0", "00000009");
      wr_stop("00000008", pkt('x', "00"));
      check("FFFFFFF6", "00000100");

      report "tb_nicemon: load " & G_EOF_FILE;
      wr("FFFFFFF0", "0000000D");
      check("FFFFFFF6", "00000000");         -- the clear ends the stop
      check("FFFFFFF0", "00000009");
      wr("FFFFFFF4", "00000000");
      load(G_EOF_FILE, first_v);
      wr("FFFFFFF0", "00000008");
      send_con("ab");
      expect_con("ab");
      send_break;
      expect_halt("01");
      check("FFFFFFE1", "00000200");         -- R1, the end of the input
      send_con("zz");                        -- dropped, as the core has halted
      check("FFFFFFF0", "0000000A");
      check("FFFFFFF3", "00000010");

      report "tb_nicemon: the keyboard";
      wr("FFFFFFF0", "00000009");
      kbd_send("xyz");                       -- dropped, as the core is held
      load(G_FIFO_FILE, first_v);
      wr("FFFFFFF0", "00000008");
      kbd_send("0123456789abcdefXYZ.");
      expect_con("0123456789abcdefXYZ.");
      expect_halt("01");
      check("FFFFFFF0", "0000000A");

      report "tb_nicemon: the keyboard after a break";
      wr("FFFFFFF0", "00000009");
      load(G_FIFO_FILE, first_v);
      wr("FFFFFFF0", "00000008");
      send_con("ab");
      expect_con("ab");
      send_break;                            -- the line's input ends
      send_con("zz");                        -- dropped by the link
      kbd_send("cd.");                       -- the keys still come
      expect_con("cd.");
      expect_halt("01");
      check("FFFFFFF3", "00000010");         -- the FIFO is empty: no "zz"

      report "tb_nicemon: a reset while the core runs";
      wr("FFFFFF81", "00000021");
      wr("FFFFFF85", "00000050");
      wr("FFFFFF90", "0000A5C3");
      wr("FFFFFFF8", "00001000");            -- a breakpoint the echo never reaches
      wr("FFFFFFF4", "00000001");
      wr("FFFFFFF0", "00000009");
      load(G_ECHO_FILE, first_v);
      wr("FFFFFFF0", "00000008");
      send_con("ab");
      expect_con("ab");
      wait until rising_edge(clk);
      rst <= '1';
      wait for 100 ns;
      wait until rising_edge(clk);
      rst <= '0';
      -- The core boots from the ROM again
      expect_pkt("b05#C7");
      expect_con("Hello from the ROM!" & C_LF);
      expect_halt("01");
      check("FFFFFFF0", "00000002");
      check("FFFFFF81", "00000000");         -- the screen's registers
      check("FFFFFF85", "00000000");
      check("FFFFFF90", "00000000");         -- the board's registers
      check("FFFFFF94", "00000000");
      check("FFFFFFF4", "00000000");         -- the breakpoints
      check("FFFFFFF8", "00000000");
      assert scr_cur_x = 0 and scr_offs = 0 and brd_led = 0 and brd_seg = 0
         report "tb_nicemon: the reset does not clear the screen's and the board's registers"
         severity failure;
      assert pkt_len = pkt_pos_v and con_len = con_pos_v
         report "tb_nicemon: more output than expected: """ & con_str(con_pos_v + 1 to con_len) &
                """ and the packets """ & pkt_str(pkt_pos_v + 1 to pkt_len) & """"
         severity failure;

      report "tb_nicemon: PASS";
      stop(0);
   end process p_main;

   -- vsg_on length_003

end architecture simulation;
