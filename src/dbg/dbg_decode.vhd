-- The decode of an instruction for the on-board debugger's row 27
-- (doc/DEBUGGER.md): the instruction word and its constant words in, the
-- text of the instruction out, in the assembler's syntax
-- (nice_cpu/doc/ISA.md §10), as nicedis.py writes it.
--
-- THEORY OF OPERATION
-- start_i takes the instruction word and its constant words, in the order
-- of the fields that take one: dest, s0, then s1 (ISA.md §2.3). The text
-- is then written into text_o one character a cycle, from the left, by a
-- sequencer: the condition and a space, unless it is "always"; the
-- mnemonic, the alias where a SHIFT has one, with its modifiers, [C],
-- [M], or [CM]; and a space and the operands that the instruction uses,
-- separated by a comma and a space. An operand is a register, R0 to R15,
-- with @, --, ++, or a trailing -- of its mode, or a constant, 0x and its
-- hex digits in lower case without leading zeros, with [Rx] unless Rx is
-- R0. INT has its vector in decimal. A reserved control word is
-- "reserved", without its condition. A text longer than G_LEN characters ends in > at the last
-- place. The rest is spaces. valid_o is '0' from start_i until the text
-- is whole, then '1', and done_o is '1' for that cycle. A decode takes
-- at most about 70 cycles.
--
-- Unlike nicedis.py, the decode shows an instruction with an unused field
-- that is not R0 as the instruction, without the field, where nicedis.py
-- writes .DAT: the debugger shows the raw word beside it.
--
-- RESET
-- Synchronous to clk_i, by rst_i. The text is spaces, and valid_o is '0'.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;
   use ieee.numeric_std_unsigned.all;

entity dbg_decode is
   generic (
      G_LEN : positive := 34
   );
   port (
      clk_i   : in  std_logic;
      rst_i   : in  std_logic;
      -- The instruction word, and its constant words, the first in bits
      -- 31..0, while start_i is '1'
      start_i : in  std_logic;
      instr_i : in  std_logic_vector(31 downto 0);
      const_i : in  std_logic_vector(95 downto 0);
      -- The text, character i in bits 8 * i + 7 .. 8 * i
      text_o  : out std_logic_vector(8 * G_LEN - 1 downto 0);
      valid_o : out std_logic;
      done_o  : out std_logic
   );
end entity dbg_decode;

