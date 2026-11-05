-- The bytes of an SD card in SPI mode, mode 0: one byte out on MOSI and
-- one in from MISO at a time, at the slow clock of the start-up or the
-- fast clock of the data (src/sd/sd_spi.vhd).
--
-- THEORY OF OPERATION
-- Each bit takes 2 * H cycles of clk_i, H the half period of the clock
-- that fast_i chooses: sclk_o is low for H cycles, with the bit on mosi_o,
-- then high for H. The card takes MOSI on the rising edge of its clock,
-- and changes MISO after the falling edge.
--
-- sclk_o and mosi_o reach the pins through one register, and the pin of
-- MISO reaches miso_i through two, the first in the I/O tile and the second
-- a synchronizer (src/sd/sd.vhd). So the card's clock rises at its pin one
-- cycle after sclk_o, and the bit is sampled at the pin one cycle after
-- that, which miso_i shows two cycles later: G_LAT = 3 cycles after the
-- first cycle of sclk_o high. At 25 MHz, H = 2, that is in the middle of
-- the bit at the pin: the card changes MISO up to 14 ns after the falling
-- edge, 1.4 cycles, and the next falling edge comes 2.6 cycles after
-- that. At the slow clock the bit has long settled.
--
-- The samples come G_LAT cycles late. The byte ends, with done_o, when
-- the eighth sample has been taken and the last period of the clock is
-- over, whichever comes later: at the fast clock the sample, and at the
-- slow clock the period, as the sample comes early in the bit's high
-- half. So every period of the clock is whole, and the next byte can
-- start in the cycle of done_o.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) start_i comes only while no byte is under way: at reset, or with
--    done_o, or after it. fast_i holds while a byte is under way.
-- b) miso_i is the pin of MISO through two registers, and sclk_o and
--    mosi_o reach their pins through one, as described above.
--
-- RESET
-- Synchronous. Reset abandons a byte: sclk_o goes low and mosi_o high.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity sd_spi_byte is
   generic (
      -- The half periods of the slow and the fast clock, in cycles of clk_i
      G_SLOW_HALF : positive;
      G_FAST_HALF : positive range 2 to positive'high;
      -- The cycles from the first of sclk_o high to the bit on miso_i
      G_LAT       : positive := 3
   );
   port (
      clk_i   : in  std_logic;
      rst_i   : in  std_logic;
      fast_i  : in  std_logic;
      start_i : in  std_logic;
      data_i  : in  std_logic_vector(7 downto 0);
      done_o  : out std_logic := '0';
      data_o  : out std_logic_vector(7 downto 0);
      sclk_o  : out std_logic;
      mosi_o  : out std_logic;
      miso_i  : in  std_logic
   );
end entity sd_spi_byte;

architecture synthesis of sd_spi_byte is

   -- Whether bits are going out, and the bit, 7 down to 0, and the cycle
   -- of it, from 0 to 2 * H - 1
   signal active_r : std_logic                     := '0';
   signal bit_r    : natural range 0 to 7          := 7;
   signal phase_r  : natural range 0 to 2 * G_SLOW_HALF + 2 * G_FAST_HALF;
   signal half_r   : natural range 1 to G_SLOW_HALF + G_FAST_HALF;
   signal tx_r     : std_logic_vector(7 downto 0)  := (others => '1');
   signal rx_r     : std_logic_vector(7 downto 0)  := (others => '1');

   -- The sample strobes on their way, the samples still to take, and
   -- whether the byte's done_o is still to come
   signal strobe_r : std_logic_vector(G_LAT downto 1) := (others => '0');
   signal left_r   : natural range 0 to 8            := 0;
   signal pend_r   : std_logic                        := '0';

begin

   sclk_o <= '1' when active_r = '1' and phase_r >= half_r else
             '0';
   mosi_o <= tx_r(7) when active_r = '1' else
             '1';
   data_o <= rx_r;

   p_byte : process (clk_i)
      -- Whether the eighth sample is in, and the clock's last period over,
      -- after this cycle
      variable last_v : boolean;
      variable idle_v : boolean;
   begin
      if rising_edge(clk_i) then
         done_o <= '0';

         -- The strobe of a bit starts in its first cycle of sclk_o high.
         strobe_r <= strobe_r(G_LAT - 1 downto 1) & '0';
         if active_r = '1' and phase_r = half_r then
            strobe_r(1) <= '1';
         end if;

         if strobe_r(G_LAT) = '1' then
            rx_r   <= rx_r(6 downto 0) & miso_i;
            left_r <= left_r - 1;
         end if;

         if active_r = '1' then
            if phase_r = 2 * half_r - 1 then
               phase_r <= 0;
               if bit_r = 0 then
                  active_r <= '0';
               else
                  bit_r <= bit_r - 1;
                  tx_r  <= tx_r(6 downto 0) & '1';
               end if;
            else
               phase_r <= phase_r + 1;
            end if;
         end if;

         -- The byte ends when its eighth sample is in and its last period
         -- of the clock is over, whichever comes later.
         last_v := left_r = 0 or (strobe_r(G_LAT) = '1' and left_r = 1);
         idle_v := active_r = '0' or (phase_r = 2 * half_r - 1 and bit_r = 0);
         if pend_r = '1' and last_v and idle_v then
            done_o <= '1';
            pend_r <= '0';
         end if;

         if start_i = '1' then
            active_r <= '1';
            bit_r    <= 7;
            phase_r  <= 0;
            tx_r     <= data_i;
            left_r   <= 8;
            pend_r   <= '1';
            if fast_i = '1' then
               half_r <= G_FAST_HALF;
            else
               half_r <= G_SLOW_HALF;
            end if;
         end if;

         if rst_i = '1' then
            active_r <= '0';
            done_o   <= '0';
            tx_r     <= (others => '1');
            strobe_r <= (others => '0');
            left_r   <= 0;
            pend_r   <= '0';
         end if;
      end if;
   end process p_byte;

end architecture synthesis;
