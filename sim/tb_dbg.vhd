-- Tests the on-board debugger (src/dbg/dbg.vhd), stage 6 of
-- doc/DEBUGGER.md, with the system under it: the strip it draws into the
-- overlay, the toggle, the core's keys over the debug link, the sticky
-- setting, the catch, the page, and the breakpoints.
--
-- PASS AND FAIL
-- Each check is an assert with severity failure, which stops GHDL with a
-- nonzero exit status. The test ends with stop(0).
--
-- THEORY OF OPERATION
-- The system, nicemon.vhd, boots G_ROM_FILE, sim/dbg.nasm, from its ROM at
-- reset: it counts in R1 to 0x800 and halts. The debugger drives the
-- system's link as system.vhd wires it. p_ovl is the overlay of text.vhd:
-- it takes the debugger's writes into a model, and counts those outside
-- its 29 rows, which must be none. p_main types keys, as bytes of the
-- keyboard, and waits for the strip's text. The debugger's G_CLOCK_HZ is
-- small, so that it refreshes every 3000 cycles. The steps:
--
-- 1. After reset the strip is drawn: no registers, NO LINK, and the keys
--    with the MEGA65's toggle key. The debugger is Off, and the link is not
--    its.
-- 2. The toggle enters Focus: the strip is shown, and the keyboard and the
--    link are the debugger's. The core is RUNNING.
-- 3. F5 pauses: PAUSED, with R0-R15 in white, R15 also as the PC, and the
--    word at the PC from the ROM.
-- 4. s steps: the PC moves on, to an instruction of the loop.
-- 5. F3 goes on: RUNNING, with the registers dimmed and no PC.
-- 6. The core halts: HALTED 1, with R1 at 0x800, the PC after the HALT,
--    and Z among the flags.
-- 7. r restarts, F7 holds: HELD. Then g and p do nothing, as they would
--    start the held core.
-- 8. F12 sets the sticky setting, which row 28 shows. r restarts, F5
--    pauses, and s steps, and the toggle comes before the step's `p`: the
--    debugger is in Strip, with the link but not the keyboard, and the
--    stop it caused itself does not take it back to Focus.
-- 9. The catch: g goes on, and the halt that comes in Strip takes the
--    debugger to Focus.
-- 10. F12 clears the setting, and the toggle leaves Focus for Off, and
--    gives the link back.
-- 11. A reset in Focus leaves the debugger Off, and draws the strip again.
--    The core runs the ROM and halts, and the debugger stays Off: Off is
--    not caught from.
-- 12. F11 shows the page: the window at 0, the ROM's words in it, and the
--    cursor on the first.
-- 13. The cursor keys and Home move the cursor; up at the top row, Page
--    Down, and Page Up move the window. A move while the window is read
--    reads it again.
-- 14. a, digits, and RETURN move the window to the screen's memory.
-- 15. A digit and DEL, then digits and RETURN, write the word after the
--    first, which the page reads back. After a digit, a is a digit. ESC clears the field,
--    and a second ESC leaves the page.
-- 16. m shows the page again. r restarts the core, and the words are
--    dimmed, and a write gets e02, until the core halts.
-- 17. b sets breakpoint 0 at the cursor's address, which the header lists
--    and the page colors. r restarts the core, which stops there: BRK 0.
-- 18. b sets breakpoint 1, and b on breakpoint 0 clears it. g goes on to
--    breakpoint 1: BRK 1.
-- 19. b takes the lowest free breakpoint, and with none free says so.
--    After a digit, b is a digit.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.textio.all;
   use std.env.all;

entity tb_dbg is
   generic (
      G_ROM_FILE : string
   );
end entity tb_dbg;