architecture synthesis of dbg_decode is

   subtype t_byte is std_logic_vector(7 downto 0);

   subtype t_word is std_logic_vector(31 downto 0);

   type t_text is array (0 to G_LEN - 1) of t_byte;

   type t_fields is array (0 to 2) of std_logic_vector(6 downto 0);

   type t_words is array (0 to 2) of t_word;

   -- The names, 8 characters each, padded with spaces: the ALU operations
   -- 0 to 15, the SHIFT operations 16 to 31, HALT, RTI, INT, and a
   -- reserved control word. One dimension, as GHDL 4.1 cannot synthesize
   -- the read of a two-dimensional constant.
   constant C_HALT     : natural := 32;
   constant C_RTI      : natural := 33;
   constant C_INT      : natural := 34;
   constant C_RESERVED : natural := 35;
   constant C_NAMES_S  : string  :=
                                    "MOVE    SUB     MDBL    ADD     DBL     DEC     NOT     NOR     " &
                                    "IAND    NAND    XOR     IOR     XNOR    AND     ONE     OR      " &
                                    "SHL     0<1     0<C     C<0     C<1     C<C     ROL     BPL     " &
                                    "SHR     1>0     C>0     0>C     1>C     C>C     ROR     BPR     " &
                                    "HALT    RTI     INT     reserved";
   constant C_FLAGS_S  : string  := "1XCZNVEI";

   type t_bytes is array (natural range <>) of t_byte;

   function to_byte(c : character) return t_byte is
   begin
      return std_logic_vector(to_unsigned(character'pos(c), 8));
   end function to_byte;

   function bytes(s : string) return t_bytes is
      variable res_v : t_bytes(0 to s'length - 1);
   begin
      for i in 0 to s'length - 1 loop
         res_v(i) := to_byte(s(s'low + i));
      end loop;
      return res_v;
   end function bytes;

   constant C_NAMES : t_bytes := bytes(C_NAMES_S);
   constant C_FLAGS : t_bytes := bytes(C_FLAGS_S);

   -- The decimal digits of 0 to 255, three of 4 bits each
   type t_bcd is array (0 to 255) of std_logic_vector(11 downto 0);

   function bcd return t_bcd is
      variable res_v : t_bcd;
   begin
      for n in 0 to 255 loop
         res_v(n) := std_logic_vector(to_unsigned(n / 100, 4)) &
                     std_logic_vector(to_unsigned((n / 10) mod 10, 4)) &
                     std_logic_vector(to_unsigned(n mod 10, 4));
      end loop;
      return res_v;
   end function bcd;

   constant C_BCD : t_bcd := bcd;

   -- A hex digit in lower case
   function hex_char(n : std_logic_vector(3 downto 0)) return t_byte is
   begin
      if n < 10 then
         return X"3" & n;
      else
         return ("0000" & n) + X"57";
      end if;
   end function hex_char;

   function takes_const(f : std_logic_vector(6 downto 0)) return boolean is
   begin
      return f(5 downto 4) = "11";
   end function takes_const;

   type t_st is (
      IDLE_ST, COND_ST, NAME_ST, MODS_ST, ARGS_ST, VEC_ST,
      AT_ST, PRE_ST, ZERO_ST, X_ST, SKIP_ST, HEX_ST, LB_ST,
      R_ST, REG_ST, REG2_ST, RB_ST, POST_ST, SEP_ST, DONE_ST
   );

   signal st    : t_st := IDLE_ST;
   signal text  : t_text := (others => X"20");
   signal pos   : natural range 0 to G_LEN := 0;
   signal step  : natural range 0 to 7;                  -- The place in a state
   signal valid : std_logic := '0';

   -- What start_i took
   signal word : t_word;
   signal vec  : std_logic_vector(11 downto 0);        -- INT's vector in decimal

   -- A small table, which Vivado would otherwise put in a block RAM
   attribute rom_style : string;
   attribute rom_style of vec : signal is "distributed";
   signal name   : natural range 0 to C_RESERVED;
   signal nops   : natural range 0 to 3;                 -- The operands shown
   signal fields : t_fields;
   signal consts : t_words;

   -- The operand being written
   signal op    : natural range 0 to 2;
   signal field : std_logic_vector(6 downto 0);
   signal hex   : t_word;

begin

   valid_o <= valid;

   gen_text : for i in 0 to G_LEN - 1 generate
      text_o(8 * i + 7 downto 8 * i) <= text(i);
   end generate gen_text;

   p_dec : process (clk_i)
      variable ch_v   : t_byte;
      variable put_v  : boolean;
      variable j_v    : natural range 0 to 3;
      variable opc_v  : natural range 0 to 15;
      variable cmd_v  : natural range 0 to 31;
      variable bcd_v  : std_logic_vector(11 downto 0);
      variable mode_v : std_logic_vector(2 downto 0);
      variable dest_v : boolean;

      -- Starts operand k
      procedure operand(k : natural range 0 to 2) is
      begin
         op    <= k;
         field <= fields(k);
         hex   <= consts(k);
         step  <= 0;
         st    <= AT_ST;
      end procedure operand;

   begin
      if rising_edge(clk_i) then
         done_o <= '0';
         put_v  := false;
         ch_v   := X"20";
         mode_v := field(6 downto 4);
         dest_v := op = 0;

         case st is

            when IDLE_ST =>
               null;

            -- ?, !, the flag, and a space
            when COND_ST =>
               step <= step + 1;
               case step is
                  when 0 =>
                     put_v := true;
                     ch_v  := X"3F";                        -- ?
                  when 1 =>
                     put_v := word(31) = '1';
                     ch_v  := X"21";                        -- !
                  when 2 =>
                     put_v := true;
                     ch_v  := C_FLAGS(to_integer(word(30 downto 28)));
                  when others =>
                     put_v := true;
                     step  <= 0;
                     st    <= NAME_ST;
               end case;

            when NAME_ST =>
               ch_v := C_NAMES(8 * name + step);
               if ch_v = X"20" or step = 7 then
                  if ch_v /= X"20" then
                     put_v := true;
                  end if;
                  step <= 0;
                  if name >= C_HALT then
                     st <= ARGS_ST;
                  else
                     st <= MODS_ST;
                  end if;
               else
                  put_v := true;
                  step  <= step + 1;
               end if;

            -- [C], [M], or [CM]: C only for an ALU instruction
            when MODS_ST =>
               step <= step + 1;
               case step is
                  when 0 =>
                     put_v := (word(26) = '1' and word(27) = '0') or word(25) = '1';
                     ch_v  := X"5B";                        -- [
                     if not put_v then
                        st <= ARGS_ST;
                     end if;
                  when 1 =>
                     put_v := word(26) = '1' and word(27) = '0';
                     ch_v  := X"43";                        -- C
                  when 2 =>
                     put_v := word(25) = '1';
                     ch_v  := X"4D";                        -- M
                  when others =>
                     put_v := true;
                     ch_v  := X"5D";                        -- ]
                     st    <= ARGS_ST;
               end case;

            -- A space, then the vector of INT or the first operand
            when ARGS_ST =>
               step <= 0;
               if name = C_INT then
                  put_v := true;
                  st    <= VEC_ST;
               elsif name >= C_HALT or nops = 0 then
                  st <= DONE_ST;
               else
                  put_v := true;
                  operand(0);
               end if;

            -- The vector's decimal digits, without leading zeros
            when VEC_ST =>
               bcd_v := vec;
               step  <= step + 1;
               case step is
                  when 0 =>
                     put_v := bcd_v(11 downto 8) /= 0;
                     ch_v  := X"3" & bcd_v(11 downto 8);
                  when 1 =>
                     put_v := bcd_v(11 downto 4) /= 0;
                     ch_v  := X"3" & bcd_v(7 downto 4);
                  when others =>
                     put_v := true;
                     ch_v  := X"3" & bcd_v(3 downto 0);
                     st    <= DONE_ST;
               end case;

            -- @ for memory, then -- before, a constant, or the register
            when AT_ST =>
               put_v := mode_v(2) = '1';
               ch_v  := X"40";                              -- @
               if mode_v(1 downto 0) = "11" then
                  st <= ZERO_ST;
               elsif mode_v(1 downto 0) = "01" and not (dest_v and mode_v(2) = '0') then
                  st <= PRE_ST;
               else
                  st <= R_ST;
               end if;

            when PRE_ST =>
               put_v := true;
               ch_v  := X"2D";                              -- -
               step  <= step + 1;
               if step = 1 then
                  st <= R_ST;
               end if;

            when ZERO_ST =>
               put_v := true;
               ch_v  := X"30";                              -- 0
               st    <= X_ST;

            when X_ST =>
               put_v := true;
               ch_v  := X"78";                              -- x
               step  <= 0;
               st    <= SKIP_ST;

            -- The leading zeros, but the last digit
            when SKIP_ST =>
               if hex(31 downto 28) = 0 and step /= 7 then
                  hex  <= hex(27 downto 0) & X"0";
                  step <= step + 1;
               else
                  st <= HEX_ST;
               end if;

            when HEX_ST =>
               put_v := true;
               ch_v  := hex_char(hex(31 downto 28));
               hex   <= hex(27 downto 0) & X"0";
               if step /= 7 then
                  step <= step + 1;
               else
                  step <= 0;
                  if field(3 downto 0) = 0 then
                     st <= SEP_ST;
                  else
                     st <= LB_ST;
                  end if;
               end if;

            when LB_ST =>
               put_v := true;
               ch_v  := X"5B";                              -- [
               st    <= R_ST;

            when R_ST =>
               put_v := true;
               ch_v  := X"52";                              -- R
               st    <= REG_ST;

            when REG_ST =>
               put_v := true;
               if field(3 downto 0) >= 10 then
                  ch_v := X"31";                            -- 1
                  st   <= REG2_ST;
               else
                  ch_v := X"3" & field(3 downto 0);
                  st   <= RB_ST;
               end if;

            when REG2_ST =>
               put_v := true;
               ch_v  := X"3" & (field(3 downto 0) - 10);
               st    <= RB_ST;

            -- ] after a constant's register, or ++ or -- after the register
            when RB_ST =>
               step <= 0;
               if mode_v(1 downto 0) = "11" then
                  put_v := true;
                  ch_v  := X"5D";                           -- ]
                  st    <= SEP_ST;
               elsif mode_v(1 downto 0) = "10" or (mode_v = "001" and dest_v) then
                  st <= POST_ST;
               else
                  st <= SEP_ST;
               end if;

            when POST_ST =>
               put_v := true;
               if mode_v(1 downto 0) = "10" then
                  ch_v := X"2B";                            -- +
               else
                  ch_v := X"2D";                            -- -
               end if;
               step <= step + 1;
               if step = 1 then
                  step <= 0;
                  st   <= SEP_ST;
               end if;

            -- A comma and a space before the next operand
            when SEP_ST =>
               if op + 1 >= nops then
                  st <= DONE_ST;
               elsif step = 0 then
                  put_v := true;
                  ch_v  := X"2C";                           -- ,
                  step  <= 1;
               else
                  put_v := true;
                  operand(op + 1);
               end if;

            when DONE_ST =>
               valid  <= '1';
               done_o <= '1';
               st     <= IDLE_ST;

         end case;

         -- The character, or > at the last place when there is no room
         if put_v and st /= IDLE_ST and st /= DONE_ST then
            if pos = G_LEN then
               text(G_LEN - 1) <= X"3E";                    -- >
               st              <= DONE_ST;
            else
               text(pos) <= ch_v;
               pos       <= pos + 1;
            end if;
         end if;

         if start_i = '1' then
            word  <= instr_i;
            vec   <= C_BCD(to_integer(instr_i(7 downto 0)));
            text  <= (others => X"20");
            pos   <= 0;
            step  <= 0;
            valid <= '0';
            -- The fields, and the constant word of each that takes one
            fields <= (instr_i(20 downto 14), instr_i(13 downto 7), instr_i(6 downto 0));
            j_v    := 0;
            consts <= (others => (others => '0'));
            for k in 0 to 2 loop
               if takes_const(instr_i(20 - 7 * k downto 14 - 7 * k)) then
                  consts(k) <= const_i(32 * j_v + 31 downto 32 * j_v);
                  j_v       := j_v + 1;
               end if;
            end loop;
            opc_v := to_integer(instr_i(24 downto 21));
            cmd_v := to_integer(instr_i(25 downto 21));
            if instr_i(27 downto 26) = "11" then
               nops <= 0;
               if cmd_v > 2 or instr_i(20 downto 8) /= 0 or (cmd_v /= 2 and instr_i(7 downto 0) /= 0) then
                  name <= C_RESERVED;
               else
                  name <= C_HALT + cmd_v;
               end if;
            elsif instr_i(27) = '1' then
               name <= 16 + opc_v;
               nops <= 3;
            else
               name <= opc_v;
               case opc_v is
                  when 0 | 4 | 5 | 6 => nops <= 2;          -- MOVE, DBL, DEC, NOT
                  when 14            => nops <= 1;          -- ONE
                  when others        => nops <= 3;
               end case;
            end if;
            -- No condition when it is "always", and none for a reserved
            -- word, which is not an instruction
            if instr_i(30 downto 28) = 0 and instr_i(31) = '0' then
               st <= NAME_ST;
            elsif instr_i(27 downto 26) = "11" and
                  (cmd_v > 2 or instr_i(20 downto 8) /= 0 or (cmd_v /= 2 and instr_i(7 downto 0) /= 0)) then
               st <= NAME_ST;
            else
               st <= COND_ST;
            end if;
         end if;

         if rst_i = '1' then
            st    <= IDLE_ST;
            text  <= (others => X"20");
            valid <= '0';
         end if;
      end if;
   end process p_dec;

end architecture synthesis;
