-- The text and the input of the on-board debugger's settings page
-- (doc/DEBUGGER.md, issue #75): the link's settings in their usual
-- notation, and the parse of what is typed for one of them.
--
-- THEORY OF OPERATION
-- text_o has four lines of C_SET_LEN characters, line l's character c in
-- bits 8 * (C_SET_LEN * l + c) + 7 downto 8 * (C_SET_LEN * l + c), padded
-- with spaces:
--   0  The IP address, ip_i, in decimal with dots, the byte in bits 31..24
--      first: 192.168.1.65.
--   1  The MAC address, mac_i, in hex with colons, the byte in bits 47..40
--      first: 02:4E:49:43:45:00.
--   2  The TCP port of the link, G_TCP_PORT, in decimal.
--   3  The UART's baud rate, baud_i, in decimal: 2000000.
-- When ip_i, mac_i, or baud_i differs from the values of the text, p_fmt
-- takes the three, writes the lines anew, a character a cycle, and pulses
-- changed_o after the last, about 80 cycles later. The decimal digits of
-- a byte come from comparisons, and those of the rate from 32 steps of
-- double dabble; the leading zeros are dropped, but for a last 0.
--
-- p_parse reads field_i, len_i characters, one a cycle after parse_i, as
-- kind_i says: 0 an IP address, four groups of 1 to 3 decimal digits, at
-- most 255, between dots; 1 a MAC address, six groups of 1 or 2 hex
-- digits, uppercase, between colons; and 2 a baud rate, 1 to 9 decimal
-- digits, which must be one of C_UART_RATES (uart_pkg.vhd). done_o pulses
-- after the last, with ok_o, and value_o holds the address, the first
-- group in the top byte, or the rate. Anything else is not ok, and so is
-- an empty field.
--
-- RESET
-- Synchronous. The text is written anew, and a parse ends without done_o.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;

library work;
   use work.uart_pkg.all;

entity dbg_set is
   generic (
      -- The TCP port of the debug link (eth/eth_tcp.vhd), shown only
      G_TCP_PORT : natural := 4510
   );
   port (
      clk_i     : in  std_logic;
      rst_i     : in  std_logic;
      -- The settings
      ip_i      : in  std_logic_vector(31 downto 0);
      mac_i     : in  std_logic_vector(47 downto 0);
      baud_i    : in  std_logic_vector(31 downto 0);
      -- Their text, and a pulse when it has changed
      text_o    : out std_logic_vector(8 * 4 * 20 - 1 downto 0);
      changed_o : out std_logic;
      -- The parse of a field: its characters, the first in bits 7..0
      parse_i   : in  std_logic;
      kind_i    : in  natural range 0 to 2;
      field_i   : in  std_logic_vector(8 * 17 - 1 downto 0);
      len_i     : in  natural range 0 to 17;
      done_o    : out std_logic;
      ok_o      : out std_logic;
      value_o   : out std_logic_vector(47 downto 0)
   );
end entity dbg_set;

architecture synthesis of dbg_set is

   constant C_SET_LEN : natural := 20;
   constant C_FIELD   : natural := 17;

   subtype t_byte is std_logic_vector(7 downto 0);

   type t_line is array (0 to C_SET_LEN - 1) of t_byte;

   type t_cands is array (0 to 14) of t_byte;

   function to_byte(c : character) return t_byte is
   begin
      return std_logic_vector(to_unsigned(character'pos(c), 8));
   end function to_byte;

   function hex_char(n : std_logic_vector(3 downto 0)) return t_byte is
   begin
      if unsigned(n) < 10 then
         return X"3" & n;
      else
         return std_logic_vector(resize(unsigned(n), 8) + 16#37#);
      end if;
   end function hex_char;

   function dec_char(n : natural range 0 to 9) return t_byte is
   begin
      return std_logic_vector(to_unsigned(48 + n, 8));
   end function dec_char;

   -- The line of the TCP port, from the generic
   function port_line return t_line is
      constant C_S   : string  := integer'image(G_TCP_PORT);
      variable res_v : t_line := (others => to_byte(' '));
   begin
      for i in 0 to C_S'length - 1 loop
         res_v(i) := to_byte(C_S(C_S'low + i));
      end loop;
      return res_v;
   end function port_line;

   constant C_PORT_LINE : t_line := port_line;

   type t_fmt_st is (FMT_IDLE_ST, FMT_IP_ST, FMT_BCD_ST, FMT_BAUD_ST);

   signal fmt_st  : t_fmt_st := FMT_IDLE_ST;
   signal fmt_ok  : std_logic := '0';                    -- The text shows ip, mac, and baud
   signal ip      : std_logic_vector(31 downto 0) := (others => '0');
   signal mac     : std_logic_vector(47 downto 0) := (others => '0');
   signal baud    : std_logic_vector(31 downto 0) := (others => '0');
   signal ip_line : t_line;
   signal bd_line : t_line;
   signal cands   : t_cands;                             -- The characters to write ...
   signal skip    : std_logic_vector(14 downto 0);       -- ... but these
   signal cand_i  : natural range 0 to 15;
   signal line_i  : natural range 0 to C_SET_LEN;
   signal bcd     : std_logic_vector(39 downto 0);       -- The rate's 10 digits
   signal bcd_bin : std_logic_vector(31 downto 0);
   signal bcd_n   : natural range 0 to 32;

   signal changed : std_logic := '0';

   -- The parse
   signal p_run    : std_logic := '0';
   signal p_kind   : natural range 0 to 2;
   signal p_idx    : natural range 0 to C_FIELD;
   signal p_len    : natural range 0 to C_FIELD;
   signal p_acc    : unsigned(31 downto 0);
   signal p_digits : natural range 0 to 15;
   signal p_groups : natural range 0 to 15;
   signal p_bad    : std_logic;
   signal p_res    : std_logic_vector(47 downto 0);
   signal p_field  : std_logic_vector(8 * C_FIELD - 1 downto 0);

begin

   ---------------------------------------------------------------------------
   -- The text
   ---------------------------------------------------------------------------

   gen_text : for c in 0 to C_SET_LEN - 1 generate
      text_o(8 * c + 7 downto 8 * c)                                     <= ip_line(c);
      text_o(8 * (2 * C_SET_LEN + c) + 7 downto 8 * (2 * C_SET_LEN + c)) <= C_PORT_LINE(c);
      text_o(8 * (3 * C_SET_LEN + c) + 7 downto 8 * (3 * C_SET_LEN + c)) <= bd_line(c);
   end generate gen_text;

   -- The MAC address: two hex digits and a colon a byte, in fixed places

   gen_mac : for c in 0 to C_SET_LEN - 1 generate

      gen_digit : if c < 17 and c mod 3 /= 2 generate
         text_o(8 * (C_SET_LEN + c) + 7 downto 8 * (C_SET_LEN + c)) <= hex_char(mac(47 - 8 * (c / 3) - 4 * (c mod 3) downto 44 - 8 * (c / 3) - 4 * (c mod 3)));
      end generate gen_digit;

      gen_colon : if c < 17 and c mod 3 = 2 generate
         text_o(8 * (C_SET_LEN + c) + 7 downto 8 * (C_SET_LEN + c)) <= to_byte(':');
      end generate gen_colon;

      gen_space : if c >= 17 generate
         text_o(8 * (C_SET_LEN + c) + 7 downto 8 * (C_SET_LEN + c)) <= to_byte(' ');
      end generate gen_space;

   end generate gen_mac;

   changed_o <= changed;

   p_fmt : process (clk_i)
      variable b_v   : natural range 0 to 255;
      variable bcd_v : std_logic_vector(39 downto 0);
   begin
      if rising_edge(clk_i) then
         changed <= '0';

         case fmt_st is

            when FMT_IDLE_ST =>
               if fmt_ok = '0' or ip_i /= ip or mac_i /= mac or baud_i /= baud then
                  ip     <= ip_i;
                  mac    <= mac_i;
                  baud   <= baud_i;
                  fmt_ok <= '1';
                  -- The IP address: three digits and a dot a byte, without
                  -- the leading zeros and the last dot
                  for k in 0 to 3 loop
                     b_v              := to_integer(unsigned(ip_i(31 - 8 * k downto 24 - 8 * k)));
                     cands(4 * k)     <= dec_char(b_v / 100);
                     cands(4 * k + 1) <= dec_char((b_v / 10) mod 10);
                     cands(4 * k + 2) <= dec_char(b_v mod 10);
                     skip(4 * k)      <= '0';
                     skip(4 * k + 1)  <= '0';
                     skip(4 * k + 2)  <= '0';
                     if b_v < 100 then
                        skip(4 * k) <= '1';
                     end if;
                     if b_v < 10 then
                        skip(4 * k + 1) <= '1';
                     end if;
                     if k < 3 then
                        cands(4 * k + 3) <= to_byte('.');
                        skip(4 * k + 3)  <= '0';
                     end if;
                  end loop;
                  ip_line <= (others => to_byte(' '));
                  cand_i  <= 0;
                  line_i  <= 0;
                  fmt_st  <= FMT_IP_ST;
               end if;

            when FMT_IP_ST =>
               if cand_i = 15 then
                  bcd     <= (others => '0');
                  bcd_bin <= baud;
                  bcd_n   <= 32;
                  fmt_st  <= FMT_BCD_ST;
               else
                  if skip(cand_i) = '0' then
                     ip_line(line_i) <= cands(cand_i);
                     line_i          <= line_i + 1;
                  end if;
                  cand_i <= cand_i + 1;
               end if;

            -- Double dabble: a digit of 5 or more gets 3, then a shift in of
            -- the next bit, the top first
            when FMT_BCD_ST =>
               if bcd_n = 0 then
                  for k in 0 to 9 loop
                     cands(k) <= X"3" & bcd(39 - 4 * k downto 36 - 4 * k);
                     skip(k)  <= '0';
                  end loop;
                  -- The leading zeros, but for the last digit
                  for k in 0 to 8 loop
                     if bcd(39 downto 36 - 4 * k) = (39 downto 36 - 4 * k => '0') then
                        skip(k) <= '1';
                     end if;
                  end loop;
                  bd_line <= (others => to_byte(' '));
                  cand_i  <= 5;                         -- Only 10 candidates: 5 to 14
                  line_i  <= 0;
                  fmt_st  <= FMT_BAUD_ST;
               else
                  bcd_v := bcd;
                  for k in 0 to 9 loop
                     if unsigned(bcd_v(4 * k + 3 downto 4 * k)) >= 5 then
                        bcd_v(4 * k + 3 downto 4 * k) := std_logic_vector(unsigned(bcd_v(4 * k + 3 downto 4 * k)) + 3);
                     end if;
                  end loop;
                  bcd     <= bcd_v(38 downto 0) & bcd_bin(31);
                  bcd_bin <= bcd_bin(30 downto 0) & '0';
                  bcd_n   <= bcd_n - 1;
               end if;

            when FMT_BAUD_ST =>
               if cand_i = 15 then
                  changed <= '1';
                  fmt_st  <= FMT_IDLE_ST;
               else
                  if skip(cand_i - 5) = '0' then
                     bd_line(line_i) <= cands(cand_i - 5);
                     line_i          <= line_i + 1;
                  end if;
                  cand_i <= cand_i + 1;
               end if;

         end case;

         if rst_i = '1' then
            fmt_st  <= FMT_IDLE_ST;
            fmt_ok  <= '0';
            changed <= '0';
            ip_line <= (others => to_byte(' '));
            bd_line <= (others => to_byte(' '));
         end if;
      end if;
   end process p_fmt;

   ---------------------------------------------------------------------------
   -- The parse
   ---------------------------------------------------------------------------

   p_parse : process (clk_i)
      variable ch_v   : t_byte;
      variable dig_v  : integer range -1 to 15;
      variable base_v : natural range 10 to 16;
      variable sep_v  : t_byte;
      variable max_v  : natural range 1 to 9;            -- The digits of a group
      variable want_v : natural range 1 to 6;            -- The groups
      variable bad_v  : std_logic;
   begin
      if rising_edge(clk_i) then
         done_o <= '0';

         case p_kind is
            when 0 =>
               base_v := 10;
               sep_v  := to_byte('.');
               max_v  := 3;
               want_v := 4;
            when 1 =>
               base_v := 16;
               sep_v  := to_byte(':');
               max_v  := 2;
               want_v := 6;
            when others =>
               base_v := 10;
               sep_v  := X"00";
               max_v  := 9;
               want_v := 1;
         end case;

         if parse_i = '1' then
            p_run    <= '1';
            p_kind   <= kind_i;
            p_field  <= field_i;
            p_len    <= len_i;
            p_idx    <= 0;
            p_acc    <= (others => '0');
            p_digits <= 0;
            p_groups <= 0;
            p_bad    <= '0';
            p_res    <= (others => '0');
         elsif p_run = '1' then
            bad_v := p_bad;
            if p_idx = p_len then
               -- The end: the last group, and the number of groups
               p_run  <= '0';
               done_o <= '1';
               if p_digits = 0 or p_groups + 1 /= want_v then
                  bad_v := '1';
               end if;
               if p_kind = 2 then
                  value_o <= X"0000" & std_logic_vector(p_acc);
                  if uart_rate_index(std_logic_vector(p_acc)) < 0 then
                     bad_v := '1';
                  end if;
               else
                  value_o <= p_res(39 downto 0) & std_logic_vector(p_acc(7 downto 0));
                  if p_acc > 255 then
                     bad_v := '1';
                  end if;
               end if;
               ok_o <= not bad_v;
            else
               ch_v  := p_field(8 * p_idx + 7 downto 8 * p_idx);
               dig_v := -1;
               if ch_v >= to_byte('0') and ch_v <= to_byte('9') then
                  dig_v := to_integer(unsigned(ch_v)) - 48;
               elsif base_v = 16 and ch_v >= to_byte('A') and ch_v <= to_byte('F') then
                  dig_v := to_integer(unsigned(ch_v)) - 55;
               end if;
               if p_kind /= 2 and ch_v = sep_v then
                  -- The end of a group
                  if p_digits = 0 or p_acc > 255 or p_groups + 1 >= want_v then
                     bad_v := '1';
                  end if;
                  p_res    <= p_res(39 downto 0) & std_logic_vector(p_acc(7 downto 0));
                  p_groups <= p_groups + 1;
                  p_acc    <= (others => '0');
                  p_digits <= 0;
               elsif dig_v >= 0 then
                  if p_digits = max_v then
                     bad_v := '1';
                  else
                     p_acc    <= resize(p_acc * base_v, 32) + to_unsigned(dig_v, 32);
                     p_digits <= p_digits + 1;
                  end if;
               else
                  bad_v := '1';
               end if;
               p_idx <= p_idx + 1;
            end if;
            p_bad <= bad_v;
         end if;

         if rst_i = '1' then
            p_run  <= '0';
            done_o <= '0';
         end if;
      end if;
   end process p_parse;

end architecture synthesis;
