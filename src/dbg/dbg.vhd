-- The on-board debugger (doc/DEBUGGER.md): a strip of 4 text rows under the
-- program's screen, shown and taking the keyboard when the board's toggle
-- key is pressed.
--
-- THEORY OF OPERATION
-- This is stage 1 of the design note: the overlay, with no link. The
-- debugger is Off after reset, and the toggle pulse, toggle_i, takes it to
-- Focus and back. In Focus the strip is shown (strip_o) and the keyboard is
-- the debugger's (focus_o): system.vhd then gives the keyboard's bytes to
-- the debugger instead of the core's console FIFO, and the debugger takes
-- and drops them. kbd_ready_o is always '1', as a PS/2 keyboard cannot wait.
--
-- The strip is rows 25 to 28 of the overlay of text.vhd, the words 2000 to
-- 2319, addressed row * 80 + column. After reset the debugger writes its
-- fixed text there, one word a cycle, in white on dark blue: the labels of
-- the registers, a row that says that there is no link yet, and the keys,
-- with the board's toggle key, G_TOGGLE_KEY, at the end. The overlay keeps
-- the text, so it is written once, and strip_o only shows or hides it. The
-- page, rows 0 to 24, is not written, and page_o is '0'.
--
-- RESET
-- Synchronous to clk_i, by rst_i. The debugger is Off, and writes the strip
-- again.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;
   use ieee.numeric_std_unsigned.all;

entity dbg is
   generic (
      -- The board's key that toggles the debugger, named in row 28
      G_TOGGLE_KEY : string := "MEGA+HELP"
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

   constant C_COLS       : natural := 80;
   constant C_STRIP_ROW  : natural := 25;
   constant C_STRIP_ROWS : natural := 4;
   constant C_STRIP_LEN  : natural := C_STRIP_ROWS * C_COLS;

   -- White on dark blue: the background in bits 31..20, the foreground in
   -- bits 19..8, as in a screen word
   constant C_COLOR : std_logic_vector(23 downto 0) := X"004FFF";

   type t_chars is array (0 to C_STRIP_LEN - 1) of std_logic_vector(7 downto 0);

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

   function chars(s : string) return t_chars is
      variable res_v : t_chars;
   begin
      for i in 0 to C_STRIP_LEN - 1 loop
         res_v(i) := to_slv(character'pos(s(s'low + i)), 8);
      end loop;
      return res_v;
   end function chars;

   constant C_DASHES : string := "-------- -------- -------- -------- " &
                                 "-------- -------- -------- --------";

   constant C_STRIP : t_chars := chars(
                                       row(" R0-7   " & C_DASHES) &
                                       row(" R8-15  " & C_DASHES) &
                                       row(" NO LINK") &
                                       row(" F1 step   F3 go   F5 pause   F7 hold   F9 restart   F11 page   " &
                                             G_TOGGLE_KEY & " back"));

   type t_state is (OFF_ST, FOCUS_ST);

   signal state : t_state := OFF_ST;

   -- The word of the strip to write next, C_STRIP_LEN when it is written
   signal draw_cnt : natural range 0 to C_STRIP_LEN := 0;

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


   p_draw : process (clk_i)
   begin
      if rising_edge(clk_i) then
         ovl_we <= '0';
         if draw_cnt /= C_STRIP_LEN then
            ovl_we   <= '1';
            ovl_addr <= std_logic_vector(to_unsigned(C_STRIP_ROW * C_COLS + draw_cnt, 12));
            ovl_data <= C_COLOR & C_STRIP(draw_cnt);
            draw_cnt <= draw_cnt + 1;
         end if;

         if rst_i = '1' then
            ovl_we   <= '0';
            draw_cnt <= 0;
         end if;
      end if;
   end process p_draw;

end architecture synthesis;
