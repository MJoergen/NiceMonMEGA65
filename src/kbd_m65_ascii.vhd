-- Turns the keys of the MEGA65 keyboard (kbd_m65.vhd) into a stream of ASCII
-- bytes, as a terminal sends them: one byte for a key, CR for RETURN, the
-- ANSI sequences ESC [ A to ESC [ D for the cursor keys, and xterm's
-- sequences for the function keys. A key that is held repeats after half a
-- second, 20 times a second.
--
-- THEORY OF OPERATION
-- Every 5 ms the keys are sampled. A key counts as pressed when it was
-- pressed in this sample and the one before, which filters out bounces and
-- glitches. After a sample, the keys are walked one per clock cycle, and each
-- key that was not pressed in the last walk and is now gives its byte. The
-- walk waits while a byte has not been taken by data_ready_i, so that byte
-- is not lost, but a key pressed and released meanwhile is.
--
-- The byte of a key is in the table below. SHIFT (either) or CAPS LOCK gives
-- the capital letters; SHIFT also gives the symbols above the digits and
-- others, as on the key caps where they are ASCII. CTRL with a key from @ to
-- _ or ` to ~ gives the control code, so CTRL-C is 0x03. CTRL-@ would be
-- NUL, which cannot be carried (0 means no byte), so that key sends nothing.
-- DEL stays DEL with CTRL. Keys without an ASCII meaning give nothing.
-- Where the key caps have no ASCII symbol:
--   £ is \, and SHIFT-£ is |      (\ is the PETSCII code of £)
--   ↑ is ^, and SHIFT-↑ is ~      (as in PETSCII)
--   ← is _, and SHIFT-← is `      (as in PETSCII)
--   SHIFT-0 is {, and SHIFT-= is }, SHIFT-: is [, and SHIFT-; is ]
--   INST/DEL is DEL (0x7F), also with SHIFT, RUN/STOP is CTRL-C (0x03)
-- F1, F3, F5, F7, F9, and F11 give xterm's sequences for those keys, and
-- with SHIFT those of F2 to F12: ESC O P to ESC O S for F1 to F4, and ESC [,
-- a number, and ~ for the others. F13 gives nothing.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity kbd_m65_ascii is
   generic (
      G_CLOCK_HZ : natural
   );
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;
      matrix_i     : in  std_logic_vector(79 downto 0);
      data_valid_o : out std_logic;
      data_ready_i : in  std_logic;
      data_o       : out std_logic_vector(7 downto 0)
   );
end entity kbd_m65_ascii;

architecture synthesis of kbd_m65_ascii is

   constant C_NUM_KEYS : natural := 80;

   -- Clock cycles from one sample to the next, and the repeat, in samples
   constant C_SAMPLE       : natural := G_CLOCK_HZ / 200;
   constant C_REPEAT_DELAY : natural := 100; -- 500 ms
   constant C_REPEAT_RATE  : natural := 10;  -- 50 ms

   -- Key numbers
   constant C_LSHIFT : natural := 15;
   constant C_RSHIFT : natural := 52;
   constant C_CTRL   : natural := 58;
   constant C_CAPS   : natural := 72;

   -- The cursor keys in the table: ESC [ A, B, C, or D
   constant C_UP    : std_logic_vector(7 downto 0) := X"80";
   constant C_DOWN  : std_logic_vector(7 downto 0) := X"81";
   constant C_RIGHT : std_logic_vector(7 downto 0) := X"82";
   constant C_LEFT  : std_logic_vector(7 downto 0) := X"83";

   -- The function keys in the table: F1 is 90, F12 is 9B
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

   type t_table is array (0 to C_NUM_KEYS - 1) of std_logic_vector(7 downto 0);

   function chr(c : character) return std_logic_vector is
   begin
      return to_slv(character'pos(c), 8);
   end function chr;

   -- The byte of each key without SHIFT, and with it. 0 is no byte.
   -- vsg_off constant_400 constant_012
   constant C_NORMAL : t_table := (
       0 => X"7F",       1 => X"0D",       2 => C_RIGHT,     3 => C_F7,
       4 => C_F1,        5 => C_F3,        6 => C_F5,        7 => C_DOWN,
       8 => chr('3'),    9 => chr('w'),   10 => chr('a'),   11 => chr('4'),
      12 => chr('z'),   13 => chr('s'),   14 => chr('e'),   16 => chr('5'),
      17 => chr('r'),   18 => chr('d'),   19 => chr('6'),   20 => chr('c'),
      21 => chr('f'),   22 => chr('t'),   23 => chr('x'),   24 => chr('7'),
      25 => chr('y'),   26 => chr('g'),   27 => chr('8'),   28 => chr('b'),
      29 => chr('h'),   30 => chr('u'),   31 => chr('v'),   32 => chr('9'),
      33 => chr('i'),   34 => chr('j'),   35 => chr('0'),   36 => chr('m'),
      37 => chr('k'),   38 => chr('o'),   39 => chr('n'),   40 => chr('+'),
      41 => chr('p'),   42 => chr('l'),   43 => chr('-'),   44 => chr('.'),
      45 => chr(':'),   46 => chr('@'),   47 => chr(','),   48 => chr('\'),
      49 => chr('*'),   50 => chr(';'),   53 => chr('='),   54 => chr('^'),
      55 => chr('/'),   56 => chr('1'),   57 => chr('_'),   59 => chr('2'),
      60 => chr(' '),   62 => chr('q'),   63 => X"03",      65 => X"09",
      68 => C_F9,       69 => C_F11,      71 => X"1B",      73 => C_UP,
      74 => C_LEFT,
      others => X"00");

   constant C_SHIFTED : t_table := (
       0 => X"7F",       1 => X"0D",       2 => C_LEFT,      3 => C_F8,
       4 => C_F2,        5 => C_F4,        6 => C_F6,        7 => C_UP,
       8 => chr('#'),    9 => chr('W'),   10 => chr('A'),   11 => chr('$'),
      12 => chr('Z'),   13 => chr('S'),   14 => chr('E'),   16 => chr('%'),
      17 => chr('R'),   18 => chr('D'),   19 => chr('&'),   20 => chr('C'),
      21 => chr('F'),   22 => chr('T'),   23 => chr('X'),   24 => chr('''),
      25 => chr('Y'),   26 => chr('G'),   27 => chr('('),   28 => chr('B'),
      29 => chr('H'),   30 => chr('U'),   31 => chr('V'),   32 => chr(')'),
      33 => chr('I'),   34 => chr('J'),   35 => chr('{'),   36 => chr('M'),
      37 => chr('K'),   38 => chr('O'),   39 => chr('N'),   40 => chr('+'),
      41 => chr('P'),   42 => chr('L'),   43 => chr('-'),   44 => chr('>'),
      45 => chr('['),   46 => chr('@'),   47 => chr('<'),   48 => chr('|'),
      49 => chr('*'),   50 => chr(']'),   53 => chr('}'),   54 => chr('~'),
      55 => chr('?'),   56 => chr('!'),   57 => chr('`'),   59 => chr('"'),
      60 => chr(' '),   62 => chr('Q'),   63 => X"03",      65 => X"09",
      68 => C_F10,      69 => C_F12,      71 => X"1B",      73 => C_UP,
      74 => C_LEFT,
      others => X"00");
   -- vsg_on

   -- The byte of a key, with the modifiers of keys
   function key_byte(key : natural; keys : std_logic_vector) return std_logic_vector is
      variable res_v : std_logic_vector(7 downto 0);
   begin
      if keys(C_LSHIFT) = '1' or keys(C_RSHIFT) = '1' then
         res_v := C_SHIFTED(key);
      else
         res_v := C_NORMAL(key);
         if keys(C_CAPS) = '1' and res_v >= chr('a') and res_v <= chr('z') then
            res_v(5) := '0';
         end if;
      end if;
      if keys(C_CTRL) = '1' and res_v(7 downto 6) /= "00" and res_v(7) = '0' and
         res_v /= X"7F" then
         res_v(7 downto 5) := "000";
      end if;
      return res_v;
   end function key_byte;

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

   signal sample_cnt : natural range 0 to C_SAMPLE - 1 := 0;
   signal last       : std_logic_vector(C_NUM_KEYS - 1 downto 0) := (others => '0');
   -- The keys pressed in this sample and the last, and in the last walk
   signal keys : std_logic_vector(C_NUM_KEYS - 1 downto 0) := (others => '0');
   signal prev : std_logic_vector(C_NUM_KEYS - 1 downto 0) := (others => '0');

   -- The key of the walk, C_NUM_KEYS when there is no walk
   signal walk_key : natural range 0 to C_NUM_KEYS := C_NUM_KEYS;

   -- The key that repeats, and the samples until it does
   signal rep_valid : std_logic := '0';
   signal rep_key   : natural range 0 to C_NUM_KEYS - 1 := 0;
   signal rep_cnt   : natural range 0 to C_REPEAT_DELAY := 0;

   -- The bytes to send: the first is in bits 39..32
   signal out_bytes : std_logic_vector(39 downto 0) := (others => '0');
   signal out_cnt   : natural range 0 to 5 := 0;

begin

   data_valid_o <= '1' when out_cnt /= 0 else '0';
   data_o       <= out_bytes(39 downto 32);

   p_scan : process (clk_i)

      -- Send the byte of a key, if it has one. sent tells if it has.
      procedure send(key : natural; sent : out boolean) is
         variable byte_v : std_logic_vector(7 downto 0);
      begin
         byte_v := key_byte(key, keys);
         sent   := byte_v /= X"00";
         if byte_v = X"00" then
            return;
         end if;
         out_bytes <= seq_bytes(byte_v);
         out_cnt   <= seq_len(byte_v);
      end procedure send;

      variable sent_v : boolean;

   begin
      if rising_edge(clk_i) then
         if out_cnt /= 0 and data_ready_i = '1' then
            out_bytes <= out_bytes(31 downto 0) & X"00";
            out_cnt   <= out_cnt - 1;
         end if;

         if walk_key /= C_NUM_KEYS then
            -- The walk: one key in each cycle while nothing waits to be sent
            if out_cnt = 0 then
               if keys(walk_key) = '1' and prev(walk_key) = '0' then
                  send(walk_key, sent_v);
                  if sent_v then
                     rep_valid <= '1';
                     rep_key   <= walk_key;
                     rep_cnt   <= C_REPEAT_DELAY - 1;
                  end if;
               end if;
               prev(walk_key) <= keys(walk_key);
               walk_key       <= walk_key + 1;
            end if;
         elsif sample_cnt /= C_SAMPLE - 1 then
            sample_cnt <= sample_cnt + 1;
         elsif out_cnt = 0 then
            -- Sample the keys, repeat the held key, and start a walk
            sample_cnt <= 0;
            last       <= matrix_i;
            keys       <= matrix_i and last;
            walk_key   <= 0;
            if rep_valid = '1' then
               if keys(rep_key) = '0' then
                  rep_valid <= '0';
               elsif rep_cnt /= 0 then
                  rep_cnt <= rep_cnt - 1;
               else
                  send(rep_key, sent_v);
                  rep_cnt <= C_REPEAT_RATE - 1;
               end if;
            end if;
         end if;

         if rst_i = '1' then
            sample_cnt <= 0;
            last       <= (others => '0');
            keys       <= (others => '0');
            prev       <= (others => '0');
            walk_key   <= C_NUM_KEYS;
            rep_valid  <= '0';
            out_cnt    <= 0;
         end if;
      end if;
   end process p_scan;

end architecture synthesis;
