-- The driver of an eight-digit seven-segment display with common anodes, as
-- on the Nexys4DDR. It takes the segments of the eight digits as raw bits,
-- one byte per digit, and scans the display.
--
-- THEORY OF OPERATION
-- The digits share the segment lines, so they are lit one at a time, each
-- for 1/8 of the time, at about 1 kHz per digit, which the eye sees as all
-- of them lit. A digit whose byte is 0 is dark.
--
-- seg_i holds digit 0, the rightmost, in bits 7..0, and digit 7 in bits
-- 63..56. In a byte, bit 0 is segment A, bit 1 is B, up to bit 6 for G, and
-- bit 7 is the decimal point; a 1 lights it. The board's anodes and
-- cathodes are active low, so the outputs are inverted here. They are
-- registered with nothing between the registers and the pins, so that the
-- IOBs hold them (IOB TRUE in the board's XDC), and the anode and the
-- cathodes change at the same time. The shared segment lines show the
-- digit that was lit before for a moment when the anode changes; a dead
-- cycle would remove that, but at this rate the ghost cannot be seen.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) clk_i runs at G_CLOCK_HZ.
--
-- RESET
-- None. The scan starts with digit 0, and seg_i is held by the caller, which
-- resets it to 0, a dark display.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity seg7 is
   generic (
      G_CLOCK_HZ : natural
   );
   port (
      clk_i : in  std_logic;
      seg_i : in  std_logic_vector(63 downto 0);
      an_o  : out std_logic_vector(7 downto 0);   -- active low
      ca_o  : out std_logic_vector(7 downto 0)    -- active low, bit 7 the point
   );
end entity seg7;

architecture synthesis of seg7 is

   -- Clock cycles of a digit, 1/8 ms
   constant C_DIGIT_CYCLES : natural := G_CLOCK_HZ / 8_000;

   signal count : natural range 0 to C_DIGIT_CYCLES - 1 := 0;
   signal digit : natural range 0 to 7                  := 0;

   -- The output registers start dark, as the pins do before configuration
   signal an_r : std_logic_vector(7 downto 0) := (others => '1');
   signal ca_r : std_logic_vector(7 downto 0) := (others => '1');

begin

   p_scan : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if count = C_DIGIT_CYCLES - 1 then
            count <= 0;
            digit <= (digit + 1) mod 8;
         else
            count <= count + 1;
         end if;

         an_r        <= (others => '1');
         an_r(digit) <= '0';
         ca_r        <= not seg_i(8 * digit + 7 downto 8 * digit);
      end if;
   end process p_scan;

   an_o <= an_r;
   ca_o <= ca_r;

end architecture synthesis;
