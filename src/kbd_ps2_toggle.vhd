-- The toggle key of the on-board debugger on a PS/2 keyboard
-- (doc/DEBUGGER.md): a pulse when Scroll Lock is pressed.
--
-- THEORY OF OPERATION
-- The scan codes come from kbd_ps2.vhd, as kbd_ps2_ascii.vhd takes them.
-- Scroll Lock is the code 7E, which gives no byte there, so the key sends
-- nothing to the program. A held key repeats its code, and its release is
-- F0 and the code. So toggle_o is '1' for one clock cycle on a 7E that does
-- not follow F0, and the detector is then disarmed until F0 7E, so that a
-- held key toggles once. 7E after E0 is part of Ctrl+Break (E0 7E E0 F0
-- 7E), and is ignored.
--
-- RESET
-- Synchronous to clk_i, by rst_i. The detector is armed, and the prefixes
-- are cleared.

library ieee;
   use ieee.std_logic_1164.all;

entity kbd_ps2_toggle is
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;
      code_valid_i : in  std_logic;
      code_i       : in  std_logic_vector(7 downto 0);
      toggle_o     : out std_logic
   );
end entity kbd_ps2_toggle;

architecture synthesis of kbd_ps2_toggle is

   constant C_EXT     : std_logic_vector(7 downto 0) := X"E0";
   constant C_RELEASE : std_logic_vector(7 downto 0) := X"F0";
   constant C_SCROLL  : std_logic_vector(7 downto 0) := X"7E";

   -- The prefixes before the code: E0, and F0, the break code
   signal ext    : std_logic := '0';
   signal brk    : std_logic := '0';
   signal armed  : std_logic := '1';
   signal toggle : std_logic := '0';

begin

   toggle_o <= toggle;

   p_decode : process (clk_i)
   begin
      if rising_edge(clk_i) then
         toggle <= '0';
         if code_valid_i = '1' then
            if code_i = C_EXT then
               ext <= '1';
            elsif code_i = C_RELEASE then
               brk <= '1';
            else
               ext <= '0';
               brk <= '0';
               if code_i = C_SCROLL and ext = '0' then
                  if brk = '1' then
                     armed <= '1';
                  elsif armed = '1' then
                     armed  <= '0';
                     toggle <= '1';
                  end if;
               end if;
            end if;
         end if;

         if rst_i = '1' then
            ext    <= '0';
            brk    <= '0';
            armed  <= '1';
            toggle <= '0';
         end if;
      end if;
   end process p_decode;

end architecture synthesis;
