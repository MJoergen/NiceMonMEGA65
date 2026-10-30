-- The key combination of the on-board debugger on the MEGA65 keyboard
-- (doc/DEBUGGER.md): a pulse when MEGA and HELP are pressed together.
--
-- THEORY OF OPERATION
-- MEGA is key 61 of the matrix of kbd_m65.vhd, and HELP is key 67. Neither
-- gives a byte in kbd_m65_ascii.vhd, so the combination sends nothing to
-- the program. Every 5 ms the two keys are sampled, as kbd_m65_ascii.vhd
-- samples all the keys, and the combination counts as pressed when both
-- keys were pressed in this sample and the one before, which filters out
-- bounces. toggle_o is '1' for one clock cycle when the combination becomes
-- pressed, and not again until it has been released, so a held
-- combination toggles once. The order of the two keys does not matter.
--
-- RESET
-- Synchronous to clk_i, by rst_i. The combination counts as released.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity kbd_m65_toggle is
   generic (
      G_CLOCK_HZ : natural
   );
   port (
      clk_i    : in  std_logic;
      rst_i    : in  std_logic;
      matrix_i : in  std_logic_vector(79 downto 0);
      toggle_o : out std_logic
   );
end entity kbd_m65_toggle;

architecture synthesis of kbd_m65_toggle is

   -- Clock cycles from one sample to the next
   constant C_SAMPLE : natural := G_CLOCK_HZ / 200;

   -- Key numbers
   constant C_MEGA : natural := 61;
   constant C_HELP : natural := 67;

   signal sample_cnt : natural range 0 to C_SAMPLE - 1 := 0;
   -- Both keys in the last sample, and the combination pressed
   signal last    : std_logic := '0';
   signal pressed : std_logic := '0';
   signal toggle  : std_logic := '0';

begin

   toggle_o <= toggle;

   p_sample : process (clk_i)
      variable both_v : std_logic;
   begin
      if rising_edge(clk_i) then
         toggle <= '0';
         if sample_cnt /= C_SAMPLE - 1 then
            sample_cnt <= sample_cnt + 1;
         else
            sample_cnt <= 0;
            both_v     := matrix_i(C_MEGA) and matrix_i(C_HELP);
            last       <= both_v;
            pressed    <= both_v and last;
            if both_v = '1' and last = '1' and pressed = '0' then
               toggle <= '1';
            end if;
         end if;

         if rst_i = '1' then
            sample_cnt <= 0;
            last       <= '0';
            pressed    <= '0';
            toggle     <= '0';
         end if;
      end if;
   end process p_sample;

end architecture synthesis;
