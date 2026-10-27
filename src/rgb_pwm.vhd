-- The driver of an RGB LED: three pulse-width modulated outputs, one for
-- each color, with 16 levels. The Nexys4DDR's RGB LEDs are too bright at full
-- duty, so levels 1 and 2 give a dim light.
--
-- THEORY OF OPERATION
-- A free-running counter of 4 bits, slowed by G_DIV, is compared with the
-- level of each color. The output is '1' while the counter is below the
-- level, so a level of 0 is off, and a level of 15 is on for 15 of every 16
-- steps. The outputs are registered, with nothing between the registers and
-- the pins (IOB TRUE in the board's XDC). keep stops synthesis from merging
-- equal registers, which could then not all be in the IOBs.
--
-- RESET
-- None. The levels come from registers that the caller resets.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity rgb_pwm is
   generic (
      -- Clock cycles per step of the counter, for a period well above what
      -- the eye sees as flicker, here 90 MHz / 4 / 16 = 1.4 MHz. A smaller
      -- number is fine too, as nothing else depends on it.
      G_DIV : natural := 4
   );
   port (
      clk_i   : in  std_logic;
      red_i   : in  std_logic_vector(3 downto 0);
      green_i : in  std_logic_vector(3 downto 0);
      blue_i  : in  std_logic_vector(3 downto 0);
      -- Bit 2 red, bit 1 green, bit 0 blue
      rgb_o   : out std_logic_vector(2 downto 0)
   );
end entity rgb_pwm;

architecture synthesis of rgb_pwm is

   signal div   : natural range 0 to G_DIV - 1 := 0;
   signal count : std_logic_vector(3 downto 0) := (others => '0');
   signal rgb_r : std_logic_vector(2 downto 0) := (others => '0');

   attribute keep : string;
   attribute keep of rgb_r : signal is "true";

begin

   p_pwm : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if div = G_DIV - 1 then
            div   <= 0;
            count <= count + 1;
         else
            div <= div + 1;
         end if;

         rgb_r(2) <= '1' when count < red_i else '0';
         rgb_r(1) <= '1' when count < green_i else '0';
         rgb_r(0) <= '1' when count < blue_i else '0';
      end if;
   end process p_pwm;

   rgb_o <= rgb_r;

end architecture synthesis;
