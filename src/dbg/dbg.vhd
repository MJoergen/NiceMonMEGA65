-- The on-board debugger (doc/DEBUGGER.md): a strip of 4 text rows under the
-- program's screen, shown and taking the keyboard when the board's toggle
-- key is pressed, which shows the core's state and registers and runs it
-- with single keys.
--
-- THEORY OF OPERATION
-- This is stage 7 of the design note: the live strip, the core keys, the
-- sticky setting, the catch, the page, the breakpoints, and the
-- Nexys4DDR's buttons and display. The debugger has three states. It is Off
-- after reset. The toggle pulse, toggle_i, takes it from Off or Strip to
-- Focus, and from Focus to Off, or to Strip while the sticky setting is
-- on, which F12 toggles in Focus. In Strip and Focus the strip is shown
-- (strip_o) and the debug link is the debugger's (on_o): nicemon.vhd then
-- gives the link's byte streams to the host in hardware here
-- (dbg_host.vhd) instead of the UART or TCP. In Focus the keyboard is the
-- debugger's too (focus_o). on_o stays '1' after Strip or Focus is left
-- until the last request has ended, so that no packet is cut. kbd_ready_o
-- is always '1', as a PS/2 keyboard cannot wait.
--
-- The catch: in Strip, a stop of the core that the debugger did not cause,
-- a `p`, `x`, or `h` notice, takes it to Focus. A stop that a key of the
-- debugger's asked for, a step or a pause, is not caught (own_r), also
-- when Focus was left before it came. Off is not caught from: the link is
-- a host's then, and the host's tools wait for their own notices.
--
-- p_seq drives the link, one request at a time. In Focus, about 60 times a
-- second, and at once after a key, a stop notice (`p`, `x`, or `h`), or
-- the entry into Focus, it reads the debug registers 0xFFFFFFF0-FB in one
-- request: the control register, the halt reason, the stop register, and
-- the enable bits, the number, and the addresses of the breakpoints, of
-- which it uses 4.
-- A key then writes the control register, with bit 3, the ROM, as it
-- reads, and the registers are read again. When the core is paused or
-- has halted, and R0-R15 have not been read since the stop, it reads them,
-- and then the word at R15. While the page is shown and the core is
-- stopped, paused, halted, or held, it reads the window's 176 words in one
-- request, into mem_ram, unless they were read since the stop; a move of
-- the window reads them again, and drops a read that it overtook
-- (mem_kill). A word's write from the page goes as a key's write does,
-- and its answer is the page's message. So does b: it clears an enabled
-- breakpoint at the cursor's address, or writes the address of the lowest
-- free one, then its enable bit. The debug registers take a write while
-- the core runs too. A request that gets no answer
-- shows NO LINK.
--
-- p_kbd turns the keyboard's bytes into the keys of DEBUGGER.md: F1 or s
-- steps a paused core, F3 or g goes on, F5 or p pauses a running core, F7
-- or h holds, and F9 or r restarts: hold, then start. F1 and F3 are xterm's
-- ESC O P and ESC O R, and F5, F7, and F9 ESC [ 15 ~, ESC [ 18 ~, and
-- ESC [ 20 ~. A key that does not fit the core's state does nothing: go
-- on and pause would start a held core. F11 or m shows the page, and on
-- it the cursor keys, Page Up, Page Down, Home, the hex digits, DEL,
-- RETURN, a, b, and ESC are the page's keys, which p_page acts on. An ESC
-- with no byte after it for 1 ms is the ESC key.
--
-- p_page has the window's address, the cursor, a word of the window, and
-- the input field. The cursor keys move the cursor, and past the top or
-- bottom row the window a row; Page Up and Page Down move the window 22
-- rows. The digits shift into the field, RETURN writes it to the cursor's
-- word, and a on an empty field makes it an address, which RETURN moves
-- the window to. b on an empty field is the key of a breakpoint; after a
-- digit, a and b are digits.
--
-- With G_BOARD_IO, the board's buttons are keys in Focus too: BTNL steps,
-- BTNR goes on, BTNU and BTND move the page's cursor, and BTNC leaves
-- Focus as the toggle key does. p_btn synchronizes them and samples them
-- every 5 ms, longer than they bounce, and a press is a sample at 1 after
-- one at 0. p_seg gives the seven-segment display the PC at a stop, a
-- hex digit on each of its eight digits, and dashes otherwise; system.vhd
-- shows it in Focus, and masks the core's buttons then.
--
-- The strip is rows 25 to 28 of the overlay of text.vhd, the words 2000 to
-- 2319, addressed row * 80 + column. C_CELLS says what each word shows: a
-- fixed character, a hex digit of a word that the debugger read, a
-- character of the state's name, a flag of SR (R14), or a character of row
-- 28, the keys in Focus or a note in Strip. p_draw writes the
-- whole strip, one word a cycle, through a pipeline of three stages, after
-- reset and whenever what it shows has changed. R0-R15 are dimmed while
-- they are not the values of the current stop: until nice_cpu V1.2 the
-- link has no registers while the core runs (DEBUG.md §6). While the page
-- is shown (page_o), the pass covers rows 0 to 24 too: the window's and
-- the cursor's address, the 22 rows of the window, the field with its
-- message, and the page's keys, from the templates of row_cells; the
-- cursor's word has its colors swapped, and a word at an enabled
-- breakpoint is on dark red. The header lists the 4 breakpoints.
--
-- RESET
-- Synchronous to clk_i, by rst_i. The debugger is Off, knows nothing of
-- the core, and draws the strip again. The page is off, its window and
-- cursor at 0, and its field empty.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;
   use ieee.numeric_std_unsigned.all;

entity dbg is
   generic (
      G_CLOCK_HZ   : positive := 100_000_000;
      -- The board's key that toggles the debugger, named in row 28
      G_TOGGLE_KEY : string   := "MEGA+HELP";
      -- The board has buttons and a seven-segment display, the Nexys4DDR's
      G_BOARD_IO   : boolean  := false
   );
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;
      -- '1' for a cycle when the toggle key is pressed
      toggle_i    : in  std_logic;

      -- The keyboard's bytes, while focus_o is '1'
      kbd_valid_i : in  std_logic;
      kbd_ready_o : out std_logic;
      kbd_data_i  : in  std_logic_vector(7 downto 0);

      -- The debug link's byte streams (nicemon.vhd), which are the
      -- debugger's while on_o is '1'
      on_o        : out std_logic;
      lrx_valid_o : out std_logic;
      lrx_ready_i : in  std_logic;
      lrx_data_o  : out std_logic_vector(7 downto 0);
      ltx_valid_i : in  std_logic;
      ltx_ready_o : out std_logic;
      ltx_data_i  : in  std_logic_vector(7 downto 0);

      -- The overlay of the text display (text.vhd)
      ovl_we_o    : out std_logic;
      ovl_addr_o  : out std_logic_vector(11 downto 0);
      ovl_data_o  : out std_logic_vector(31 downto 0);
      strip_o     : out std_logic;
      page_o      : out std_logic;

      -- '1' while the keyboard is the debugger's
      focus_o     : out std_logic;

      -- With G_BOARD_IO, the board's buttons, unsynchronized, bit 0 the
      -- center one, then up, left, right, and down; and the display's
      -- segments, which are the board's in Focus (seg7.vhd)
      btn_i       : in  std_logic_vector(4 downto 0) := (others => '0');
      seg_o       : out std_logic_vector(63 downto 0)
   );
end entity dbg;

architecture synthesis of dbg is

   subtype t_byte is std_logic_vector(7 downto 0);

   subtype t_word is std_logic_vector(31 downto 0);

   constant C_COLS       : natural := 80;
   constant C_STRIP_ROW  : natural := 25;
   constant C_STRIP_ROWS : natural := 4;
   constant C_STRIP_LEN  : natural := C_STRIP_ROWS * C_COLS;
   constant C_STRIP_ADDR : natural := C_STRIP_ROW * C_COLS;
   -- The page: rows 0 to 24, the memory in rows 1 to 22, 8 words a row
   constant C_MEM_ROWS  : natural := 22;
   constant C_MEM_LEN   : natural := C_MEM_ROWS * 8;
   constant C_FIELD_ROW : natural := C_MEM_ROWS + 1;
   constant C_ALL_LEN   : natural := (C_STRIP_ROW + C_STRIP_ROWS) * C_COLS;

   -- White on dark blue, and gray on dark blue for stale values: the
   -- background in bits 31..20, the foreground in bits 19..8, as in a
   -- screen word
   constant C_COLOR : std_logic_vector(23 downto 0) := X"004FFF";
   constant C_DIM   : std_logic_vector(23 downto 0) := X"004888";
   -- The page's cursor: the colors swapped; a word at an enabled
   -- breakpoint, white or gray on dark red, and the cursor on one
   constant C_CURSOR    : std_logic_vector(23 downto 0) := X"FFF004";
   constant C_BREAK     : std_logic_vector(23 downto 0) := X"800FFF";
   constant C_BREAK_DIM : std_logic_vector(23 downto 0) := X"800888";
   constant C_CUR_BREAK : std_logic_vector(23 downto 0) := X"FFF800";

   -- The refresh, about 60 times a second, and the host's timeout, the
   -- link's 100 ms (DEBUG.md §5)
   constant C_REFRESH : positive := G_CLOCK_HZ / 60;
   constant C_TIMEOUT : positive := G_CLOCK_HZ / 10;
   -- An ESC with no byte after it for 1 ms is the ESC key, not a sequence
   constant C_ESC_WAIT : positive := G_CLOCK_HZ / 1000;
   -- The buttons are sampled every 5 ms, which outlasts their bounce
   constant C_BTN_WAIT : positive := G_CLOCK_HZ / 200;
   constant C_BTN_C    : natural  := 0;
   constant C_BTN_U    : natural  := 1;
   constant C_BTN_L    : natural  := 2;
   constant C_BTN_R    : natural  := 3;
   constant C_BTN_D    : natural  := 4;

   constant C_REGS : t_word := X"FFFFFFE0";
   constant C_CTRL : t_word := X"FFFFFFF0";
   -- The breakpoints' enable bits, and the address of breakpoint 0
   constant C_BRK_EN   : t_word := X"FFFFFFF4";
   constant C_BRK_ADDR : t_word := X"FFFFFFF8";
   -- The debug registers read at each refresh: the control register up to
   -- the address of breakpoint 3. The page shows 4 breakpoints, as many
   -- as every board has.
   constant C_CTRL_N : natural := 12;
   constant C_BRKS   : natural := 4;

   type t_words is array (0 to 15) of t_word;

   type t_brk_addrs is array (0 to C_BRKS - 1) of t_word;

   type t_act is (ACT_NONE, ACT_STEP, ACT_GO, ACT_PAUSE, ACT_HOLD, ACT_RESTART, ACT_STICKY, ACT_POKE, ACT_BREAK);

   -- The keys of the page
   type t_pkey is (PK_NONE, PK_PAGE, PK_UP, PK_DOWN, PK_LEFT, PK_RIGHT, PK_PGUP, PK_PGDN, PK_HOME, PK_DIGIT, PK_DEL, PK_RETURN, PK_ESC);

   type t_mem is array (0 to 255) of std_logic_vector(31 downto 0);

   type t_state is (OFF_ST, STRIP_ST, FOCUS_ST);

   type t_kbd_st is (KBD_IDLE_ST, KBD_ESC_ST, KBD_SS3_ST, KBD_CSI_ST);

   type t_seq_st is (SEQ_IDLE_ST, SEQ_CTRL_ST, SEQ_WRITE_ST, SEQ_START_ST, SEQ_REGS_ST, SEQ_INSTR_ST, SEQ_MEM_ST, SEQ_BRK_ST);

   ---------------------------------------------------------------------------
   -- The cells of the strip
   ---------------------------------------------------------------------------

   -- What a word of the overlay shows: a fixed character; hex digit nib of
   -- word idx, R0-R15 for 0 to 15, the word at the PC for 16, the PC for
   -- 17, the window's address for 18, the cursor's for 19, the row's for
   -- 20, and the address of breakpoint idx - 21 for 21 to 24; character idx of the state's name; flag idx of SR, X to I;
   -- character idx of the keys' row, which depends on the state; hex digit
   -- nib of word idx of a row of memory; or character idx of the input
   -- field's label, of the field, or of the message
   type t_kind is (CELL_FIX, CELL_HEX, CELL_STATE, CELL_FLAG, CELL_KEYS, CELL_MEM, CELL_LABEL, CELL_FIELD, CELL_MSG);

   type t_cell is record
      kind : t_kind;
      idx  : natural range 0 to C_COLS - 1;
      nib  : natural range 0 to 7;
      ch   : t_byte;
   end record t_cell;

   type t_cells is array (0 to C_STRIP_LEN - 1) of t_cell;

   type t_row is array (0 to C_COLS - 1) of t_cell;

   constant C_IDX_INSTR  : natural := 16;
   constant C_IDX_PC     : natural := 17;
   constant C_IDX_WINDOW : natural := 18;
   constant C_IDX_CURSOR : natural := 19;
   constant C_IDX_ROW    : natural := 20;
   constant C_IDX_BRK    : natural := 21;

   -- The columns of row 27: the state's name, the PC, the word at the PC,
   -- and the flags, every second column
   constant C_COL_STATE : natural := 1;
   constant C_COL_PC    : natural := 10;
   constant C_COL_INSTR : natural := 20;
   constant C_COL_FLAGS : natural := 30;
   constant C_STATE_LEN : natural := 9;

   function to_byte(c : character) return t_byte is
   begin
      return std_logic_vector(to_unsigned(character'pos(c), 8));
   end function to_byte;

   type t_strings3 is array (0 to 2) of string(1 to C_COLS);

   -- s, cut or padded with spaces to a row
   function row(s : string) return string is
      variable res_v : string(1 to C_COLS) := (others => ' ');
   begin
      for i in 1 to C_COLS loop
         if i <= s'length then
            res_v(i) := s(s'low + i - 1);
         end if;
      end loop;
      return res_v;
   end function row;

   function cells return t_cells is
      constant C_FIX : t_cell := (kind => CELL_FIX, idx => 0, nib => 0, ch => to_byte(' '));
      variable res_v : t_cells := (others => C_FIX);
      variable c_v   : natural;
   begin
      -- Rows 25 and 26: R0-R7 and R8-R15, a word in 8 digits and a space
      for r in 0 to 1 loop
         for c in 0 to C_COLS - 1 loop
            if c < 8 then
               if r = 0 then
                  res_v(r * C_COLS + c).ch := to_byte(row(" R0-7")(c + 1));
               else
                  res_v(r * C_COLS + c).ch := to_byte(row(" R8-15")(c + 1));
               end if;
            elsif (c - 8) mod 9 < 8 then
               res_v(r * C_COLS + c) := (kind => CELL_HEX, idx => r * 8 + (c - 8) / 9, nib => 7 - (c - 8) mod 9, ch => to_byte(' '));
            end if;
         end loop;
      end loop;

      -- Row 27: the state, the PC, the word at the PC, and the flags
      c_v := 2 * C_COLS;
      for i in 0 to C_STATE_LEN - 1 loop
         res_v(c_v + C_COL_STATE + i) := (kind => CELL_STATE, idx => i, nib => 0, ch => to_byte(' '));
      end loop;
      for i in 0 to 7 loop
         res_v(c_v + C_COL_PC + i)    := (kind => CELL_HEX, idx => C_IDX_PC, nib => 7 - i, ch => to_byte(' '));
         res_v(c_v + C_COL_INSTR + i) := (kind => CELL_HEX, idx => C_IDX_INSTR, nib => 7 - i, ch => to_byte(' '));
      end loop;
      for i in 0 to 6 loop
         res_v(c_v + C_COL_FLAGS + 2 * i) := (kind => CELL_FLAG, idx => i, nib => 0, ch => to_byte(' '));
      end loop;

      -- Row 28: the keys
      for c in 0 to C_COLS - 1 loop
         res_v(3 * C_COLS + c) := (kind => CELL_KEYS, idx => c, nib => 0, ch => to_byte(' '));
      end loop;
      return res_v;
   end function cells;

   constant C_CELLS : t_cells := cells;

   -- A row of the page from a template: % is a digit of the window's
   -- address, & of the cursor's, $ of the row's, @ of a breakpoint's, # of
   -- a word of memory, < a character of the field's label, ? of the field, and ! of the
   -- message; any other character is itself
   function row_cells(s : string) return t_row is
      constant C_S    : string(1 to C_COLS) := row(s);
      variable res_v  : t_row;
      variable run_v  : natural := 0;                     -- The place in a run of a marker
      variable word_v : natural := 0;                     -- The runs of # before
      variable brk_v  : natural := 0;                     -- The runs of @ before
      variable ch_v   : character;
   begin
      for c in 0 to C_COLS - 1 loop
         ch_v := C_S(c + 1);
         if c > 0 and ch_v = C_S(c) then
            run_v := run_v + 1;
         else
            run_v := 0;
         end if;
         res_v(c) := (kind => CELL_FIX, idx => 0, nib => 0, ch => to_byte(ch_v));
         case ch_v is
            when '%' => res_v(c) := (kind => CELL_HEX, idx => C_IDX_WINDOW, nib => 7 - run_v, ch => X"20");
            when '&' => res_v(c) := (kind => CELL_HEX, idx => C_IDX_CURSOR, nib => 7 - run_v, ch => X"20");
            when '$' => res_v(c) := (kind => CELL_HEX, idx => C_IDX_ROW, nib => 7 - run_v, ch => X"20");
            when '@' =>
               res_v(c) := (kind => CELL_HEX, idx => C_IDX_BRK + brk_v, nib => 7 - run_v, ch => X"20");
               if run_v = 7 then
                  brk_v := brk_v + 1;
               end if;
            when '#' =>
               res_v(c) := (kind => CELL_MEM, idx => word_v, nib => 7 - run_v, ch => X"20");
               if run_v = 7 then
                  word_v := word_v + 1;
               end if;
            when '<' => res_v(c) := (kind => CELL_LABEL, idx => run_v, nib => 0, ch => X"20");
            when '?' => res_v(c) := (kind => CELL_FIELD, idx => run_v, nib => 0, ch => X"20");
            when '!' => res_v(c) := (kind => CELL_MSG, idx => run_v, nib => 0, ch => X"20");
            when others => null;
         end case;
      end loop;
      return res_v;
   end function row_cells;

   -- Row 0, the rows of memory, row 23, and row 24 of the page
   constant C_HEAD_ROW  : t_row := row_cells(" Window %%%%%%%%  Cursor &&&&&&&&  Breaks @@@@@@@@ @@@@@@@@ @@@@@@@@ @@@@@@@@");
   constant C_MEM_ROW   : t_row := row_cells("$$$$$$$$ ######## ######## ######## ######## ######## ######## ######## ########");
   constant C_INPUT_ROW : t_row := row_cells(" <<<<<<<< ????????  !!!!!!!!!!");
   constant C_PKEYS_ROW : t_row := row_cells(" CRSR PgUp PgDn Home move  0-f type  RETURN write  a address  b break  ESC back");

   -- The field's label, for a word in 0 to 7 and for an address in 8 to
   -- 15, one dimension, as GHDL 4.1 cannot synthesize the read of a
   -- two-dimensional one here; and the messages
   type t_labels is array (0 to 15) of t_byte;

   type t_msgs is array (0 to 4, 0 to 9) of t_byte;

   constant C_MSG_NONE    : natural := 0;
   constant C_MSG_WRITTEN : natural := 1;
   constant C_MSG_ERR     : natural := 2;                -- e and the code's two digits
   constant C_MSG_TIMEOUT : natural := 3;
   constant C_MSG_FULL    : natural := 4;                -- No breakpoint is free

   function labels return t_labels is
      constant C_S   : string(1 to 16) := "Word:   Address:";
      variable res_v : t_labels;
   begin
      for i in 0 to 15 loop
         res_v(i) := to_byte(C_S(i + 1));
      end loop;
      return res_v;
   end function labels;

   function msgs return t_msgs is
      constant C_S   : string(1 to 50) := "          written   e         no answer none free ";
      variable res_v : t_msgs;
   begin
      for k in 0 to 4 loop
         for i in 0 to 9 loop
            res_v(k, i) := to_byte(C_S(10 * k + i + 1));
         end loop;
      end loop;
      return res_v;
   end function msgs;

   constant C_LABELS : t_labels := labels;
   constant C_MSGS   : t_msgs   := msgs;

   -- The names of the states, in C_STATE_LEN characters each, and the
   -- position of the digit of BRK n and HALTED n
   type t_names is array (0 to 5, 0 to C_STATE_LEN - 1) of t_byte;

   constant C_ST_NOLINK  : natural := 0;
   constant C_ST_RUNNING : natural := 1;
   constant C_ST_PAUSED  : natural := 2;
   constant C_ST_BRK     : natural := 3;
   constant C_ST_HALTED  : natural := 4;
   constant C_ST_HELD    : natural := 5;

   function names return t_names is
      type     t_strings is array (0 to 5) of string(1 to C_STATE_LEN);
      constant C_S   : t_strings := ("NO LINK  ", "RUNNING  ", "PAUSED   ", "BRK      ", "HALTED   ", "HELD     ");
      variable res_v : t_names;
   begin
      for s in 0 to 5 loop
         for i in 0 to C_STATE_LEN - 1 loop
            res_v(s, i) := to_byte(C_S(s)(i + 1));
         end loop;
      end loop;
      return res_v;
   end function names;

   constant C_NAMES     : t_names := names;
   constant C_BRK_DIG   : natural := 4;
   constant C_HALT_DIG  : natural := 7;
   constant C_FLAG_CHAR : string(1 to 7) := "XCZNVEI";

   -- Row 28: the keys in Focus, with the sticky setting, and the note of
   -- Strip, which names the toggle key
   type t_keys is array (0 to 2, 0 to C_COLS - 1) of t_byte;

   constant C_KEYS_OFF   : natural := 0;
   constant C_KEYS_STRIP : natural := 1;
   constant C_KEYS_PROG  : natural := 2;

   function keys return t_keys is
      constant C_F   : string := " F1 step  F3 go  F5 pause  F7 hold  F9 restart  F11 page  F12 keep strip: ";
      constant C_R   : t_strings3 := (row(C_F & "off"), row(C_F & "on"),
         row(" The keys are the program's.  " & G_TOGGLE_KEY & " for the debugger"));
      variable res_v : t_keys;
   begin
      for k in 0 to 2 loop
         for c in 0 to C_COLS - 1 loop
            res_v(k, c) := to_byte(C_R(k)(c + 1));
         end loop;
      end loop;
      return res_v;
   end function keys;

   constant C_KEYS : t_keys := keys;

   function hex_char(n : std_logic_vector(3 downto 0)) return t_byte is
   begin
      if n < 10 then
         return X"3" & n;
      else
         return ("0000" & n) + X"37";
      end if;
   end function hex_char;

   -- The segments of a hex digit, bit 0 segment A to bit 6 segment G
   type t_hex7 is array (0 to 15) of t_byte;

   constant C_HEX7     : t_hex7 := (X"3F", X"06", X"5B", X"4F", X"66", X"6D", X"7D", X"07",
      X"7F", X"6F", X"77", X"7C", X"39", X"5E", X"79", X"71");
   constant C_SEG_DASH : t_byte := X"40";

   function nibble(w : t_word;
                   n : natural range 0 to 7) return std_logic_vector is
   begin
      case n is
         when 0 => return w(3 downto 0);
         when 1 => return w(7 downto 4);
         when 2 => return w(11 downto 8);
         when 3 => return w(15 downto 12);
         when 4 => return w(19 downto 16);
         when 5 => return w(23 downto 20);
         when 6 => return w(27 downto 24);
         when 7 => return w(31 downto 28);
      end case;
   end function nibble;

   ---------------------------------------------------------------------------
   -- Signals
   ---------------------------------------------------------------------------

   signal state  : t_state   := OFF_ST;
   signal enter  : std_logic;
   signal sticky : std_logic := '0';                     -- Leave Focus to Strip
   signal catch  : std_logic;                            -- A stop to catch in Strip
   signal own_r  : std_logic := '0';                     -- A stop of the debugger's own is due
   signal keys_k : natural range 0 to 2;
   signal leave  : std_logic;                            -- BTNC in Focus

   -- The buttons: synchronized, sampled, and the presses
   signal btn_meta  : std_logic_vector(4 downto 0) := (others => '0');
   signal btn_sync  : std_logic_vector(4 downto 0) := (others => '0');
   signal btn_level : std_logic_vector(4 downto 0) := (others => '0');
   signal btn_press : std_logic_vector(4 downto 0) := (others => '0');
   signal btn_cnt   : natural range 0 to C_BTN_WAIT - 1 := 0;

   attribute async_reg : string;
   attribute async_reg of btn_meta : signal is "TRUE";
   attribute async_reg of btn_sync : signal is "TRUE";

   signal kbd_st   : t_kbd_st := KBD_IDLE_ST;
   signal kbd_num  : natural range 0 to 99;
   signal key_act  : t_act    := ACT_NONE;
   signal pkey     : t_pkey   := PK_NONE;
   signal pkey_dig : std_logic_vector(3 downto 0);
   signal esc_cnt  : natural range 0 to C_ESC_WAIT - 1;

   -- The page: shown in Focus, the window's address, the cursor's word in
   -- it, and the input field, its digits, and whether it is an address
   signal page_r     : std_logic := '0';
   signal page_on    : std_logic;
   signal window     : t_word    := (others => '0');
   signal cur        : natural range 0 to C_MEM_LEN - 1 := 0;
   signal field      : t_word    := (others => '0');
   signal field_n    : natural range 0 to 8 := 0;
   signal field_addr : std_logic := '0';
   signal pg_dirty   : std_logic := '0';                 -- The page changed
   signal mem_move   : std_logic := '0';                 -- The window moved
   signal poke       : std_logic := '0';                 -- Write poke_data to poke_addr
   signal poke_addr  : t_word;
   signal poke_data  : t_word;
   signal brk        : std_logic := '0';                 -- Toggle a breakpoint at brk_at
   signal brk_at     : t_word;

   -- The request to the host, and its answers
   signal req_valid : std_logic := '0';
   signal req_ready : std_logic;
   signal req_we    : std_logic;
   signal req_addr  : t_word;
   signal req_n     : std_logic_vector(15 downto 0);
   signal req_data  : t_word;
   signal rd_valid  : std_logic;
   signal rd_data   : t_word;
   signal done      : std_logic;
   signal err       : std_logic;
   signal ntc_valid : std_logic;
   signal ntc_tag   : t_byte;

   -- The sequence of requests
   signal seq_st    : t_seq_st := SEQ_IDLE_ST;
   signal act_r     : t_act    := ACT_NONE;
   signal tick_r    : std_logic := '0';
   signal refresh   : natural range 0 to C_REFRESH - 1 := 0;
   signal rd_idx    : natural range 0 to 255;
   signal restart_r : std_logic;
   signal msg_r     : std_logic := '0';                  -- The write's answer is the page's message
   signal msg_ok    : natural range 0 to 4;              -- ... and this, when it is k
   signal brk_set   : std_logic_vector(C_BRKS - 1 downto 0);
   signal err_code  : t_byte;

   -- What the debugger knows of the core
   signal ctrl_r   : t_word := (others => '0');
   signal reason_r : t_byte := (others => '0');
   signal stop_r   : std_logic_vector(8 downto 0) := (others => '0');
   signal regs_r   : t_words := (others => (others => '0'));
   signal instr_r  : t_word := (others => '0');
   signal brk_en_r : std_logic_vector(C_BRKS - 1 downto 0) := (others => '0');
   signal brk_n    : natural range 0 to C_BRKS := 0;     -- The breakpoints of the link, up to 4
   signal brk_r    : t_brk_addrs := (others => (others => '0'));
   signal link_ok  : std_logic := '0';                   -- The last refresh had an answer
   signal regs_any : std_logic := '0';                   -- R0-R15 were read once
   signal regs_ok  : std_logic := '0';                   -- ... since the current stop
   signal instr_ok : std_logic := '0';                   -- The word at the PC too
   signal st_code  : natural range 0 to 5;

   -- The words of the window, read when the core is stopped
   signal mem_ram  : t_mem;
   signal mem_q    : t_word;
   signal mem_any  : std_logic := '0';                   -- The window was read once
   signal mem_ok   : std_logic := '0';                   -- ... since the core stopped
   signal mem_kill : std_logic := '0';                   -- The read is of a window left
   signal msg_k    : natural range 0 to 4 := C_MSG_NONE;
   signal msg_code : t_byte := (others => '0');

   -- The drawing: a pass over the strip after each change
   signal dirty      : std_logic := '1';
   signal draw_start : std_logic;
   signal draw_cnt   : natural range 0 to C_ALL_LEN := C_ALL_LEN;
   signal draw_row   : natural range 0 to C_STRIP_ROW + C_STRIP_ROWS - 1;
   signal draw_col   : natural range 0 to C_COLS - 1;
   signal s1_valid   : std_logic := '0';
   signal s1_cell    : t_cell;
   signal s1_addr    : natural range 0 to C_ALL_LEN - 1;
   signal s1_row     : natural range 0 to C_STRIP_ROW + C_STRIP_ROWS - 1;
   signal s1_mem     : natural range 0 to 255;           -- The word of the window
   signal s2_valid   : std_logic := '0';
   signal s2_cell    : t_cell;
   signal s2_addr    : natural range 0 to C_ALL_LEN - 1;
   signal s2_word    : t_word;
   signal s2_nib     : natural range 0 to 7;
   signal s2_shown   : std_logic;                        -- The word is known
   signal s2_dim     : std_logic;
   signal s2_cur     : std_logic;                        -- The cursor's word
   signal s2_brk     : std_logic;                        -- A word at an enabled breakpoint
   signal s2_ch      : t_byte;                           -- A fixed or state character

   signal ovl_we   : std_logic := '0';
   signal ovl_addr : std_logic_vector(11 downto 0) := (others => '0');
   signal ovl_data : std_logic_vector(31 downto 0) := (others => '0');

begin

   kbd_ready_o <= '1';

   ovl_we_o   <= ovl_we;
   ovl_addr_o <= ovl_addr;
   ovl_data_o <= ovl_data;

   strip_o <= '1' when state /= OFF_ST else '0';
   page_on <= page_r when state = FOCUS_ST else '0';
   page_o  <= page_on;
   focus_o <= '1' when state = FOCUS_ST else '0';
   on_o    <= '1' when state /= OFF_ST or seq_st /= SEQ_IDLE_ST or req_valid = '1' or req_ready = '0' else
              '0';

   enter <= '1' when toggle_i = '1' and state = OFF_ST else '0';
   leave <= '1' when btn_press(C_BTN_C) = '1' and state = FOCUS_ST else '0';

   p_state : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if key_act = ACT_STICKY then
            sticky <= not sticky;
         end if;

         if toggle_i = '1' or leave = '1' then
            case state is
               when OFF_ST | STRIP_ST =>
                  state <= FOCUS_ST;
               when FOCUS_ST =>
                  if sticky = '1' then
                     state <= STRIP_ST;
                  else
                     state <= OFF_ST;
                  end if;
            end case;
         elsif catch = '1' and state = STRIP_ST then
            state <= FOCUS_ST;
         end if;

         if rst_i = '1' then
            state  <= OFF_ST;
            sticky <= '0';
         end if;
      end if;
   end process p_state;

   ---------------------------------------------------------------------------
   -- The keys
   ---------------------------------------------------------------------------

   p_kbd : process (clk_i)
   begin
      if rising_edge(clk_i) then
         key_act <= ACT_NONE;
         pkey    <= PK_NONE;
         if kbd_valid_i = '1' and state = FOCUS_ST then
            case kbd_st is

               when KBD_IDLE_ST =>
                  pkey_dig <= kbd_data_i(3 downto 0);
                  case kbd_data_i is
                     when X"1B"  =>
                        kbd_st  <= KBD_ESC_ST;
                        esc_cnt <= C_ESC_WAIT - 1;
                     when X"73"  => key_act <= ACT_STEP;    -- s
                     when X"67"  => key_act <= ACT_GO;      -- g
                     when X"70"  => key_act <= ACT_PAUSE;   -- p
                     when X"68"  => key_act <= ACT_HOLD;    -- h
                     when X"72"  => key_act <= ACT_RESTART; -- r
                     when X"6D"  => pkey    <= PK_PAGE;     -- m
                     when X"0D"  => pkey    <= PK_RETURN;
                     when X"7F"  => pkey    <= PK_DEL;
                     when X"30" | X"31" | X"32" | X"33" | X"34" |
                          X"35" | X"36" | X"37" | X"38" | X"39" =>
                        pkey <= PK_DIGIT;
                     when X"41" | X"42" | X"43" | X"44" | X"45" | X"46" |
                          X"61" | X"62" | X"63" | X"64" | X"65" | X"66" =>
                        pkey     <= PK_DIGIT;               -- A to F, a to f
                        pkey_dig <= kbd_data_i(3 downto 0) + 9;
                     when others => null;
                  end case;

               when KBD_ESC_ST =>
                  kbd_num <= 0;
                  case kbd_data_i is
                     when X"4F"  => kbd_st <= KBD_SS3_ST;   -- O
                     when X"5B"  => kbd_st <= KBD_CSI_ST;   -- [
                     when X"1B"  =>                         -- The ESC before was a key
                        pkey    <= PK_ESC;
                        esc_cnt <= C_ESC_WAIT - 1;
                     when others =>
                        pkey   <= PK_ESC;
                        kbd_st <= KBD_IDLE_ST;
                  end case;

               when KBD_SS3_ST =>
                  kbd_st <= KBD_IDLE_ST;
                  case kbd_data_i is
                     when X"50"  => key_act <= ACT_STEP;    -- F1
                     when X"52"  => key_act <= ACT_GO;      -- F3
                     when others => null;
                  end case;

               when KBD_CSI_ST =>
                  if kbd_data_i >= X"30" and kbd_data_i <= X"39" then
                     if kbd_num < 10 then
                        kbd_num <= kbd_num * 10 + to_integer(kbd_data_i(3 downto 0));
                     else
                        kbd_num <= 99;
                     end if;
                  else
                     kbd_st <= KBD_IDLE_ST;
                     case kbd_data_i is
                        when X"7E" =>                                -- ~
                           case kbd_num is
                              when 5      => pkey    <= PK_PGUP;
                              when 6      => pkey    <= PK_PGDN;
                              when 15     => key_act <= ACT_PAUSE;   -- F5
                              when 18     => key_act <= ACT_HOLD;    -- F7
                              when 20     => key_act <= ACT_RESTART; -- F9
                              when 23     => pkey    <= PK_PAGE;     -- F11
                              when 24     => key_act <= ACT_STICKY;  -- F12
                              when others => null;
                           end case;
                        when X"41"  => pkey <= PK_UP;                -- A
                        when X"42"  => pkey <= PK_DOWN;              -- B
                        when X"43"  => pkey <= PK_RIGHT;             -- C
                        when X"44"  => pkey <= PK_LEFT;              -- D
                        when X"48"  => pkey <= PK_HOME;              -- H
                        when others => null;
                     end case;
                  end if;

            end case;
         elsif state = FOCUS_ST and btn_press(C_BTN_L) = '1' then
            key_act <= ACT_STEP;
         elsif state = FOCUS_ST and btn_press(C_BTN_R) = '1' then
            key_act <= ACT_GO;
         elsif state = FOCUS_ST and btn_press(C_BTN_U) = '1' then
            pkey <= PK_UP;
         elsif state = FOCUS_ST and btn_press(C_BTN_D) = '1' then
            pkey <= PK_DOWN;
         elsif kbd_st = KBD_ESC_ST then
            -- No byte after the ESC: the ESC key
            if esc_cnt = 0 then
               pkey   <= PK_ESC;
               kbd_st <= KBD_IDLE_ST;
            else
               esc_cnt <= esc_cnt - 1;
            end if;
         end if;

         if rst_i = '1' then
            kbd_st  <= KBD_IDLE_ST;
            key_act <= ACT_NONE;
            pkey    <= PK_NONE;
         end if;
      end if;
   end process p_kbd;

   ---------------------------------------------------------------------------
   -- The board's buttons and display
   ---------------------------------------------------------------------------

   gen_board_io : if G_BOARD_IO generate

      -- A press is a sample at 1 after one at 0
      p_btn : process (clk_i)
      begin
         if rising_edge(clk_i) then
            btn_meta  <= btn_i;
            btn_sync  <= btn_meta;
            btn_press <= (others => '0');
            if btn_cnt = 0 then
               btn_cnt   <= C_BTN_WAIT - 1;
               btn_level <= btn_sync;
               btn_press <= btn_sync and not btn_level;
            else
               btn_cnt <= btn_cnt - 1;
            end if;

            if rst_i = '1' then
               btn_level <= (others => '0');
               btn_press <= (others => '0');
            end if;
         end if;
      end process p_btn;

      -- The PC at a stop, else dashes
      p_seg : process (clk_i)
      begin
         if rising_edge(clk_i) then
            for i in 0 to 7 loop
               if regs_ok = '1' and link_ok = '1' then
                  seg_o(8 * i + 7 downto 8 * i) <= C_HEX7(to_integer(nibble(regs_r(15), i)));
               else
                  seg_o(8 * i + 7 downto 8 * i) <= C_SEG_DASH;
               end if;
            end loop;
         end if;
      end process p_seg;

   else generate
      seg_o <= (others => '0');
   end generate gen_board_io;

   ---------------------------------------------------------------------------
   -- The page
   ---------------------------------------------------------------------------

   p_page : process (clk_i)

      procedure clear is
      begin
         field      <= (others => '0');
         field_n    <= 0;
         field_addr <= '0';
      end procedure clear;

   begin
      if rising_edge(clk_i) then
         pg_dirty <= '0';
         mem_move <= '0';
         poke     <= '0';
         brk      <= '0';
         if state = FOCUS_ST and pkey /= PK_NONE then
            pg_dirty <= '1';
            if pkey = PK_PAGE then
               page_r   <= not page_r;
               mem_move <= not page_r;
            elsif page_r = '1' then
               case pkey is
                  when PK_UP =>
                     if cur < 8 then
                        window   <= window - 8;
                        mem_move <= '1';
                     else
                        cur <= cur - 8;
                     end if;
                  when PK_DOWN =>
                     if cur >= C_MEM_LEN - 8 then
                        window   <= window + 8;
                        mem_move <= '1';
                     else
                        cur <= cur + 8;
                     end if;
                  when PK_LEFT =>
                     if cur = 0 then
                        window   <= window - 8;
                        cur      <= 7;
                        mem_move <= '1';
                     else
                        cur <= cur - 1;
                     end if;
                  when PK_RIGHT =>
                     if cur = C_MEM_LEN - 1 then
                        window   <= window + 8;
                        cur      <= C_MEM_LEN - 8;
                        mem_move <= '1';
                     else
                        cur <= cur + 1;
                     end if;
                  when PK_PGUP =>
                     window   <= window - C_MEM_LEN;
                     mem_move <= '1';
                  when PK_PGDN =>
                     window   <= window + C_MEM_LEN;
                     mem_move <= '1';
                  when PK_HOME =>
                     cur <= 0;
                  when PK_DIGIT =>
                     -- a on an empty field is the key of an address, and b
                     -- the key of a breakpoint
                     if pkey_dig = X"A" and field_n = 0 and field_addr = '0' then
                        field_addr <= '1';
                     elsif pkey_dig = X"B" and field_n = 0 and field_addr = '0' then
                        brk    <= '1';
                        brk_at <= window + cur;
                     else
                        field <= field(27 downto 0) & pkey_dig;
                        if field_n /= 8 then
                           field_n <= field_n + 1;
                        end if;
                     end if;
                  when PK_DEL =>
                     field <= X"0" & field(31 downto 4);
                     if field_n /= 0 then
                        field_n <= field_n - 1;
                     else
                        field_addr <= '0';
                     end if;
                  when PK_RETURN =>
                     if field_n /= 0 and field_addr = '1' then
                        window   <= field;
                        cur      <= 0;
                        mem_move <= '1';
                     elsif field_n /= 0 then
                        poke      <= '1';
                        poke_addr <= window + cur;
                        poke_data <= field;
                     end if;
                     clear;
                  when PK_ESC =>
                     if field_n /= 0 or field_addr = '1' then
                        clear;
                     else
                        page_r <= '0';
                     end if;
                  when others =>
                     null;
               end case;
            end if;
         end if;

         if rst_i = '1' then
            page_r <= '0';
            window <= (others => '0');
            cur    <= 0;
            clear;
         end if;
      end if;
   end process p_page;

   ---------------------------------------------------------------------------
   -- The link
   ---------------------------------------------------------------------------

   i_dbg_host : entity work.dbg_host
      generic map (
         G_TIMEOUT => C_TIMEOUT
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         req_valid_i => req_valid,
         req_ready_o => req_ready,
         req_we_i    => req_we,
         req_addr_i  => req_addr,
         req_n_i     => req_n,
         req_data_i  => req_data,
         rd_valid_o  => rd_valid,
         rd_data_o   => rd_data,
         done_o      => done,
         err_o       => err,
         err_code_o  => err_code,
         ntc_valid_o => ntc_valid,
         ntc_tag_o   => ntc_tag,
         ntc_arg_o   => open,
         con_valid_o => open,
         con_data_o  => open,
         lrx_valid_o => lrx_valid_o,
         lrx_ready_i => lrx_ready_i,
         lrx_data_o  => lrx_data_o,
         ltx_valid_i => ltx_valid_i,
         ltx_ready_o => ltx_ready_o,
         ltx_data_i  => ltx_data_i
      ); -- i_dbg_host


   p_seq : process (clk_i)
      variable rom_v   : t_word;
      variable data_v  : t_word;
      variable write_v : boolean;
      variable hit_v   : integer range -1 to C_BRKS - 1; -- The breakpoint at brk_at
      variable free_v  : integer range -1 to C_BRKS - 1; -- The lowest free one

      procedure read(addr : t_word;
                     n    : natural) is
      begin
         req_valid <= '1';
         req_we    <= '0';
         req_addr  <= addr;
         req_n     <= std_logic_vector(to_unsigned(n, 16));
         rd_idx    <= 0;
      end procedure read;

      procedure write(addr : t_word;
                      data : t_word) is
      begin
         req_valid <= '1';
         req_we    <= '1';
         req_addr  <= addr;
         req_n     <= X"0001";
         req_data  <= data;
      end procedure write;

      -- The page's message from the answer of a write
      procedure answer is
      begin
         msg_r <= '0';
         if err = '0' then
            msg_k <= msg_ok;
         elsif err_code = X"FF" then
            msg_k <= C_MSG_TIMEOUT;
         else
            msg_k <= C_MSG_ERR;
         end if;
         msg_code <= err_code;
      end procedure answer;

   begin
      if rising_edge(clk_i) then
         if refresh = 0 then
            refresh <= C_REFRESH - 1;
            tick_r  <= '1';
         else
            refresh <= refresh - 1;
         end if;

         if req_valid = '1' and req_ready = '1' then
            req_valid <= '0';
         end if;

         -- The words of an `r`, into what the request reads
         if rd_valid = '1' then
            if rd_idx /= 255 then
               rd_idx <= rd_idx + 1;
            end if;
            case seq_st is
               when SEQ_CTRL_ST =>
                  case rd_idx is
                     when 0      => ctrl_r   <= rd_data;
                     when 1      => reason_r <= rd_data(7 downto 0);
                     when 4      => brk_en_r <= rd_data(C_BRKS - 1 downto 0);
                     when 5      =>
                        if rd_data(7 downto 0) < C_BRKS then
                           brk_n <= to_integer(rd_data(2 downto 0));
                        else
                           brk_n <= C_BRKS;
                        end if;
                     when 6      => stop_r <= rd_data(8 downto 0);
                     when 8 to 11 => brk_r(rd_idx mod 4) <= rd_data;
                     when others => null;
                  end case;
               when SEQ_REGS_ST  => regs_r(rd_idx mod 16) <= rd_data;
               when SEQ_INSTR_ST => instr_r               <= rd_data;
               when others       => null;
            end case;
         end if;

         if done = '1' then
            dirty <= '1';
         end if;
         if draw_start = '1' then
            dirty <= '0';
         end if;

         rom_v := (3 => ctrl_r(3), others => '0');

         case seq_st is

            when SEQ_IDLE_ST =>
               if state /= OFF_ST and req_valid = '0' and (tick_r = '1' or act_r /= ACT_NONE) then
                  tick_r <= '0';
                  read(C_CTRL, C_CTRL_N);
                  seq_st <= SEQ_CTRL_ST;
               end if;

            -- The debug registers: a key's write, or R0-R15 at a new stop
            when SEQ_CTRL_ST =>
               if done = '1' then
                  link_ok <= not err;
                  seq_st  <= SEQ_IDLE_ST;
                  if err = '0' then
                     write_v   := true;
                     data_v    := rom_v;
                     restart_r <= '0';
                     msg_r     <= '0';
                     case act_r is
                        when ACT_STEP =>
                           write_v := ctrl_r(4) = '1';
                           data_v  := X"00000030" or rom_v;
                        when ACT_GO =>
                           write_v := ctrl_r(4) = '1';
                        when ACT_PAUSE =>
                           write_v := ctrl_r(4) = '0' and ctrl_r(1) = '0' and ctrl_r(0) = '0';
                           data_v  := X"00000010" or rom_v;
                        when ACT_HOLD =>
                           data_v := X"00000001" or rom_v;
                        when ACT_RESTART =>
                           restart_r <= '1';
                           data_v    := X"00000001" or rom_v;
                        when ACT_POKE =>
                           msg_r  <= '1';
                           msg_ok <= C_MSG_WRITTEN;
                        when ACT_NONE | ACT_STICKY | ACT_BREAK =>
                           write_v := false;
                     end case;
                     act_r <= ACT_NONE;

                     -- A breakpoint at brk_at is cleared, else the lowest
                     -- free one is set there
                     hit_v  := -1;
                     free_v := -1;
                     for i in C_BRKS - 1 downto 0 loop
                        if i < brk_n and brk_en_r(i) = '1' and brk_r(i) = brk_at then
                           hit_v := i;
                        end if;
                        if i < brk_n and brk_en_r(i) = '0' then
                           free_v := i;
                        end if;
                     end loop;

                     if act_r = ACT_BREAK then
                        msg_r   <= '1';
                        msg_ok  <= C_MSG_NONE;
                        brk_set <= brk_en_r;
                        if hit_v >= 0 then
                           write(C_BRK_EN, (others => '0'));
                           req_data(C_BRKS - 1 downto 0) <= brk_en_r;
                           req_data(hit_v)               <= '0';
                           seq_st                        <= SEQ_WRITE_ST;
                        elsif free_v >= 0 then
                           brk_set(free_v) <= '1';
                           write(C_BRK_ADDR + free_v, brk_at);
                           seq_st <= SEQ_BRK_ST;
                        else
                           msg_r <= '0';
                           msg_k <= C_MSG_FULL;
                        end if;
                     elsif write_v then
                        if act_r = ACT_STEP or act_r = ACT_PAUSE then
                           own_r <= '1';
                        end if;
                        if act_r = ACT_POKE then
                           write(poke_addr, poke_data);
                        else
                           write(C_CTRL, data_v);
                        end if;
                        regs_ok  <= '0';
                        instr_ok <= '0';
                        mem_ok   <= '0';
                        seq_st   <= SEQ_WRITE_ST;
                     elsif (ctrl_r(4) = '1' or ctrl_r(1) = '1') and regs_ok = '0' then
                        read(C_REGS, 16);
                        seq_st <= SEQ_REGS_ST;
                     elsif ctrl_r(4) = '1' or ctrl_r(1) = '1' or ctrl_r(0) = '1' then
                        -- The window, while the page is shown and the core
                        -- stopped
                        if page_on = '1' and mem_ok = '0' then
                           read(window, C_MEM_LEN);
                           mem_kill <= '0';
                           seq_st   <= SEQ_MEM_ST;
                        end if;
                     end if;
                  end if;
               end if;

            -- The address of a breakpoint, then its enable bit
            when SEQ_BRK_ST =>
               if done = '1' then
                  if err = '0' then
                     write(C_BRK_EN, (others => '0'));
                     req_data(C_BRKS - 1 downto 0) <= brk_set;
                     seq_st                        <= SEQ_WRITE_ST;
                  else
                     answer;
                     read(C_CTRL, C_CTRL_N);
                     seq_st <= SEQ_CTRL_ST;
                  end if;
               end if;

            -- The write of a key, and the start of a restart, then the
            -- registers again
            when SEQ_WRITE_ST =>
               if done = '1' then
                  -- The message of a word's or a breakpoint's write
                  if msg_r = '1' then
                     answer;
                  end if;
                  if restart_r = '1' then
                     restart_r <= '0';
                     write(C_CTRL, rom_v);
                     seq_st    <= SEQ_START_ST;
                  else
                     read(C_CTRL, C_CTRL_N);
                     seq_st <= SEQ_CTRL_ST;
                  end if;
               end if;

            when SEQ_START_ST =>
               if done = '1' then
                  read(C_CTRL, C_CTRL_N);
                  seq_st <= SEQ_CTRL_ST;
               end if;

            -- R0-R15, then the word at the PC; e02 if the core went on
            when SEQ_REGS_ST =>
               if done = '1' then
                  seq_st <= SEQ_IDLE_ST;
                  if err = '0' then
                     regs_ok  <= '1';
                     regs_any <= '1';
                     read(regs_r(15), 1);
                     seq_st   <= SEQ_INSTR_ST;
                  end if;
               end if;

            when SEQ_INSTR_ST =>
               if done = '1' then
                  instr_ok <= not err;
                  seq_st   <= SEQ_IDLE_ST;
                  -- Then the window, at once
                  if page_on = '1' then
                     tick_r <= '1';
                  end if;
               end if;

            when SEQ_MEM_ST =>
               if done = '1' then
                  seq_st <= SEQ_IDLE_ST;
                  if err = '0' and mem_kill = '0' then
                     mem_ok  <= '1';
                     mem_any <= '1';
                  end if;
               end if;

         end case;

         -- A key waits for the next refresh. A stop notice, or the entry
         -- into Focus, refreshes at once, and R0-R15 are read again.
         if key_act /= ACT_NONE and key_act /= ACT_STICKY then
            act_r <= key_act;
         end if;
         if poke = '1' then
            act_r <= ACT_POKE;
         end if;
         if brk = '1' then
            act_r <= ACT_BREAK;
         end if;
         if ntc_valid = '1' and (ntc_tag = X"68" or ntc_tag = X"70" or ntc_tag = X"78") then
            regs_ok  <= '0';
            instr_ok <= '0';
            mem_ok   <= '0';
            tick_r   <= '1';
            dirty    <= '1';
            own_r    <= '0';
         end if;
         -- Row 28 changes with the state and the sticky setting, and the
         -- page with its keys
         if toggle_i = '1' or leave = '1' or key_act = ACT_STICKY or catch = '1' or pg_dirty = '1' then
            dirty <= '1';
         end if;
         if enter = '1' then
            regs_ok  <= '0';
            instr_ok <= '0';
            mem_ok   <= '0';
            tick_r   <= '1';
            act_r    <= ACT_NONE;
            dirty    <= '1';
         end if;
         -- A window moved, or the page shown again, is read again at once,
         -- and a read of the window before shows nothing
         if mem_move = '1' then
            mem_ok   <= '0';
            mem_any  <= '0';
            mem_kill <= '1';
            tick_r   <= '1';
            msg_k    <= C_MSG_NONE;
         end if;

         if rst_i = '1' then
            seq_st    <= SEQ_IDLE_ST;
            req_valid <= '0';
            act_r     <= ACT_NONE;
            tick_r    <= '0';
            refresh   <= 0;
            ctrl_r    <= (others => '0');
            reason_r  <= (others => '0');
            stop_r    <= (others => '0');
            link_ok   <= '0';
            regs_any  <= '0';
            regs_ok   <= '0';
            instr_ok  <= '0';
            own_r     <= '0';
            msg_r     <= '0';
            brk_en_r  <= (others => '0');
            brk_n     <= 0;
            mem_any   <= '0';
            mem_ok    <= '0';
            msg_k     <= C_MSG_NONE;
            dirty     <= '1';
         end if;
      end if;
   end process p_seq;

   -- The words of the window, as they arrive, and those of the page's
   -- cells, a cycle after stage 1 of the drawing
   p_mem : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if rd_valid = '1' and seq_st = SEQ_MEM_ST then
            mem_ram(rd_idx) <= rd_data;
         end if;
         mem_q <= mem_ram(s1_mem);
      end if;
   end process p_mem;

   -- A stop that the debugger did not cause: a breakpoint, or a halt
   catch <= '1' when ntc_valid = '1' and own_r = '0' and
                     (ntc_tag = X"68" or ntc_tag = X"70" or ntc_tag = X"78") else
            '0';

   ---------------------------------------------------------------------------
   -- The drawing
   ---------------------------------------------------------------------------

   st_code <= C_ST_NOLINK when link_ok = '0' else
              C_ST_HALTED when ctrl_r(1) = '1' else
              C_ST_HELD when ctrl_r(0) = '1' else
              C_ST_BRK when ctrl_r(4) = '1' and stop_r(8) = '1' else
              C_ST_PAUSED when ctrl_r(4) = '1' else
              C_ST_RUNNING;

   keys_k <= C_KEYS_PROG when state = STRIP_ST else
             C_KEYS_STRIP when sticky = '1' else
             C_KEYS_OFF;

   draw_start <= '1' when draw_cnt = C_ALL_LEN and dirty = '1' else '0';

   p_draw : process (clk_i)
      variable ch_v : t_byte;
   begin
      if rising_edge(clk_i) then
         -- Stage 1: the cell, of the strip or of a row of the page, and the
         -- word of the window it shows
         s1_valid <= '0';
         if draw_cnt /= C_ALL_LEN then
            s1_valid <= '1';
            s1_addr  <= draw_cnt;
            s1_row   <= draw_row;
            s1_mem   <= 0;
            if draw_row >= C_STRIP_ROW then
               s1_cell <= C_CELLS(draw_cnt - C_STRIP_ADDR);
            elsif draw_row = 0 then
               s1_cell <= C_HEAD_ROW(draw_col);
            elsif draw_row < C_FIELD_ROW then
               s1_cell <= C_MEM_ROW(draw_col);
               s1_mem  <= (draw_row - 1) * 8 + C_MEM_ROW(draw_col).idx mod 8;
            elsif draw_row = C_FIELD_ROW then
               s1_cell <= C_INPUT_ROW(draw_col);
            else
               s1_cell <= C_PKEYS_ROW(draw_col);
            end if;
            draw_cnt <= draw_cnt + 1;
            if draw_col = C_COLS - 1 then
               draw_col <= 0;
               if draw_row /= C_STRIP_ROW + C_STRIP_ROWS - 1 then
                  draw_row <= draw_row + 1;
               end if;
            else
               draw_col <= draw_col + 1;
            end if;
         elsif draw_start = '1' then
            -- The page too while it is shown
            draw_col <= 0;
            if page_on = '1' then
               draw_cnt <= 0;
               draw_row <= 0;
            else
               draw_cnt <= C_STRIP_ADDR;
               draw_row <= C_STRIP_ROW;
            end if;
         end if;

         -- Stage 2: the word it shows, or its character
         s2_valid <= s1_valid;
         s2_cell  <= s1_cell;
         s2_addr  <= s1_addr;
         s2_ch    <= s1_cell.ch;
         s2_nib   <= s1_cell.nib;
         s2_dim   <= '0';
         s2_cur   <= '0';
         s2_brk   <= '0';
         case s1_cell.kind is
            when CELL_HEX =>
               s2_shown <= '1';
               case s1_cell.idx is
                  when C_IDX_INSTR =>
                     s2_word  <= instr_r;
                     s2_shown <= instr_ok;
                  when C_IDX_PC =>
                     s2_word  <= regs_r(15);
                     s2_shown <= regs_ok;
                  when C_IDX_WINDOW =>
                     s2_word <= window;
                  when C_IDX_CURSOR =>
                     s2_word <= window + cur;
                  when C_IDX_ROW =>
                     s2_word <= window + s1_row * 8 - 8;
                  when C_IDX_BRK to C_IDX_BRK + C_BRKS - 1 =>
                     s2_word  <= brk_r(s1_cell.idx - C_IDX_BRK);
                     s2_shown <= brk_en_r(s1_cell.idx - C_IDX_BRK);
                  when others =>
                     s2_word  <= regs_r(s1_cell.idx mod 16);
                     s2_shown <= regs_any;
                     s2_dim   <= not regs_ok;
               end case;
            when CELL_MEM =>
               s2_shown <= mem_any;
               s2_dim   <= not mem_ok;
               if s1_mem = cur then
                  s2_cur <= '1';
               end if;
               for i in 0 to C_BRKS - 1 loop
                  if brk_en_r(i) = '1' and brk_r(i) = window + s1_mem then
                     s2_brk <= '1';
                  end if;
               end loop;
            when CELL_LABEL =>
               if field_addr = '1' then
                  s2_ch <= C_LABELS(8 + s1_cell.idx mod 8);
               else
                  s2_ch <= C_LABELS(s1_cell.idx mod 8);
               end if;
            when CELL_FIELD =>
               -- The digits typed, the first at the left
               s2_word  <= field;
               s2_shown <= '0';
               if s1_cell.idx < field_n then
                  s2_shown <= '1';
                  s2_nib   <= (field_n - 1 - s1_cell.idx) mod 8;
               end if;
            when CELL_MSG =>
               s2_ch <= C_MSGS(msg_k, s1_cell.idx mod 10);
               if msg_k = C_MSG_ERR and s1_cell.idx = 1 then
                  s2_ch <= hex_char(msg_code(7 downto 4));
               end if;
               if msg_k = C_MSG_ERR and s1_cell.idx = 2 then
                  s2_ch <= hex_char(msg_code(3 downto 0));
               end if;
            when CELL_FLAG =>
               s2_word  <= regs_r(14);
               s2_shown <= regs_any;
               s2_dim   <= not regs_ok;
            when CELL_STATE =>
               s2_ch <= C_NAMES(st_code, s1_cell.idx mod C_STATE_LEN);
               if st_code = C_ST_BRK and s1_cell.idx = C_BRK_DIG then
                  s2_ch <= hex_char(stop_r(3 downto 0));
               end if;
               if st_code = C_ST_HALTED and s1_cell.idx = C_HALT_DIG then
                  s2_ch <= hex_char(reason_r(3 downto 0));
               end if;
            when CELL_KEYS =>
               s2_ch <= C_KEYS(keys_k, s1_cell.idx);
            when CELL_FIX =>
               null;
         end case;

         -- Stage 3: the overlay's word
         ovl_we <= s2_valid;
         ch_v   := s2_ch;
         case s2_cell.kind is
            when CELL_HEX =>
               ch_v := X"2D";                               -- -
               if s2_shown = '1' then
                  ch_v := hex_char(nibble(s2_word, s2_nib));
               end if;
            when CELL_MEM =>
               ch_v := X"2D";                               -- -
               if s2_shown = '1' then
                  ch_v := hex_char(nibble(mem_q, s2_nib));
               end if;
            when CELL_FIELD =>
               ch_v := X"5F";                               -- _
               if s2_shown = '1' then
                  ch_v := hex_char(nibble(s2_word, s2_nib));
               end if;
            when CELL_FLAG =>
               ch_v := X"2E";                               -- .
               if s2_shown = '1' and s2_word(25 + s2_cell.idx mod 7) = '1' then
                  ch_v := to_byte(C_FLAG_CHAR(s2_cell.idx mod 7 + 1));
               end if;
            when others =>
               null;
         end case;
         ovl_addr <= std_logic_vector(to_unsigned(s2_addr, 12));
         if s2_cur = '1' and s2_brk = '1' then
            ovl_data <= C_CUR_BREAK & ch_v;
         elsif s2_cur = '1' then
            ovl_data <= C_CURSOR & ch_v;
         elsif s2_brk = '1' and s2_dim = '1' then
            ovl_data <= C_BREAK_DIM & ch_v;
         elsif s2_brk = '1' then
            ovl_data <= C_BREAK & ch_v;
         elsif s2_dim = '1' then
            ovl_data <= C_DIM & ch_v;
         else
            ovl_data <= C_COLOR & ch_v;
         end if;

         if rst_i = '1' then
            draw_cnt <= C_ALL_LEN;
            s1_valid <= '0';
            s2_valid <= '0';
            ovl_we   <= '0';
         end if;
      end if;
   end process p_draw;

end architecture synthesis;
