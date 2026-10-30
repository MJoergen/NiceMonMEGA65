-- Tests the decode of row 27 (src/dbg/dbg_decode.vhd) against nicedis: the
-- cases of sim/gen_decode.py, instruction words of every class, condition,
-- modifier, and mode, with their constant words, and the text that
-- nicedis writes for each.
--
-- PASS AND FAIL
-- Each check is an assert with severity failure, which stops GHDL with a
-- nonzero exit status. The test ends with stop(0).
--
-- THEORY OF OPERATION
-- p_main reads G_FILE a line at a time: the instruction word, three
-- constant words, and the text. It gives the words to the decode with
-- start, waits for done, and compares the text and valid. Every tenth
-- case starts again before the decode is done, which must not matter.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.textio.all;
   use std.env.all;

entity tb_dbg_decode is
   generic (
      G_FILE : string
   );
end entity tb_dbg_decode;

architecture simulation of tb_dbg_decode is

   constant C_LEN    : natural := 34;
   constant C_PERIOD : time    := 10 ns;

   signal clk   : std_logic;
   signal rst   : std_logic := '1';
   signal start : std_logic := '0';
   signal instr : std_logic_vector(31 downto 0);
   signal const : std_logic_vector(95 downto 0);
   signal txt   : std_logic_vector(8 * C_LEN - 1 downto 0);
   signal valid : std_logic;
   signal done  : std_logic;

   function to_text(t : std_logic_vector(8 * C_LEN - 1 downto 0)) return string is
      variable res_v : string(1 to C_LEN);
   begin
      for i in 0 to C_LEN - 1 loop
         res_v(i + 1) := character'val(to_integer(t(8 * i + 7 downto 8 * i)));
      end loop;
      return res_v;
   end function to_text;

begin

   p_clk : process
   begin
      clk <= '1', '0' after C_PERIOD / 2;
      wait for C_PERIOD;
   end process p_clk;


   i_dbg_decode : entity work.dbg_decode
      generic map (
         G_LEN => C_LEN
      )
      port map (
         clk_i   => clk,
         rst_i   => rst,
         start_i => start,
         instr_i => instr,
         const_i => const,
         text_o  => txt,
         valid_o => valid,
         done_o  => done
      ); -- i_dbg_decode


   p_main : process
      file     f      : text;
      variable l      : line;
      variable w_v    : std_logic_vector(31 downto 0);
      variable c_v    : std_logic_vector(31 downto 0);
      variable ch_v   : character;
      variable want_v : string(1 to C_LEN);
      variable n_v    : natural := 0;
      variable cyc_v  : natural;
   begin
      wait until rising_edge(clk);
      rst <= '0';
      wait until rising_edge(clk);
      assert valid = '0' and to_text(txt) = (1 to C_LEN => ' ')
         report "tb_dbg_decode: after reset, valid is " & std_logic'image(valid) & " and the text '" &
                to_text(txt) & "'"
         severity failure;

      file_open(f, G_FILE, read_mode);
      while not endfile(f) loop
         readline(f, l);
         hread(l, w_v);
         instr <= w_v;
         for i in 0 to 2 loop
            hread(l, c_v);
            const(32 * i + 31 downto 32 * i) <= c_v;
         end loop;
         read(l, ch_v);
         for i in 1 to C_LEN loop
            read(l, want_v(i));
         end loop;

         -- A start in the middle of a decode first
         if n_v mod 10 = 9 then
            start <= '1';
            wait until rising_edge(clk);
            start <= '0';
            wait until rising_edge(clk);
            wait until rising_edge(clk);
         end if;
         start <= '1';
         wait until rising_edge(clk);
         start <= '0';
         wait until rising_edge(clk);
         assert valid = '0'
            report "tb_dbg_decode: valid after start"
            severity failure;
         cyc_v := 0;
         while done = '0' loop
            wait until rising_edge(clk);
            cyc_v := cyc_v + 1;
            assert cyc_v < 200
               report "tb_dbg_decode: no done for " & to_hstring(w_v)
               severity failure;
         end loop;
         wait until rising_edge(clk);
         assert valid = '1' and to_text(txt) = want_v
            report "tb_dbg_decode: " & to_hstring(w_v) & " gives '" & to_text(txt) & "', not '" & want_v & "'"
            severity failure;
         n_v := n_v + 1;
      end loop;
      file_close(f);

      report "tb_dbg_decode: " & to_string(n_v) & " cases";
      report "tb_dbg_decode: PASS";
      stop(0);
   end process p_main;

end architecture simulation;
