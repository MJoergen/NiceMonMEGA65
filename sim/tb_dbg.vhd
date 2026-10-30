-- Tests the on-board debugger (src/dbg/dbg.vhd), stage 1 of doc/DEBUGGER.md:
-- the strip it draws into the overlay, and the toggle between Off and Focus.
--
-- THEORY OF OPERATION
-- p_ovl is the overlay of text.vhd: it takes the debugger's writes into a
-- model, and counts those outside the strip, which must be none. p_main
-- resets the debugger, waits for the strip to be drawn, and checks every
-- word of it against the text written out here, with the toggle key of the
-- MEGA65. It then pulses the toggle, and checks the strip, the page, and the
-- focus outputs, and that the debugger takes the keyboard's bytes. A reset
-- in Focus leaves the debugger Off, and draws the strip again.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.env.all;

entity tb_dbg is
end entity tb_dbg;

architecture simulation of tb_dbg is

   type t_ovl is array (0 to 4095) of std_logic_vector(31 downto 0);

   -- The strip, rows 25 to 28 of the overlay
   constant C_FIRST : natural := 25 * 80;
   constant C_LAST  : natural := 29 * 80 - 1;

   -- The strip's four rows of 80 characters, and their color
   constant C_ROW25 : string := " R0-7   -------- -------- -------- -------- -------- -------- -------- -------- ";
   constant C_ROW26 : string := " R8-15  -------- -------- -------- -------- -------- -------- -------- -------- ";
   constant C_ROW27 : string := " NO LINK                                                                        ";
   constant C_ROW28 : string := " F1 step   F3 go   F5 pause   F7 hold   F9 restart   F11 page   MEGA+HELP back  ";
   constant C_TEXT  : string(1 to 320) := C_ROW25 & C_ROW26 & C_ROW27 & C_ROW28;
   constant C_COLOR : std_logic_vector(23 downto 0) := X"004FFF";

   signal clk     : std_logic := '1';
   signal rst     : std_logic := '1';
   signal running : boolean   := true;

   signal toggle    : std_logic := '0';
   signal kbd_valid : std_logic := '0';
   signal kbd_ready : std_logic;
   signal kbd_data  : std_logic_vector(7 downto 0) := X"00";

   signal ovl_we   : std_logic;
   signal ovl_addr : std_logic_vector(11 downto 0);
   signal ovl_data : std_logic_vector(31 downto 0);
   signal strip    : std_logic;
   signal page     : std_logic;
   signal focus    : std_logic;

   signal ovl    : t_ovl   := (others => (others => '0'));
   signal writes : natural := 0;
   signal stray  : natural := 0;

begin

   clk <= not clk after 5 ns when running;

   i_dbg : entity work.dbg
      port map (
         clk_i       => clk,
         rst_i       => rst,
         toggle_i    => toggle,
         kbd_valid_i => kbd_valid,
         kbd_ready_o => kbd_ready,
         kbd_data_i  => kbd_data,
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
            if ovl_addr < C_FIRST or ovl_addr > C_LAST then
               stray <= stray + 1;
            end if;
         end if;
      end if;
   end process p_ovl;


   p_main : process
      variable base_v : natural;

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

      -- The strip must be written once since base writes, and hold C_TEXT.
      procedure check_strip(base : natural) is
         variable want_v : std_logic_vector(31 downto 0);
      begin
         assert writes - base = C_LAST - C_FIRST + 1 and stray = 0
            report "tb_dbg: " & integer'image(writes - base) & " writes to the overlay, " &
                   integer'image(stray) & " outside the strip"
            severity failure;
         for i in C_FIRST to C_LAST loop
            want_v := C_COLOR & to_slv(character'pos(C_TEXT(i - C_FIRST + 1)), 8);
            assert ovl(i) = want_v
               report "tb_dbg: overlay word " & integer'image(i) & " is " &
                      to_hstring(ovl(i)) & ", not " & to_hstring(want_v)
               severity failure;
         end loop;
      end procedure check_strip;

   begin
      cycles(4);
      rst <= '0';

      report "tb_dbg: the strip is drawn after reset, and the debugger is Off";
      cycles(400);
      check_strip(0);
      expect('0', '0', '0', "after reset");

      report "tb_dbg: the toggle enters Focus";
      pulse;
      expect('1', '0', '1', "after the toggle");

      report "tb_dbg: the keyboard's bytes are taken in Focus";
      kbd_valid <= '1';
      kbd_data  <= X"61";
      wait until rising_edge(clk);
      assert kbd_ready = '1'
         report "tb_dbg: a byte was not taken"
         severity failure;
      kbd_valid <= '0';

      report "tb_dbg: the toggle leaves Focus";
      pulse;
      expect('0', '0', '0', "after the second toggle");

      report "tb_dbg: a reset in Focus leaves it Off, and draws the strip again";
      pulse;
      expect('1', '0', '1', "after the third toggle");
      base_v := writes;
      rst    <= '1';
      wait until rising_edge(clk);
      rst <= '0';
      cycles(400);
      expect('0', '0', '0', "after the reset");
      check_strip(base_v);

      report "tb_dbg: PASS";
      running <= false;
      stop(0);
   end process p_main;

end architecture simulation;