architecture simulation of tb_dbg is

   constant C_CLOCK_HZ : natural := 90_000_000;
   constant C_PERIOD   : time    := 1 sec / C_CLOCK_HZ;
   -- The debugger's clock rate, which sets its refresh, 3000 cycles
   constant C_DBG_HZ  : natural := 60 * 3000;
   constant C_TIMEOUT : time    := 2 ms;

   type t_ovl is array (0 to 4095) of std_logic_vector(31 downto 0);

   type t_rom is array (0 to 255) of std_logic_vector(31 downto 0);

   -- The strip, rows 25 to 28 of the overlay
   constant C_FIRST : natural := 25 * 80;
   constant C_LAST  : natural := 29 * 80 - 1;

   constant C_DASHES : string := "-------- -------- -------- -------- -------- -------- -------- -------- ";
   constant C_KEYS   : string := " F1 step  F3 go  F5 pause  F7 hold  F9 restart  F11 page  F12 keep strip: ";
   constant C_ROW28  : string := C_KEYS & "off" & (1 to 80 - C_KEYS'length - 3 => ' ');
   constant C_STRIP  : string := " The keys are the program's.  MEGA+HELP for the debugger";
   constant C_COLOR  : std_logic_vector(23 downto 0) := X"004FFF";
   constant C_DIM    : std_logic_vector(23 downto 0) := X"004888";
   constant C_CURSOR : std_logic_vector(23 downto 0) := X"FFF004";
   constant C_PKEYS  : string := " CRSR PgUp PgDn Home move  0-f type  RETURN write  a address  b break  ESC back";
   constant C_BREAK  : std_logic_vector(23 downto 0) := X"800FFF";
   constant C_CUR_BR : std_logic_vector(23 downto 0) := X"FFF800";
   constant C_NONE   : string := "________";

   constant C_ESC : character := character'val(27);
   constant C_CR  : character := character'val(13);
   constant C_DEL : character := character'val(127);

   signal clk : std_logic;
   signal rst : std_logic := '1';

   signal toggle    : std_logic := '0';
   signal kbd_valid : std_logic := '0';
   signal kbd_ready : std_logic;
   signal kbd_data  : std_logic_vector(7 downto 0) := X"00";

   signal dbg_on       : std_logic;
   signal dbg_rx_data  : std_logic_vector(7 downto 0);
   signal dbg_rx_valid : std_logic;
   signal dbg_rx_ready : std_logic;
   signal dbg_tx_data  : std_logic_vector(7 downto 0);
   signal dbg_tx_valid : std_logic;
   signal dbg_tx_ready : std_logic;

   signal ovl_we   : std_logic;
   signal ovl_addr : std_logic_vector(11 downto 0);
   signal ovl_data : std_logic_vector(31 downto 0);
   signal strip    : std_logic;
   signal page     : std_logic;
   signal focus    : std_logic;

   signal ovl    : t_ovl   := (others => (others => '0'));
   signal writes : natural := 0;
   signal stray  : natural := 0;

   -- Row r of the overlay, as text
   function row_text(o : t_ovl;
                 r : natural) return string is
      variable res_v : string(1 to 80);
   begin
      for c in 0 to 79 loop
         res_v(c + 1) := character'val(to_integer(o(r * 80 + c)(7 downto 0)));
      end loop;
      return res_v;
   end function row_text;

   function hex_word(s : string) return std_logic_vector is
      variable res_v : std_logic_vector(31 downto 0) := (others => '0');
      variable d_v   : natural;
   begin
      for i in s'range loop
         if s(i) >= 'A' then
            d_v := character'pos(s(i)) - character'pos('A') + 10;
         else
            d_v := character'pos(s(i)) - character'pos('0');
         end if;
         res_v := res_v(27 downto 0) & to_slv(d_v, 4);
      end loop;
      return res_v;
   end function hex_word;

begin

   p_clk : process
   begin
      clk <= '1', '0' after C_PERIOD / 2;
      wait for C_PERIOD;
   end process p_clk;


   i_nicemon : entity work.nicemon
      generic map (
         G_CLOCK_HZ         => C_CLOCK_HZ,
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
         uart_rxd_i     => '1',
         uart_txd_o     => open,
         dbg_on_i       => dbg_on,
         dbg_rx_data_i  => dbg_rx_data,
         dbg_rx_valid_i => dbg_rx_valid,
         dbg_rx_ready_o => dbg_rx_ready,
         dbg_tx_data_o  => dbg_tx_data,
         dbg_tx_valid_o => dbg_tx_valid,
         dbg_tx_ready_i => dbg_tx_ready
      ); -- i_nicemon


   i_dbg : entity work.dbg
      generic map (
         G_CLOCK_HZ => C_DBG_HZ
      )
      port map (
         clk_i       => clk,
         rst_i       => rst,
         toggle_i    => toggle,
         kbd_valid_i => kbd_valid,
         kbd_ready_o => kbd_ready,
         kbd_data_i  => kbd_data,
         on_o        => dbg_on,
         lrx_valid_o => dbg_rx_valid,
         lrx_ready_i => dbg_rx_ready,
         lrx_data_o  => dbg_rx_data,
         ltx_valid_i => dbg_tx_valid,
         ltx_ready_o => dbg_tx_ready,
         ltx_data_i  => dbg_tx_data,
         ovl_we_o    => ovl_we,
         ovl_addr_o  => ovl_addr,
         ovl_data_o  => ovl_data,
         strip_o     => strip,
         page_o      => page,
         focus_o     => focus
      ); -- i_dbg


   p_ovl : process (clk)
   begin
      if rising_edge(clk) then
         if ovl_we = '1' then
            ovl(to_integer(ovl_addr)) <= ovl_data;
            writes                    <= writes + 1;
            if ovl_addr > C_LAST then
               stray <= stray + 1;
            end if;
         end if;
      end if;
   end process p_ovl;


   p_main : process
      variable rom_v  : t_rom := (others => (others => '0'));
      variable pc_v   : std_logic_vector(31 downto 0);
      variable base_v : natural;
      variable n_v    : natural;

      procedure cycles(n : natural) is
      begin
         for i in 1 to n loop
            wait until rising_edge(clk);
         end loop;
      end procedure cycles;

      procedure pulse is
      begin
         toggle <= '1';
         wait until rising_edge(clk);
         toggle <= '0';
         cycles(2);
      end procedure pulse;

      -- The outputs must be strip, page, and focus.
      procedure expect(s, p, f : std_logic; what : string) is
      begin
         assert strip = s and page = p and focus = f
            report "tb_dbg: " & what & ": strip, page, and focus are " &
                   std_logic'image(strip) & std_logic'image(page) & std_logic'image(focus)
            severity failure;
      end procedure expect;

      -- Types the keys of s, a byte a cycle, each taken at once
      procedure key(s : string) is
      begin
         for i in s'range loop
            kbd_valid <= '1';
            kbd_data  <= to_slv(character'pos(s(i)), 8);
            wait until rising_edge(clk);
            assert kbd_ready = '1'
               report "tb_dbg: a byte was not taken"
               severity failure;
         end loop;
         kbd_valid <= '0';
      end procedure key;

      -- Waits until row r has s from column c, and a pass of the strip
      -- has ended
      procedure wait_text(r : natural; c : natural; s : string) is
         variable end_v : time;
      begin
         end_v := now + C_TIMEOUT;
         loop
            wait until rising_edge(clk);
            exit when row_text(ovl, r)(c + 1 to c + s'length) = s and ovl_we = '0';
            assert now < end_v
               report "tb_dbg: row " & to_string(r) & " is '" & row_text(ovl, r) & "', waiting for '" & s & "'"
               severity failure;
         end loop;
         cycles(400);
      end procedure wait_text;

      impure function row(r : natural) return string is
      begin
         return row_text(ovl, r);
      end function row;

      -- The state and the PC of row 27
      procedure expect_row27(state : string; what : string) is
      begin
         wait_text(27, 1, state);
         assert row(27)(2 to 1 + state'length) = state
            report "tb_dbg: " & what & ": row 27 is '" & row(27) & "'"
            severity failure;
      end procedure expect_row27;

      -- The color of the hex digits of R1
      procedure expect_color(c : std_logic_vector(23 downto 0); what : string) is
      begin
         assert ovl(C_FIRST + 17)(31 downto 8) = c
            report "tb_dbg: " & what & ": R1 is in " & to_hstring(ovl(C_FIRST + 17)(31 downto 8))
            severity failure;
      end procedure expect_color;

      -- At a stop: R15 is the PC of row 27, and the word at the PC the ROM's
      procedure expect_stop(what : string) is
      begin
         loop
            exit when row(27)(11) /= '-' and row(27)(21) /= '-' and ovl_we = '0';
            wait until rising_edge(clk);
         end loop;
         cycles(400);
         pc_v := hex_word(row(27)(11 to 18));
         assert row(26)(72 to 79) = row(27)(11 to 18)
            report "tb_dbg: " & what & ": R15 is " & row(26)(72 to 79) & ", the PC " & row(27)(11 to 18)
            severity failure;
         assert hex_word(row(27)(21 to 28)) = rom_v(to_integer(pc_v(7 downto 0)))
            report "tb_dbg: " & what & ": the word at the PC is " & row(27)(21 to 28)
            severity failure;
         expect_color(C_COLOR, what);
      end procedure expect_stop;

      -- Row r of the page shows the ROM's words from address a
      procedure expect_rom_row(r : natural; a : natural; what : string) is
         variable s_v : line;
      begin
         write(s_v, to_hstring(to_slv(a, 32)));
         for i in 0 to 7 loop
            write(s_v, " " & to_hstring(rom_v(a + i)));
         end loop;
         wait_text(r, 0, s_v.all);
         deallocate(s_v);
      end procedure expect_rom_row;

      -- The colors of word w of row r of the page, waited for
      procedure expect_word_color(r, w : natural; c : std_logic_vector(23 downto 0); what : string) is
         variable end_v : time;
      begin
         end_v := now + C_TIMEOUT;
         loop
            exit when ovl(r * 80 + 9 + 9 * w)(31 downto 8) = c and ovl_we = '0';
            exit when now >= end_v;
            wait until rising_edge(clk);
         end loop;
         assert ovl(r * 80 + 9 + 9 * w)(31 downto 8) = c
            report "tb_dbg: " & what & ": word " & to_string(w) & " of row " & to_string(r) & " is in " &
                   to_hstring(ovl(r * 80 + 9 + 9 * w)(31 downto 8))
            severity failure;
      end procedure expect_word_color;

      procedure read_rom is
         file     f      : text;
         variable l      : line;
         variable addr_v : std_logic_vector(31 downto 0);
         variable word_v : std_logic_vector(31 downto 0);
      begin
         file_open(f, G_ROM_FILE, read_mode);
         while not endfile(f) loop
            readline(f, l);
            if l'length > 0 then
               hread(l, addr_v);
               hread(l, word_v);
               rom_v(to_integer(addr_v(7 downto 0))) := word_v;
            end if;
         end loop;
         file_close(f);
      end procedure read_rom;

   begin
      read_rom;
      cycles(4);
      rst <= '0';

      report "tb_dbg: 1. the strip is drawn after reset, and the debugger is Off";
      cycles(400);
      assert writes = C_LAST - C_FIRST + 1 and stray = 0
         report "tb_dbg: " & integer'image(writes) & " writes to the overlay, " &
                integer'image(stray) & " outside the strip"
         severity failure;
      assert row(25) = " R0-7   " & C_DASHES and row(26) = " R8-15  " & C_DASHES
         report "tb_dbg: rows 25 and 26 are '" & row(25) & "' and '" & row(26) & "'"
         severity failure;
      assert row(27)(1 to 43) = " NO LINK  --------  --------  . . . . . . ." and
             row(27)(44 to 80) = (44 to 80 => ' ')
         report "tb_dbg: row 27 is '" & row(27) & "'"
         severity failure;
      assert row(28) = C_ROW28
         report "tb_dbg: row 28 is '" & row(28) & "'"
         severity failure;
      expect_color(C_DIM, "after reset");
      assert ovl(C_FIRST + 1)(31 downto 8) = C_COLOR
         report "tb_dbg: the label of R0 is not white on dark blue"
         severity failure;
      expect('0', '0', '0', "after reset");
      assert dbg_on = '0'
         report "tb_dbg: the debugger has the link while Off"
         severity failure;

      report "tb_dbg: 2. the toggle enters Focus";
      pulse;
      expect('1', '0', '1', "after the toggle");
      assert dbg_on = '1'
         report "tb_dbg: the debugger has not the link in Focus"
         severity failure;
      expect_row27("RUNNING", "in Focus");
      key("z");

      report "tb_dbg: 3. F5 pauses";
      key(C_ESC & "[15~");
      expect_row27("PAUSED ", "after F5");
      expect_stop("after F5");
      assert pc_v >= 2 and pc_v <= 6
         report "tb_dbg: the PC is " & to_hstring(pc_v) & " at a pause"
         severity failure;

      report "tb_dbg: 4. s steps";
      key("s");
      loop
         exit when ovl_we = '0' and row(27)(11) /= '-' and hex_word(row(27)(11 to 18)) /= pc_v;
         wait until rising_edge(clk);
      end loop;
      expect_stop("after s");
      expect_row27("PAUSED ", "after s");
      assert pc_v = 2 or pc_v = 4 or pc_v = 6
         report "tb_dbg: the PC is " & to_hstring(pc_v) & " after a step"
         severity failure;

      report "tb_dbg: 5. F3 goes on";
      key(C_ESC & "OR");
      expect_row27("RUNNING  --------  --------", "after F3");
      expect_color(C_DIM, "after F3");

      report "tb_dbg: 6. the halt";
      expect_row27("HALTED 1", "after the halt");
      expect_stop("after the halt");
      assert pc_v = 9 and row(25)(18 to 25) = "00000800"
         report "tb_dbg: the PC is " & to_hstring(pc_v) & " and R1 " & row(25)(18 to 25) & " at the halt"
         severity failure;
      assert row(27)(31 to 43) = ". . Z . . . ."
         report "tb_dbg: the flags are '" & row(27)(31 to 43) & "' at the halt"
         severity failure;

      report "tb_dbg: 7. r restarts, F7 holds, and g and p do not start";
      key("r");
      expect_row27("RUNNING", "after r");
      key(C_ESC & "[18~");
      expect_row27("HELD     --------", "after F7");
      key("g");
      cycles(10000);
      key("p");
      cycles(10000);
      expect_row27("HELD", "after g and p");

      report "tb_dbg: 8. F12, and a step of the debugger's own in Strip";
      key(C_ESC & "[24~");
      wait_text(28, 0, C_KEYS & "on ");
      key("r");
      expect_row27("RUNNING", "after r");
      key(C_ESC & "[15~");
      expect_row27("PAUSED ", "after F5");
      expect_stop("after F5");
      key("s");
      pulse;
      expect('1', '0', '0', "in Strip");
      assert dbg_on = '1'
         report "tb_dbg: the debugger has not the link in Strip"
         severity failure;
      wait_text(28, 0, C_STRIP);
      cycles(20000);
      expect('1', '0', '0', "after the step in Strip");
      expect_row27("PAUSED ", "after the step in Strip");

      report "tb_dbg: 9. the catch of a halt in Strip";
      pulse;
      expect('1', '0', '1', "back in Focus");
      key("g");
      expect_row27("RUNNING", "after g");
      pulse;
      expect('1', '0', '0', "in Strip again");
      wait until focus = '1' for C_TIMEOUT;
      expect('1', '0', '1', "after the halt in Strip");
      expect_row27("HALTED 1", "after the catch");

      report "tb_dbg: 10. F12 again, and the toggle leaves for Off";
      key(C_ESC & "[24~");
      wait_text(28, 0, C_ROW28);
      pulse;
      expect('0', '0', '0', "after the toggle to Off");
      cycles(2000);
      assert dbg_on = '0'
         report "tb_dbg: the debugger keeps the link after Focus"
         severity failure;

      report "tb_dbg: 11. a reset in Focus, and no catch from Off";
      pulse;
      expect('1', '0', '1', "after the toggle to Focus");
      cycles(100);
      base_v := writes;
      rst    <= '1';
      wait until rising_edge(clk);
      rst <= '0';
      cycles(400);
      expect('0', '0', '0', "after the reset");
      assert writes - base_v >= C_LAST - C_FIRST + 1 and stray = 0 and
             row(27)(1 to 8) = " NO LINK" and row(25) = " R0-7   " & C_DASHES and row(28) = C_ROW28
         report "tb_dbg: the strip is not drawn again after the reset: '" & row(27) & "'"
         severity failure;
      wait for C_TIMEOUT;
      expect('0', '0', '0', "after the halt in Off");
      assert dbg_on = '0'
         report "tb_dbg: the debugger took the link in Off"
         severity failure;

      report "tb_dbg: 12. F11 shows the page";
      pulse;
      expect('1', '0', '1', "in Focus for the page");
      expect_row27("HALTED 1", "before the page");
      key(C_ESC & "[23~");
      cycles(4);
      expect('1', '1', '1', "with the page");
      wait_text(0, 0, " Window 00000000  Cursor 00000000 ");
      expect_rom_row(1, 0, "the first row");
      expect_rom_row(22, 21 * 8, "the last row");
      assert row(23)(1 to 20) = " Word:    " & C_NONE & "  " and row(24)(1 to C_PKEYS'length) = C_PKEYS
         report "tb_dbg: rows 23 and 24 are '" & row(23) & "' and '" & row(24) & "'"
         severity failure;
      expect_word_color(1, 0, C_CURSOR, "the cursor");
      expect_word_color(1, 1, C_COLOR, "after the cursor");

      report "tb_dbg: 13. the cursor keys, Home, Page Down, and Page Up";
      key(C_ESC & "[C");
      key(C_ESC & "[B");
      wait_text(0, 0, " Window 00000000  Cursor 00000009 ");
      expect_word_color(2, 1, C_CURSOR, "after right and down");
      expect_word_color(1, 0, C_COLOR, "after right and down");
      key(C_ESC & "[H");
      wait_text(0, 0, " Window 00000000  Cursor 00000000 ");
      key(C_ESC & "[A");
      wait_text(0, 0, " Window FFFFFFF8  Cursor FFFFFFF8 ");
      expect_rom_row(2, 0, "after up at the top");
      key(C_ESC & "[B");
      wait_text(0, 0, " Window FFFFFFF8  Cursor 00000000 ");
      expect_word_color(2, 0, C_CURSOR, "after down");
      key(C_ESC & "[6~");
      wait_text(0, 0, " Window 000000A8  Cursor 000000B0 ");
      expect_rom_row(2, 16#B0#, "after Page Down");
      -- Page Up, and Page Down again while the window at FFFFFFF8 is read:
      -- that read, of the ROM's words, is not shown
      key(C_ESC & "[5~");
      loop
         wait until rising_edge(clk) and dbg_tx_valid = '1' and dbg_tx_data = X"72";
         n_v := 0;
         loop
            wait until rising_edge(clk) and dbg_tx_valid = '1';
            exit when dbg_tx_data = X"23" or n_v = 200;
            n_v := n_v + 1;
         end loop;
         exit when n_v = 200;
      end loop;
      key(C_ESC & "[6~");
      wait_text(0, 0, " Window 000000A8  Cursor 000000B0 ");
      expect_rom_row(2, 16#B0#, "after a Page Down during a read");
      key(C_ESC & "[5~");
      wait_text(0, 0, " Window FFFFFFF8  Cursor 00000000 ");

      report "tb_dbg: 14. a moves the window";
      key("a");
      wait_text(23, 0, " Address: " & C_NONE);
      key("ffff0010");
      wait_text(23, 0, " Address: FFFF0010");
      key("" & C_CR);
      wait_text(0, 0, " Window FFFF0010  Cursor FFFF0010 ");
      wait_text(1, 0, "FFFF0010 00000000 00000000");
      assert row(23)(1 to 18) = " Word:    " & C_NONE
         report "tb_dbg: the field is '" & row(23) & "' after RETURN"
         severity failure;

      report "tb_dbg: 15. a word's write, DEL, and ESC";
      key("9");
      wait_text(23, 0, " Word:    9_______");
      key("" & C_DEL);
      wait_text(23, 0, " Word:    " & C_NONE);
      key(C_ESC & "[C");
      wait_text(0, 0, " Window FFFF0010  Cursor FFFF0011 ");
      key("12345678" & C_CR);
      wait_text(23, 20, "written   ");
      wait_text(1, 0, "FFFF0010 00000000 12345678 00000000");
      key("1a");
      wait_text(23, 0, " Word:    1A______");
      key("" & C_ESC);
      wait_text(23, 0, " Word:    " & C_NONE);
      expect('1', '1', '1', "after an ESC with digits");
      key("" & C_ESC);
      wait until page = '0' for C_TIMEOUT;
      expect('1', '0', '1', "after the second ESC");

      report "tb_dbg: 16. m, and the page while the core runs";
      key("m");
      wait_text(1, 0, "FFFF0010 00000000 12345678 00000000");
      assert row(23)(21 to 30) = "          "
         report "tb_dbg: the message stays: '" & row(23) & "'"
         severity failure;
      key("r");
      expect_row27("RUNNING", "after r with the page");
      expect_word_color(1, 2, C_DIM, "while the core runs");
      key("1" & C_CR);
      wait_text(23, 20, "e02       ");
      expect_row27("HALTED 1", "after the run with the page");
      wait_text(1, 0, "FFFF0010 00000000 12345678 00000000");
      expect_word_color(1, 2, C_COLOR, "after the halt");
      expect_word_color(1, 1, C_CURSOR, "after the halt");
      key("m");
      cycles(4);
      expect('1', '0', '1', "after m");

      report "tb_dbg: 17. b sets a breakpoint, and the core stops there";
      key("m");
      key("a0" & C_CR);
      wait_text(0, 0, " Window 00000000  Cursor 00000000  Breaks -------- -------- -------- --------");
      key(C_ESC & "[C" & C_ESC & "[C" & "b");
      wait_text(0, 0, " Window 00000000  Cursor 00000002  Breaks 00000002 -------- -------- --------");
      expect_word_color(1, 2, C_CUR_BR, "the cursor on a breakpoint");
      key(C_ESC & "[C");
      wait_text(0, 0, " Window 00000000  Cursor 00000003 ");
      expect_word_color(1, 2, C_BREAK, "a breakpoint");
      expect_word_color(1, 3, C_CURSOR, "after a breakpoint");
      key("r");
      expect_row27("BRK 0    00000002", "at breakpoint 0");
      assert row(25)(18 to 25) = "00000000"
         report "tb_dbg: R1 is " & row(25)(18 to 25) & " at breakpoint 0"
         severity failure;

      report "tb_dbg: 18. b clears a breakpoint, and g goes on to the next";
      key(C_ESC & "[C" & "b");
      wait_text(0, 0, " Window 00000000  Cursor 00000004  Breaks 00000002 00000004 -------- --------");
      key(C_ESC & "[D" & C_ESC & "[D" & "b");
      wait_text(0, 0, " Window 00000000  Cursor 00000002  Breaks -------- 00000004 -------- --------");
      expect_word_color(1, 2, C_CURSOR, "a breakpoint cleared");
      expect_word_color(1, 4, C_BREAK, "breakpoint 1");
      key("g");
      expect_row27("BRK 1    00000004", "at breakpoint 1");

      report "tb_dbg: 19. the lowest free breakpoint, and none free";
      for i in 1 to 4 loop
         key(C_ESC & "[C");
      end loop;
      key("b");
      wait_text(0, 0, " Window 00000000  Cursor 00000006  Breaks 00000006 00000004 -------- --------");
      key(C_ESC & "[C" & "b");
      wait_text(0, 0, " Window 00000000  Cursor 00000007  Breaks 00000006 00000004 00000007 --------");
      key(C_ESC & "[C" & "b");
      wait_text(0, 0, " Window 00000000  Cursor 00000008  Breaks 00000006 00000004 00000007 00000008");
      key(C_ESC & "[C" & "b");
      wait_text(23, 20, "none free ");
      key("1b");
      wait_text(23, 0, " Word:    1B______");
      key("" & C_ESC);
      wait_text(23, 0, " Word:    " & C_NONE);
      assert row(0)(36 to 77) = "Breaks 00000006 00000004 00000007 00000008"
         report "tb_dbg: the header is '" & row(0) & "' after b as a digit"
         severity failure;
      assert stray = 0
         report "tb_dbg: " & to_string(stray) & " writes outside the overlay's rows"
         severity failure;

      report "tb_dbg: PASS";
      stop(0);
   end process p_main;

end architecture simulation;
