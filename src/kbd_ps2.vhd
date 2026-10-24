-- The receiver of a PS/2 keyboard. It takes the frames that the keyboard
-- sends on its clock and data lines, and gives each byte of them, a scan
-- code, for kbd_ps2_ascii.vhd. It only listens: it never drives the lines,
-- so it sends no commands to the keyboard, and the keyboard's LEDs are not
-- set. On the Nexys4DDR the keyboard is a USB keyboard, which the board's
-- PIC24 turns into PS/2.
--
-- THEORY OF OPERATION
-- The keyboard drives the clock, at 10 to 16.7 kHz, and changes the data
-- while the clock is high. A frame is 11 bits: a start bit (0), the eight
-- bits of the byte, LSB first, an odd parity bit, and a stop bit (1). The
-- receiver takes a bit at each falling edge of the clock.
--
-- Both lines are synchronized, and the clock is filtered: it counts as low
-- or high only once it has been so for 1 us, so that a glitch or a slow
-- edge does not count as an edge. A frame whose start, parity, or stop bit
-- is wrong is dropped. If the clock stops for 200 us within a frame, the
-- frame is dropped too, so that a lost bit does not shift every frame after
-- it.
--
-- data_valid_o is '1' for one clock cycle with each byte. There is no ready:
-- a frame is 11 bits, so a byte comes at most every 0.66 ms, and the next one must take it before.
--
-- RESET
-- Synchronous to clk_i, by rst_i. It drops the frame that is being received.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity kbd_ps2 is
   generic (
      G_CLOCK_HZ : natural
   );
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;

      -- The pins of the keyboard
      ps2_clk_i    : in  std_logic;
      ps2_data_i   : in  std_logic;

      -- The bytes from the keyboard
      data_valid_o : out std_logic;
      data_o       : out std_logic_vector(7 downto 0)
   );
end entity kbd_ps2;

architecture synthesis of kbd_ps2 is

   -- Clock cycles of the filter, 1 us, and of the timeout, 200 us
   constant C_FILTER  : natural := G_CLOCK_HZ / 1_000_000 + 1;
   constant C_TIMEOUT : natural := G_CLOCK_HZ / 5_000;

   -- The pins, synchronized
   signal clk_sync  : std_logic_vector(1 downto 0) := "11";
   signal data_sync : std_logic_vector(1 downto 0) := "11";
   attribute async_reg : string;
   attribute async_reg of clk_sync  : signal is "TRUE";
   attribute async_reg of data_sync : signal is "TRUE";

   -- The filtered clock, and the cycles that the input has differed from it
   signal clk_filt : std_logic := '1';
   signal filt_cnt : natural range 0 to C_FILTER := 0;

   -- The bits of the frame so far, the first in bit 0 once all are in
   signal frame    : std_logic_vector(10 downto 0) := (others => '0');
   signal bits     : natural range 0 to 11 := 0;
   signal idle_cnt : natural range 0 to C_TIMEOUT := 0;

begin

   p_rx : process (clk_i)
      variable frame_v : std_logic_vector(10 downto 0);
   begin
      if rising_edge(clk_i) then
         clk_sync  <= clk_sync(0) & ps2_clk_i;
         data_sync <= data_sync(0) & ps2_data_i;

         data_valid_o <= '0';

         if bits /= 0 and idle_cnt /= C_TIMEOUT then
            idle_cnt <= idle_cnt + 1;
         end if;
         if idle_cnt = C_TIMEOUT then
            bits     <= 0;
            idle_cnt <= 0;
         end if;

         if clk_sync(1) = clk_filt then
            filt_cnt <= 0;
         elsif filt_cnt /= C_FILTER then
            filt_cnt <= filt_cnt + 1;
         else
            filt_cnt <= 0;
            clk_filt <= clk_sync(1);
            if clk_sync(1) = '0' then
               -- A falling edge: take the bit
               frame_v  := data_sync(1) & frame(10 downto 1);
               frame    <= frame_v;
               idle_cnt <= 0;
               if bits /= 10 then
                  bits <= bits + 1;
               else
                  bits <= 0;
                  if frame_v(0) = '0' and frame_v(10) = '1' and
                     (xor frame_v(9 downto 1)) = '1' then
                     data_o       <= frame_v(8 downto 1);
                     data_valid_o <= '1';
                  end if;
               end if;
            end if;
         end if;

         if rst_i = '1' then
            bits         <= 0;
            idle_cnt     <= 0;
            data_valid_o <= '0';
         end if;
      end if;
   end process p_rx;

end architecture synthesis;
