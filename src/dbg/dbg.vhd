-- The on-board debugger (doc/DEBUGGER.md): a strip of 4 text rows under the
-- program's screen, shown and taking the keyboard when the board's toggle
-- key is pressed, which shows the core's state and registers and runs it
-- with single keys.
--
-- THEORY OF OPERATION
-- This is stage 3 of the design note: the live strip and the core keys.
-- The debugger is Off after reset, and the toggle pulse, toggle_i, takes it
-- to Focus and back. In Focus the strip is shown (strip_o), the keyboard is
-- the debugger's (focus_o), and so is the debug link (on_o): nicemon.vhd
-- then gives the link's byte streams to the host in hardware here
-- (dbg_host.vhd) instead of the UART or TCP. on_o stays '1' after Focus
-- is left until the last request has ended, so that no packet is cut.
-- kbd_ready_o is always '1', as a PS/2 keyboard cannot wait.
--
-- p_seq drives the link, one request at a time. In Focus, about 60 times a
-- second, and at once after a key, a stop notice (`p`, `x`, or `h`), or
-- the entry into Focus, it reads the debug registers 0xFFFFFFF0-F6 in one
-- request: the control register, the halt reason, and the stop register.
-- A key then writes the control register, with bit 3, the ROM, as it
-- reads, and the registers are read again. When the core is paused or
-- has halted, and R0-R15 have not been read since the stop, it reads them,
-- and then the word at R15. A request that gets no answer shows NO LINK.
--
-- p_kbd turns the keyboard's bytes into the keys of DEBUGGER.md: F1 or s
-- steps a paused core, F3 or g goes on, F5 or p pauses a running core, F7
-- or h holds, and F9 or r restarts: hold, then start. F1 and F3 are xterm's
-- ESC O P and ESC O R, and F5, F7, and F9 ESC [ 15 ~, ESC [ 18 ~, and
-- ESC [ 20 ~. A key that does not fit the core's state does nothing: go
-- on and pause would start a held core.
--
-- The strip is rows 25 to 28 of the overlay of text.vhd, the words 2000 to
-- 2319, addressed row * 80 + column. C_CELLS says what each word shows: a
-- fixed character, a hex digit of a word that the debugger read, a
-- character of the state's name, or a flag of SR (R14). p_draw writes the
-- whole strip, one word a cycle, through a pipeline of three stages, after
-- reset and whenever what it shows has changed. R0-R15 are dimmed while
-- they are not the values of the current stop: until nice_cpu V1.2 the
-- link has no registers while the core runs (DEBUG.md §6). The page, rows
-- 0 to 24, is not written, and page_o is '0'.
--
-- RESET
-- Synchronous to clk_i, by rst_i. The debugger is Off, knows nothing of
-- the core, and draws the strip again.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity dbg is
   generic (
      G_CLOCK_HZ   : positive := 100_000_000;
      -- The board's key that toggles the debugger, named in row 28
      G_TOGGLE_KEY : string   := "MEGA+HELP"
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
      focus_o     : out std_logic
   );
end entity dbg;

architecture synthesis of dbg is

   subtype t_byte is std_logic_vector(7 downto 0);

   subtype t_word is std_logic_vector(31 downto 0);

   constant C_COLS       : natural := 80;
   constant C_STRIP_ROW  : natural := 25;
   constant C_STRIP_ROWS : natural := 4;
   constant C_STRIP_LEN  : natural := C_STRIP_ROWS * C_COLS;

   -- White on dark blue, and gray on dark blue for stale values: the
   -- background in bits 31..20, the foreground in bits 19..8, as in a
   -- screen word
   constant C_COLOR : std_logic_vector(23 downto 0) := X"004FFF";
   constant C_DIM   : std_logic_vector(23 downto 0) := X"004888";

   -- The refresh, about 60 times a second, and the host's timeout, the
   -- link's 100 ms (DEBUG.md §5)
   constant C_REFRESH : positive := G_CLOCK_HZ / 60;
   constant C_TIMEOUT : positive := G_CLOCK_HZ / 10;

   constant C_REGS : t_word := X"FFFFFFE0";
   constant C_CTRL : t_word := X"FFFFFFF0";
   -- The debug registers read at each refresh: the control register up to
   -- the stop register
   constant C_CTRL_N : natural := 7;

   type t_words is array (0 to 15) of t_word;

   type t_act is (ACT_NONE, ACT_STEP, ACT_GO, ACT_PAUSE, ACT_HOLD, ACT_RESTART);

   type t_state is (OFF_ST, FOCUS_ST);

   type t_kbd_st is (KBD_IDLE_ST, KBD_ESC_ST, KBD_SS3_ST, KBD_CSI_ST);

   type t_seq_st is (SEQ_IDLE_ST, SEQ_CTRL_ST, SEQ_WRITE_ST, SEQ_START_ST, SEQ_REGS_ST, SEQ_INSTR_ST);

   ---------------------------------------------------------------------------
   -- The cells of the strip
   ---------------------------------------------------------------------------

   -- What a word of the strip shows: a fixed character; hex digit nib of
   -- word idx, R0-R15 for 0 to 15, the word at the PC for 16, and the PC for
   -- 17; character idx of the state's name; or flag idx of SR, X to I
   type t_kind is (CELL_FIX, CELL_HEX, CELL_STATE, CELL_FLAG);

   type t_cell is record
      kind : t_kind;
      idx  : natural range 0 to 17;
      nib  : natural range 0 to 7;
      ch   : t_byte;
   end record t_cell;

   type t_cells is array (0 to C_STRIP_LEN - 1) of t_cell;

   constant C_IDX_INSTR : natural := 16;
   constant C_IDX_PC    : natural := 17;

   -- The columns of row 27: the state's name, the PC, the word at the PC,
   -- and the flags, every second column
   constant C_COL_STATE : natural := 1;
   constant C_COL_PC    : natural := 10;
   constant C_COL_INSTR : natural := 20;
   constant C_COL_FLAGS : natural := 30;
   constant C_STATE_LEN : natural := 9;

   function to_byte(c : character) return t_byte is
   begin
      return to_slv(character'pos(c), 8);
   end function to_byte;

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
      constant C_KEYS : string := row(" F1 step   F3 go   F5 pause   F7 hold   F9 restart   F11 page   " &
                                      G_TOGGLE_KEY & " back");
      constant C_FIX  : t_cell := (kind => CELL_FIX, idx => 0, nib => 0, ch => to_byte(' '));
      variable res_v  : t_cells := (others => C_FIX);
      variable c_v    : natural;
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
               res_v(r * C_COLS + c) := (kind => CELL_HEX, idx => r * 8 + (c - 8) / 9,
                                         nib => 7 - (c - 8) mod 9, ch => to_byte(' '));
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
         res_v(3 * C_COLS + c).ch := to_byte(C_KEYS(c + 1));
      end loop;
      return res_v;
   end function cells;

   constant C_CELLS : t_cells := cells;

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
      type t_strings is array (0 to 5) of string(1 to C_STATE_LEN);
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

   function hex_char(n : std_logic_vector(3 downto 0)) return t_byte is
   begin
      if n < 10 then
         return X"3" & n;
      else
         return ("0000" & n) + X"37";
      end if;
   end function hex_char;

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

   signal state : t_state := OFF_ST;
   signal enter : std_logic;

   signal kbd_st  : t_kbd_st := KBD_IDLE_ST;
   signal kbd_num : natural range 0 to 99;
   signal key_act : t_act    := ACT_NONE;

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
   signal rd_idx    : natural range 0 to 15;
   signal restart_r : std_logic;

   -- What the debugger knows of the core
   signal ctrl_r   : t_word := (others => '0');
   signal reason_r : t_byte := (others => '0');
   signal stop_r   : std_logic_vector(8 downto 0) := (others => '0');
   signal regs_r   : t_words := (others => (others => '0'));
   signal instr_r  : t_word := (others => '0');
   signal link_ok  : std_logic := '0';                   -- The last refresh had an answer
   signal regs_any : std_logic := '0';                   -- R0-R15 were read once
   signal regs_ok  : std_logic := '0';                   -- ... since the current stop
   signal instr_ok : std_logic := '0';                   -- The word at the PC too
   signal st_code  : natural range 0 to 5;

   -- The drawing: a pass over the strip after each change
   signal dirty      : std_logic := '1';
   signal draw_start : std_logic;
   signal draw_cnt   : natural range 0 to C_STRIP_LEN := C_STRIP_LEN;
   signal s1_valid   : std_logic := '0';
   signal s1_cell    : t_cell;
   signal s1_addr    : natural range 0 to C_STRIP_LEN - 1;
   signal s2_valid   : std_logic := '0';
   signal s2_cell    : t_cell;
   signal s2_addr    : natural range 0 to C_STRIP_LEN - 1;
   signal s2_word    : t_word;
   signal s2_shown   : std_logic;                        -- The word is known
   signal s2_dim     : std_logic;
   signal s2_ch      : t_byte;                           -- A fixed or state character

   signal ovl_we   : std_logic := '0';
   signal ovl_addr : std_logic_vector(11 downto 0) := (others => '0');
   signal ovl_data : std_logic_vector(31 downto 0) := (others => '0');

begin

   kbd_ready_o <= '1';

   ovl_we_o   <= ovl_we;
   ovl_addr_o <= ovl_addr;
   ovl_data_o <= ovl_data;

   strip_o <= '1' when state = FOCUS_ST else '0';
   page_o  <= '0';
   focus_o <= '1' when state = FOCUS_ST else '0';
   on_o    <= '1' when state = FOCUS_ST or seq_st /= SEQ_IDLE_ST or req_valid = '1' or req_ready = '0' else
              '0';

   enter <= '1' when toggle_i = '1' and state = OFF_ST else '0';

   p_state : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if toggle_i = '1' then
            case state is
               when OFF_ST   => state <= FOCUS_ST;
               when FOCUS_ST => state <= OFF_ST;
            end case;
         end if;

         if rst_i = '1' then
            state <= OFF_ST;
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
         if kbd_valid_i = '1' and state = FOCUS_ST then
            case kbd_st is

               when KBD_IDLE_ST =>
                  case kbd_data_i is
                     when X"1B"  => kbd_st  <= KBD_ESC_ST;
                     when X"73"  => key_act <= ACT_STEP;    -- s
                     when X"67"  => key_act <= ACT_GO;      -- g
                     when X"70"  => key_act <= ACT_PAUSE;   -- p
                     when X"68"  => key_act <= ACT_HOLD;    -- h
                     when X"72"  => key_act <= ACT_RESTART; -- r
                     when others => null;
                  end case;

               when KBD_ESC_ST =>
                  kbd_num <= 0;
                  case kbd_data_i is
                     when X"4F"  => kbd_st <= KBD_SS3_ST;   -- O
                     when X"5B"  => kbd_st <= KBD_CSI_ST;   -- [
                     when X"1B"  => kbd_st <= KBD_ESC_ST;
                     when others => kbd_st <= KBD_IDLE_ST;
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
                     if kbd_data_i = X"7E" then             -- ~
                        case kbd_num is
                           when 15     => key_act <= ACT_PAUSE;   -- F5
                           when 18     => key_act <= ACT_HOLD;    -- F7
                           when 20     => key_act <= ACT_RESTART; -- F9
                           when others => null;
                        end case;
                     end if;
                  end if;

            end case;
         end if;

         if rst_i = '1' then
            kbd_st  <= KBD_IDLE_ST;
            key_act <= ACT_NONE;
         end if;
      end if;
   end process p_kbd;

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
         err_code_o  => open,
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

      procedure read(addr : t_word;
                     n    : natural) is
      begin
         req_valid <= '1';
         req_we    <= '0';
         req_addr  <= addr;
         req_n     <= to_slv(n, 16);
         rd_idx    <= 0;
      end procedure read;

      procedure write(data : t_word) is
      begin
         req_valid <= '1';
         req_we    <= '1';
         req_addr  <= C_CTRL;
         req_n     <= X"0001";
         req_data  <= data;
      end procedure write;

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
            if rd_idx /= 15 then
               rd_idx <= rd_idx + 1;
            end if;
            case seq_st is
               when SEQ_CTRL_ST =>
                  case rd_idx is
                     when 0      => ctrl_r   <= rd_data;
                     when 1      => reason_r <= rd_data(7 downto 0);
                     when 6      => stop_r   <= rd_data(8 downto 0);
                     when others => null;
                  end case;
               when SEQ_REGS_ST  => regs_r(rd_idx) <= rd_data;
               when SEQ_INSTR_ST => instr_r        <= rd_data;
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
               if state = FOCUS_ST and req_valid = '0' and (tick_r = '1' or act_r /= ACT_NONE) then
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
                        when ACT_NONE =>
                           write_v := false;
                     end case;
                     act_r <= ACT_NONE;

                     if write_v then
                        write(data_v);
                        regs_ok  <= '0';
                        instr_ok <= '0';
                        seq_st   <= SEQ_WRITE_ST;
                     elsif (ctrl_r(4) = '1' or ctrl_r(1) = '1') and regs_ok = '0' then
                        read(C_REGS, 16);
                        seq_st <= SEQ_REGS_ST;
                     end if;
                  end if;
               end if;

            -- The write of a key, and the start of a restart, then the
            -- registers again
            when SEQ_WRITE_ST =>
               if done = '1' then
                  if restart_r = '1' then
                     restart_r <= '0';
                     write(rom_v);
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
               end if;

         end case;

         -- A key waits for the next refresh. A stop notice, or the entry
         -- into Focus, refreshes at once, and R0-R15 are read again.
         if key_act /= ACT_NONE then
            act_r <= key_act;
         end if;
         if ntc_valid = '1' and (ntc_tag = X"68" or ntc_tag = X"70" or ntc_tag = X"78") then
            regs_ok  <= '0';
            instr_ok <= '0';
            tick_r   <= '1';
            dirty    <= '1';
         end if;
         if enter = '1' then
            regs_ok  <= '0';
            instr_ok <= '0';
            tick_r   <= '1';
            act_r    <= ACT_NONE;
            dirty    <= '1';
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
            dirty     <= '1';
         end if;
      end if;
   end process p_seq;

   ---------------------------------------------------------------------------
   -- The drawing
   ---------------------------------------------------------------------------

   st_code <= C_ST_NOLINK when link_ok = '0' else
              C_ST_HALTED when ctrl_r(1) = '1' else
              C_ST_HELD when ctrl_r(0) = '1' else
              C_ST_BRK when ctrl_r(4) = '1' and stop_r(8) = '1' else
              C_ST_PAUSED when ctrl_r(4) = '1' else
              C_ST_RUNNING;

   draw_start <= '1' when draw_cnt = C_STRIP_LEN and dirty = '1' else '0';

   p_draw : process (clk_i)
      variable ch_v : t_byte;
   begin
      if rising_edge(clk_i) then
         -- Stage 1: the cell
         s1_valid <= '0';
         if draw_cnt /= C_STRIP_LEN then
            s1_valid <= '1';
            s1_cell  <= C_CELLS(draw_cnt);
            s1_addr  <= draw_cnt;
            draw_cnt <= draw_cnt + 1;
         elsif draw_start = '1' then
            draw_cnt <= 0;
         end if;

         -- Stage 2: the word it shows, or the character of the state
         s2_valid <= s1_valid;
         s2_cell  <= s1_cell;
         s2_addr  <= s1_addr;
         s2_ch    <= s1_cell.ch;
         s2_dim   <= '0';
         case s1_cell.kind is
            when CELL_HEX =>
               if s1_cell.idx = C_IDX_INSTR then
                  s2_word  <= instr_r;
                  s2_shown <= instr_ok;
               elsif s1_cell.idx = C_IDX_PC then
                  s2_word  <= regs_r(15);
                  s2_shown <= regs_ok;
               else
                  s2_word  <= regs_r(s1_cell.idx mod 16);
                  s2_shown <= regs_any;
                  s2_dim   <= not regs_ok;
               end if;
            when CELL_FLAG =>
               s2_word  <= regs_r(14);
               s2_shown <= regs_any;
               s2_dim   <= not regs_ok;
            when CELL_STATE =>
               s2_ch <= C_NAMES(st_code, s1_cell.idx);
               if st_code = C_ST_BRK and s1_cell.idx = C_BRK_DIG then
                  s2_ch <= hex_char(stop_r(3 downto 0));
               end if;
               if st_code = C_ST_HALTED and s1_cell.idx = C_HALT_DIG then
                  s2_ch <= hex_char(reason_r(3 downto 0));
               end if;
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
                  ch_v := hex_char(nibble(s2_word, s2_cell.nib));
               end if;
            when CELL_FLAG =>
               ch_v := X"2E";                               -- .
               if s2_shown = '1' and s2_word(25 + s2_cell.idx) = '1' then
                  ch_v := to_byte(C_FLAG_CHAR(s2_cell.idx + 1));
               end if;
            when others =>
               null;
         end case;
         ovl_addr <= to_slv(C_STRIP_ROW * C_COLS + s2_addr, 12);
         if s2_dim = '1' then
            ovl_data <= C_DIM & ch_v;
         else
            ovl_data <= C_COLOR & ch_v;
         end if;

         if rst_i = '1' then
            draw_cnt <= C_STRIP_LEN;
            s1_valid <= '0';
            s2_valid <= '0';
            ovl_we   <= '0';
         end if;
      end if;
   end process p_draw;

end architecture synthesis;
