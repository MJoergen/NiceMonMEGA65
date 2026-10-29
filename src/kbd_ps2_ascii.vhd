-- Turns the scan codes of a PS/2 keyboard (kbd_ps2.vhd) into a stream of
-- ASCII bytes, as kbd_m65_ascii.vhd does for the MEGA65 keyboard: one byte for a
-- key, CR for Enter, the ANSI sequences ESC [ A to ESC [ D for the cursor
-- keys, and xterm's sequences for F1 to F12. The layout is US English.
--
-- THEORY OF OPERATION
-- The keyboard sends scan code set 2: a key's code when it is pressed, the
-- code again every so often while it is held, and F0 and the code when it is
-- released. Some keys have E0 before their code. So a held key repeats as
-- the keyboard repeats it, and the release gives nothing but the release of
-- a modifier. Bytes from 80 up other than E0, F0, and 83, which is F7, are
-- answers to commands or errors, and are ignored.
--
-- The byte of a key is in the tables below, one for codes without E0, with
-- and without SHIFT, and a few lines for those with E0. SHIFT (either) gives
-- the upper symbols of the keys; CAPS LOCK, which each press switches on or
-- off, gives the capital letters without SHIFT. CTRL (either) with a key
-- from @ to _ or ` to ~ gives the control code, so CTRL-C is 0x03; CTRL-@
-- would be NUL, which means no byte, so it gives nothing. Backspace and
-- Delete give DEL (0x7F), also with SHIFT or CTRL, as INST/DEL does on the
-- MEGA65. The keypad gives its digits and symbols, whatever Num Lock is,
-- and its Enter gives CR. F1 to F4 give ESC O P to ESC O S, and F5 to F12
-- ESC [, a number, and ~, as xterm sends them, also with SHIFT. Other keys
-- give nothing.
--
-- The bytes of a key wait in out_bytes until data_ready_i takes them. A key
-- that comes while they wait gives nothing, but the modifiers still change.
--
-- RESET
-- Synchronous to clk_i, by rst_i. It releases the modifiers, switches CAPS
-- LOCK off, and drops the bytes that wait.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;
   use ieee.numeric_std_unsigned.all;

entity kbd_ps2_ascii is
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;

      -- The scan codes, from kbd_ps2
      code_valid_i : in  std_logic;
      code_i       : in  std_logic_vector(7 downto 0);

      -- The ASCII bytes
      data_valid_o : out std_logic;
      data_ready_i : in  std_logic;
      data_o       : out std_logic_vector(7 downto 0)
   );
end entity kbd_ps2_ascii;

architecture synthesis of kbd_ps2_ascii is

   -- Scan codes
   constant C_EXT     : std_logic_vector(7 downto 0) := X"E0";
   constant C_RELEASE : std_logic_vector(7 downto 0) := X"F0";
   constant C_LSHIFT  : std_logic_vector(7 downto 0) := X"12";
   constant C_RSHIFT  : std_logic_vector(7 downto 0) := X"59";
   constant C_CTRL    : std_logic_vector(7 downto 0) := X"14"; -- either, E0 for the right
   constant C_CAPS    : std_logic_vector(7 downto 0) := X"58";
   constant C_F7_CODE : std_logic_vector(7 downto 0) := X"83"; -- the only key above 7F

   -- The cursor keys: ESC [ A, B, C, or D
   constant C_UP    : std_logic_vector(7 downto 0) := X"80";
   constant C_DOWN  : std_logic_vector(7 downto 0) := X"81";
   constant C_RIGHT : std_logic_vector(7 downto 0) := X"82";
   constant C_LEFT  : std_logic_vector(7 downto 0) := X"83";

   -- The function keys: F1 is 90, F12 is 9B
   constant C_F1  : std_logic_vector(7 downto 0) := X"90";
   constant C_F2  : std_logic_vector(7 downto 0) := X"91";
   constant C_F3  : std_logic_vector(7 downto 0) := X"92";
   constant C_F4  : std_logic_vector(7 downto 0) := X"93";
   constant C_F5  : std_logic_vector(7 downto 0) := X"94";
   constant C_F6  : std_logic_vector(7 downto 0) := X"95";
   constant C_F7  : std_logic_vector(7 downto 0) := X"96";
   constant C_F8  : std_logic_vector(7 downto 0) := X"97";
   constant C_F9  : std_logic_vector(7 downto 0) := X"98";
   constant C_F10 : std_logic_vector(7 downto 0) := X"99";
   constant C_F11 : std_logic_vector(7 downto 0) := X"9A";
   constant C_F12 : std_logic_vector(7 downto 0) := X"9B";

   -- What xterm sends after ESC for each function key: two bytes for F1 to
   -- F4, and four for the others
   type t_fkeys is array (0 to 15) of string(1 to 4);

   constant C_FKEYS : t_fkeys := (
      "OP  ", "OQ  ", "OR  ", "OS  ", "[15~", "[17~", "[18~", "[19~",
      "[20~", "[21~", "[23~", "[24~", others => "    ");

   type t_table is array (0 to 127) of std_logic_vector(7 downto 0);

   function chr(c : character) return std_logic_vector is
   begin
      return std_logic_vector(to_unsigned(character'pos(c), 8));
   end function chr;

   -- The byte of each code without E0, without SHIFT and with it. 0 is no
   -- byte.
   -- vsg_off constant_400 constant_012
   constant C_NORMAL : t_table := (
      16#01# => C_F9,      16#03# => C_F5,      16#04# => C_F3,      16#05# => C_F1,
      16#06# => C_F2,      16#07# => C_F12,     16#09# => C_F10,     16#0A# => C_F8,
      16#0B# => C_F6,      16#0C# => C_F4,      16#78# => C_F11,
      16#0D# => X"09",     16#0E# => chr('`'),  16#15# => chr('q'),  16#16# => chr('1'),
      16#1A# => chr('z'),  16#1B# => chr('s'),  16#1C# => chr('a'),  16#1D# => chr('w'),
      16#1E# => chr('2'),  16#21# => chr('c'),  16#22# => chr('x'),  16#23# => chr('d'),
      16#24# => chr('e'),  16#25# => chr('4'),  16#26# => chr('3'),  16#29# => chr(' '),
      16#2A# => chr('v'),  16#2B# => chr('f'),  16#2C# => chr('t'),  16#2D# => chr('r'),
      16#2E# => chr('5'),  16#31# => chr('n'),  16#32# => chr('b'),  16#33# => chr('h'),
      16#34# => chr('g'),  16#35# => chr('y'),  16#36# => chr('6'),  16#3A# => chr('m'),
      16#3B# => chr('j'),  16#3C# => chr('u'),  16#3D# => chr('7'),  16#3E# => chr('8'),
      16#41# => chr(','),  16#42# => chr('k'),  16#43# => chr('i'),  16#44# => chr('o'),
      16#45# => chr('0'),  16#46# => chr('9'),  16#49# => chr('.'),  16#4A# => chr('/'),
      16#4B# => chr('l'),  16#4C# => chr(';'),  16#4D# => chr('p'),  16#4E# => chr('-'),
      16#52# => chr('''),  16#54# => chr('['),  16#55# => chr('='),  16#5A# => X"0D",
      16#5B# => chr(']'),  16#5D# => chr('\'),  16#66# => X"7F",     16#69# => chr('1'),
      16#6B# => chr('4'),  16#6C# => chr('7'),  16#70# => chr('0'),  16#71# => chr('.'),
      16#72# => chr('2'),  16#73# => chr('5'),  16#74# => chr('6'),  16#75# => chr('8'),
      16#76# => X"1B",     16#79# => chr('+'),  16#7A# => chr('3'),  16#7B# => chr('-'),
      16#7C# => chr('*'),  16#7D# => chr('9'),
      others => X"00");

   constant C_SHIFTED : t_table := (
      16#01# => C_F9,      16#03# => C_F5,      16#04# => C_F3,      16#05# => C_F1,
      16#06# => C_F2,      16#07# => C_F12,     16#09# => C_F10,     16#0A# => C_F8,
      16#0B# => C_F6,      16#0C# => C_F4,      16#78# => C_F11,
      16#0D# => X"09",     16#0E# => chr('~'),  16#15# => chr('Q'),  16#16# => chr('!'),
      16#1A# => chr('Z'),  16#1B# => chr('S'),  16#1C# => chr('A'),  16#1D# => chr('W'),
      16#1E# => chr('@'),  16#21# => chr('C'),  16#22# => chr('X'),  16#23# => chr('D'),
      16#24# => chr('E'),  16#25# => chr('$'),  16#26# => chr('#'),  16#29# => chr(' '),
      16#2A# => chr('V'),  16#2B# => chr('F'),  16#2C# => chr('T'),  16#2D# => chr('R'),
      16#2E# => chr('%'),  16#31# => chr('N'),  16#32# => chr('B'),  16#33# => chr('H'),
      16#34# => chr('G'),  16#35# => chr('Y'),  16#36# => chr('^'),  16#3A# => chr('M'),
      16#3B# => chr('J'),  16#3C# => chr('U'),  16#3D# => chr('&'),  16#3E# => chr('*'),
      16#41# => chr('<'),  16#42# => chr('K'),  16#43# => chr('I'),  16#44# => chr('O'),
      16#45# => chr(')'),  16#46# => chr('('),  16#49# => chr('>'),  16#4A# => chr('?'),
      16#4B# => chr('L'),  16#4C# => chr(':'),  16#4D# => chr('P'),  16#4E# => chr('_'),
      16#52# => chr('"'),  16#54# => chr('{'),  16#55# => chr('+'),  16#5A# => X"0D",
      16#5B# => chr('}'),  16#5D# => chr('|'),  16#66# => X"7F",     16#69# => chr('1'),
      16#6B# => chr('4'),  16#6C# => chr('7'),  16#70# => chr('0'),  16#71# => chr('.'),
      16#72# => chr('2'),  16#73# => chr('5'),  16#74# => chr('6'),  16#75# => chr('8'),
      16#76# => X"1B",     16#79# => chr('+'),  16#7A# => chr('3'),  16#7B# => chr('-'),
      16#7C# => chr('*'),  16#7D# => chr('9'),
      others => X"00");
   -- vsg_on

   -- The byte of a code with E0
   function ext_byte(code : std_logic_vector(7 downto 0)) return std_logic_vector is
   begin
      case code is
         when X"75"  => return C_UP;
         when X"72"  => return C_DOWN;
         when X"74"  => return C_RIGHT;
         when X"6B"  => return C_LEFT;
         when X"71"  => return X"7F";     -- Delete
         when X"4A"  => return chr('/');  -- the keypad's /
         when X"5A"  => return X"0D";     -- the keypad's Enter
         when others => return X"00";
      end case;
   end function ext_byte;

   -- The bytes that a byte of the tables stands for, the first in bits
   -- 39..32: itself, ESC [ and A to D for a cursor key, or ESC and the
   -- bytes of C_FKEYS for a function key
   function seq_bytes(byte : std_logic_vector(7 downto 0)) return std_logic_vector is
      variable fkey_v : string(1 to 4);
   begin
      if byte(7) = '0' then
         return byte & X"00000000";
      elsif byte(4) = '0' then
         return X"1B" & chr('[') & (chr('A') + byte(1 downto 0)) & X"0000";
      else
         fkey_v := C_FKEYS(to_integer(byte(3 downto 0)));
         return X"1B" & chr(fkey_v(1)) & chr(fkey_v(2)) & chr(fkey_v(3)) & chr(fkey_v(4));
      end if;
   end function seq_bytes;

   -- How many bytes seq_bytes gives
   function seq_len(byte : std_logic_vector(7 downto 0)) return natural is
   begin
      if byte(7) = '0' then
         return 1;
      elsif byte(4) = '0' or byte(3 downto 2) = "00" then
         return 3;
      else
         return 5;
      end if;
   end function seq_len;

   -- The prefixes before the code: E0, and F0, the break code
   signal ext : std_logic := '0';
   signal brk : std_logic := '0';

   -- The modifiers. ctrl has a bit for each CTRL key, left in bit 0.
   signal lshift    : std_logic := '0';
   signal rshift    : std_logic := '0';
   signal ctrl      : std_logic_vector(1 downto 0) := "00";
   signal caps      : std_logic := '0';
   signal caps_held : std_logic := '0';

   -- The bytes to send: the first is in bits 39..32
   signal out_bytes : std_logic_vector(39 downto 0) := (others => '0');
   signal out_cnt   : natural range 0 to 5 := 0;

begin

   data_valid_o <= '1' when out_cnt /= 0 else '0';
   data_o       <= out_bytes(39 downto 32);

   p_decode : process (clk_i)
      variable byte_v : std_logic_vector(7 downto 0);
   begin
      if rising_edge(clk_i) then
         if out_cnt /= 0 and data_ready_i = '1' then
            out_bytes <= out_bytes(31 downto 0) & X"00";
            out_cnt   <= out_cnt - 1;
         end if;

         if code_valid_i = '1' then
            if code_i = C_EXT then
               ext <= '1';
            elsif code_i = C_RELEASE then
               brk <= '1';
            else
               ext     <= '0';
               brk <= '0';

               -- The modifiers
               if ext = '0' and code_i = C_LSHIFT then
                  lshift <= not brk;
               end if;
               if ext = '0' and code_i = C_RSHIFT then
                  rshift <= not brk;
               end if;
               if ext = '0' and code_i = C_CTRL then
                  ctrl(0) <= not brk;
               end if;
               if ext = '1' and code_i = C_CTRL then
                  ctrl(1) <= not brk;
               end if;
               if ext = '0' and code_i = C_CAPS then
                  -- A press switches it, but not the repeats while held
                  caps_held <= not brk;
                  if brk = '0' and caps_held = '0' then
                     caps <= not caps;
                  end if;
               end if;

               -- The byte of the key
               if ext = '0' and code_i = C_F7_CODE then
                  byte_v := C_F7;
               elsif code_i(7) = '1' then
                  byte_v := X"00";
               elsif ext = '1' then
                  byte_v := ext_byte(code_i);
               elsif lshift = '1' or rshift = '1' then
                  byte_v := C_SHIFTED(to_integer(code_i));
               else
                  byte_v := C_NORMAL(to_integer(code_i));
                  if caps = '1' and byte_v >= chr('a') and byte_v <= chr('z') then
                     byte_v(5) := '0';
                  end if;
               end if;
               if ctrl /= "00" and byte_v(7 downto 6) /= "00" and byte_v(7) = '0' and
                  byte_v /= X"7F" then
                  byte_v(7 downto 5) := "000";
               end if;

               if brk = '0' and byte_v /= X"00" and out_cnt = 0 then
                  out_bytes <= seq_bytes(byte_v);
                  out_cnt   <= seq_len(byte_v);
               end if;
            end if;
         end if;

         if rst_i = '1' then
            ext       <= '0';
            brk   <= '0';
            lshift    <= '0';
            rshift    <= '0';
            ctrl      <= "00";
            caps      <= '0';
            caps_held <= '0';
            out_cnt   <= 0;
         end if;
      end if;
   end process p_decode;

end architecture synthesis;
