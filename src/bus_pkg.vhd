-- The gate of a bus's read data, which devices.vhd and nicemon.vhd share.
--
-- THEORY OF OPERATION
-- A read's sources are picked with one AND-OR: each source's word is
-- gated with its one-hot select bit, and the gated words are ORed.
-- gate() is the AND of that: the word if en is '1', else 0.
--
-- RESET
-- None; a function only.

library ieee;
   use ieee.std_logic_1164.all;

package bus_pkg is

   -- word if en is '1', else 0
   function gate (
      word : std_logic_vector(31 downto 0);
      en   : std_logic
   ) return std_logic_vector;

end package bus_pkg;

package body bus_pkg is

   function gate (
      word : std_logic_vector(31 downto 0);
      en   : std_logic
   ) return std_logic_vector is
   begin
      return word and (31 downto 0 => en);
   end function gate;

end package body bus_pkg;
