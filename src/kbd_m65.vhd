-- The driver of the MEGA65 keyboard. The keyboard has a small FPGA of its own,
-- which scans the keys and drives the two LEDs. This driver talks to it over
-- three pins, the same on the R3 and the R6 boards: a clock and a data line
-- to the keyboard, and a data line from it. It reports which keys are
-- pressed, and sets the colour of the LEDs. It is written after
-- mega65kbd_to_matrix.vhdl of MiSTer2MEGA65, by Paul Gardner-Stephen and
-- sy2002, with the same timing on the pins.
--
-- THEORY OF OPERATION
-- The clock to the keyboard runs at 312.5 kHz. A frame is 141 of its
-- periods, numbered by phase:
-- * In phases 0 to 126 the driver sends the LED colours, one bit in each
--   period, and the keyboard sends the state of one key in each period, low
--   when the key is pressed. The bit from the keyboard is sampled just before
--   the rising edge of the clock, and the bit to it changes after the falling
--   edge.
-- * In phases 127 to 140 the clock stays high: a sync pulse, which starts the
--   next frame.
-- The bits from the keyboard are the key numbers of matrix_o. Keys 0 to 71
-- are the matrix of the C64 keyboard. 72 to 78 have lines of their own: CAPS
-- LOCK (set while it is locked), the cursor up and left keys, RESTORE, and
-- copies of INST/DEL and RETURN, which also come as keys 0 and 1. As in
-- MiSTer2MEGA65, keys 0 and 1 are taken from those copies, for the bits at
-- 0 and 1 arrive too late.
--
-- matrix_o has bit n set while key n is pressed. It changes once in each
-- frame, after phase 79, so about every 0.9 ms.
--
-- The LED colours are 24 bits of RGB each. The keyboard takes each LED's
-- colour twice, for its left and right halves, in the order BGR.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity kbd_m65 is
   generic (
      G_CLOCK_HZ : natural
   );
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;

      -- Bit n is set while key n is pressed
      matrix_o    : out std_logic_vector(79 downto 0);

      -- RGB colours of the LEDs, 0 for off
      power_rgb_i : in  std_logic_vector(23 downto 0);
      drive_rgb_i : in  std_logic_vector(23 downto 0);

      -- The pins to the keyboard
      kb_clk_o    : out std_logic;
      kb_data_o   : out std_logic;
      kb_data_i   : in  std_logic
   );
end entity kbd_m65;

architecture synthesis of kbd_m65 is

   -- Clock cycles in half a period of the keyboard clock
   constant C_HALF_PERIOD : natural := G_CLOCK_HZ / 625_000;

   constant C_SYNC_PHASE : natural := 127;
   constant C_LAST_PHASE : natural := 140;
   constant C_NUM_KEYS   : natural := 80;

   signal divider : natural range 0 to C_HALF_PERIOD - 1 := 0;
   signal kbd_clk : std_logic := '0';
   signal sync    : std_logic := '0';
   signal phase   : natural range 0 to C_LAST_PHASE := 0;

   -- The input, synchronised
   signal data_in : std_logic_vector(1 downto 0) := "11";

   -- The bits from the keyboard in this frame, low while a key is pressed
   signal keys_n : std_logic_vector(C_NUM_KEYS - 1 downto 0) := (others => '1');

   -- The bits to the keyboard, from bit 127 down
   signal leds : std_logic_vector(127 downto 0) := (others => '0');

   -- RGB to the BGR of the keyboard
   function bgr(rgb : std_logic_vector(23 downto 0)) return std_logic_vector is
   begin
      return rgb(7 downto 0) & rgb(15 downto 8) & rgb(23 downto 16);
   end function bgr;

begin

   p_kbd : process (clk_i)
   begin
      if rising_edge(clk_i) then
         data_in <= data_in(0) & kb_data_i;

         if divider /= C_HALF_PERIOD - 1 then
            divider <= divider + 1;
         else
            divider  <= 0;
            kbd_clk  <= not kbd_clk;
            -- The pin follows kbd_clk half a period later, so a rising edge
            -- of the pin comes in the same cycle as the sampling below.
            kb_clk_o <= kbd_clk or sync;

            if kbd_clk = '1' then
               -- The pin rises: take the key of this phase
               if phase < C_NUM_KEYS then
                  keys_n(phase) <= data_in(1);
               elsif phase = C_NUM_KEYS then
                  matrix_o    <= not keys_n;
                  matrix_o(0) <= not keys_n(76);
                  matrix_o(1) <= not keys_n(77);
               end if;
            else
               -- The pin falls: the next phase, and the next bit to the
               -- keyboard
               if phase = C_LAST_PHASE then
                  phase <= 0;
               else
                  phase <= phase + 1;
               end if;

               if phase = C_SYNC_PHASE then
                  sync               <= '1';
                  leds               <= (others => '0');
                  leds(23 downto 0)  <= bgr(drive_rgb_i);
                  leds(47 downto 24) <= bgr(drive_rgb_i);
                  leds(71 downto 48) <= bgr(power_rgb_i);
                  leds(95 downto 72) <= bgr(power_rgb_i);
               elsif phase = C_LAST_PHASE then
                  sync <= '0';
               elsif phase < C_SYNC_PHASE then
                  kb_data_o <= leds(127);
                  leds      <= leds(126 downto 0) & '0';
               end if;
            end if;
         end if;

         if rst_i = '1' then
            divider  <= 0;
            kbd_clk  <= '0';
            sync     <= '0';
            phase    <= 0;
            matrix_o <= (others => '0');
         end if;
      end if;
   end process p_kbd;

end architecture synthesis;
