-- The PS/2 keyboard's lines. It takes the frames that the keyboard sends on
-- its clock and data lines, and gives each byte of them, a scan code, for
-- kbd_ps2_ascii.vhd. It also sets the keyboard's three LEDs, Scroll Lock,
-- Num Lock, and CAPS LOCK, from leds_i, whenever they change. On the
-- Nexys4DDR the keyboard is a USB keyboard, which the board's PIC24 turns
-- into PS/2.
--
-- THEORY OF OPERATION
-- The lines are open drain: the keyboard and the host each pull a line low
-- or let it go, and a pull-up makes it high. The keyboard drives the clock,
-- at 10 to 16.7 kHz, in both directions.
--
-- From the keyboard, a frame is 11 bits: a start bit (0), the eight bits of
-- the byte, LSB first, an odd parity bit, and a stop bit (1). The keyboard
-- changes the data while the clock is high, and the receiver takes a bit at
-- each falling edge of the clock.
--
-- Both lines are synchronized, and the clock is filtered: it counts as low
-- or high only once it has been so for 1 us, so that a glitch or a slow
-- edge does not count as an edge. A frame whose start, parity, or stop bit
-- is wrong is dropped. If the clock stops for 200 us within a frame, the
-- frame is dropped too, so that a lost bit does not shift every frame after
-- it.
--
-- To the keyboard, the host sends a byte as a request: it holds the clock
-- low for 100 us, which stops the keyboard, pulls the data low, the start
-- bit, and lets the clock go. The keyboard then clocks the byte in: after
-- each of the first ten falling edges of its clock, the host puts the next
-- bit on the data, the eight bits, LSB first, the odd parity, and the stop
-- bit, a 1, for which it lets the data go. At the eleventh falling edge the
-- keyboard holds the data low, its acknowledge, and then lets both lines
-- go. A request starts only when both lines have been high for 100 us, so
-- not within a frame from the keyboard, and the receiver ignores the lines
-- while the host sends. A change of the LEDs starts only when they have
-- been high for G_STILL_MS, 100 ms on the board, so after the keys that
-- changed them, and seldom while the keyboard has a key to send. If the
-- keyboard does not clock the byte in within 200 ms, the host lets the
-- lines go and gives up.
--
-- The LEDs are a command, ED, and a byte with Scroll Lock in bit 0, Num Lock
-- in bit 1, and CAPS LOCK in bit 2. The keyboard answers each of the two
-- bytes with FA. The host sends ED when leds_i differ from the LEDs last
-- sent, and the LED byte once FA has come, or 200 ms after ED without it:
-- a keyboard that has taken ED waits for the LED byte and sends no keys
-- until it comes, and the Nexys4DDR's PIC24, which passes the LEDs on over
-- USB, can answer late. The LED byte's FA, or FE, resend, in place of
-- either FA, ends the change. Other bytes, such as the codes of a key,
-- that come while the host waits for FA are passed on and do not end the
-- wait. Without the LED byte's FA in 200 ms, the host sends ED and the LED
-- byte again, up to C_TRIES times more: now and then the PIC24 takes the
-- LED byte, never answers it, and sends no keys until it gets ED again.
-- After that the change is not tried again until leds_i change again: a
-- keyboard that does not take the command is then asked 1 + C_TRIES times
-- per change, not again and again. The LEDs are
-- sent at reset, and again when the keyboard says AA, which it does after
-- its self-test, when it is plugged in: that is a change of its own, with
-- all its tries, whatever the change before it used up. The answers, FA
-- and AA, go to data_o as any byte does, and kbd_ps2_ascii.vhd ignores
-- them.
--
-- The lines' outputs ps2_clk_o and ps2_data_o are registers of their own,
-- copies of the state machine's lines a cycle later, which drive nothing
-- else, so that they fit in the I/O tile, and their inputs pass through two
-- registers, the first of each in the I/O tile (IOB TRUE in the board's
-- XDC). The board's pin is pulled low while its output is 0, and released
-- while it is 1.
--
-- data_valid_o is '1' for one clock cycle with each byte. There is no ready:
-- a frame is 11 bits, so a byte comes at most every 0.66 ms, and the user
-- of data_o must take each byte before the next one comes.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) clk_i runs at G_CLOCK_HZ, at least 1 MHz.
-- b) The lines have pull-ups.
--
-- RESET
-- Synchronous to clk_i, by rst_i. It drops the frame that is being received,
-- ends a byte that is being sent and lets the lines go, and sends the LEDs
-- again.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity kbd_ps2 is
   generic (
      G_CLOCK_HZ : natural;
      G_STILL_MS : natural := 100
   );
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;

      -- The pins of the keyboard, open drain: an output of 0 pulls the line
      -- low, and 1 lets it go
      ps2_clk_i    : in  std_logic;
      ps2_data_i   : in  std_logic;
      ps2_clk_o    : out std_logic;
      ps2_data_o   : out std_logic;

      -- The keyboard's LEDs: Scroll Lock in bit 0, Num Lock in bit 1, and
      -- CAPS LOCK in bit 2
      leds_i       : in  std_logic_vector(2 downto 0);

      -- The bytes from the keyboard
      data_valid_o : out std_logic;
      data_o       : out std_logic_vector(7 downto 0)
   );
end entity kbd_ps2;

architecture synthesis of kbd_ps2 is

   -- Clock cycles of the filter, 1 us, of the timeout of a frame, 200 us, of
   -- the quiet lines before a request and the clock held low in it, 100 us,
   -- of the wait for the keyboard, 200 ms, and of the still lines before a
   -- change of the LEDs, G_STILL_MS
   constant C_FILTER  : natural := G_CLOCK_HZ / 1_000_000 + 1;
   constant C_TIMEOUT : natural := G_CLOCK_HZ / 5_000;
   constant C_QUIET   : natural := G_CLOCK_HZ / 10_000;
   constant C_STILL   : natural := G_CLOCK_HZ / 1000 * G_STILL_MS;
   constant C_WAIT    : natural := G_CLOCK_HZ / 5;

   -- The command, and the answers
   constant C_SET_LEDS : std_logic_vector(7 downto 0) := X"ED";
   constant C_ACK      : std_logic_vector(7 downto 0) := X"FA";
   constant C_PASSED   : std_logic_vector(7 downto 0) := X"AA";
   constant C_RESEND   : std_logic_vector(7 downto 0) := X"FE";

   -- The times that a change of the LEDs is sent again without an answer
   constant C_TRIES : natural := 2;

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

   -- The cycles that both lines have been high, up to C_QUIET and C_STILL
   signal quiet_cnt : natural range 0 to C_QUIET := 0;
   signal still_cnt : natural range 0 to C_STILL := 0;

   -- The host's side. ST_IDLE receives; ST_HOLD holds the clock low, and
   -- then the data; ST_SEND puts the bits on the data; ST_DONE waits for
   -- the lines to go high after the acknowledge; ST_ANSWER receives, and
   -- waits for FA.
   type   t_state is (ST_IDLE, ST_HOLD, ST_SEND, ST_DONE, ST_ANSWER);
   signal state    : t_state := ST_IDLE;
   signal wait_cnt : natural range 0 to C_WAIT := 0;

   -- The byte being sent, its parity, and the stop bit, the next in bit 0,
   -- and the falling edges so far
   signal tx_bits  : std_logic_vector(9 downto 0) := (others => '1');
   signal tx_edges : natural range 0 to 10 := 0;
   signal tx_ack   : std_logic := '0';

   -- The LEDs last sent, those being sent, whether they are sent again,
   -- whether ED has been taken, so that the LED byte comes next, and the
   -- times that the change has been sent again
   signal leds_sent : std_logic_vector(2 downto 0) := "000";
   signal leds_new  : std_logic_vector(2 downto 0) := "000";
   signal resend    : std_logic := '1';
   signal second    : std_logic := '0';
   signal tries     : natural range 0 to C_TRIES := 0;

   -- The state machine's lines, and their copies in the I/O tiles
   signal clk_out  : std_logic := '1';
   signal data_out : std_logic := '1';
   signal clk_q    : std_logic := '1';
   signal data_q   : std_logic := '1';

begin

   p_ps2 : process (clk_i)
      variable fall_v  : boolean;
      variable frame_v : std_logic_vector(10 downto 0);
      variable rx_v    : boolean;

      -- The end of a change of the LEDs, taken or not
      procedure finish is
      begin
         leds_sent <= leds_new;
         second    <= '0';
         state     <= ST_IDLE;
      end procedure finish;

      -- A byte to send, with its odd parity and the stop bit
      procedure start(b : std_logic_vector(7 downto 0)) is
      begin
         tx_bits  <= '1' & not (xor b) & b;
         tx_edges <= 0;
         wait_cnt <= 0;
         clk_out  <= '0';
         state    <= ST_HOLD;
      end procedure start;

   begin
      if rising_edge(clk_i) then
         clk_sync  <= clk_sync(0) & ps2_clk_i;
         data_sync <= data_sync(0) & ps2_data_i;

         data_valid_o <= '0';

         -- The filtered clock, and its falling edges
         fall_v := false;
         if clk_sync(1) = clk_filt then
            filt_cnt <= 0;
         elsif filt_cnt /= C_FILTER then
            filt_cnt <= filt_cnt + 1;
         else
            filt_cnt <= 0;
            clk_filt <= clk_sync(1);
            fall_v   := clk_sync(1) = '0';
         end if;

         if clk_sync(1) = '1' and data_sync(1) = '1' then
            if quiet_cnt /= C_QUIET then
               quiet_cnt <= quiet_cnt + 1;
            end if;
            if still_cnt /= C_STILL then
               still_cnt <= still_cnt + 1;
            end if;
         else
            quiet_cnt <= 0;
            still_cnt <= 0;
         end if;

         if wait_cnt /= C_WAIT then
            wait_cnt <= wait_cnt + 1;
         end if;

         -- The receiver, while the host does not send
         rx_v := state = ST_IDLE or state = ST_ANSWER;
         if rx_v then
            if bits /= 0 and idle_cnt /= C_TIMEOUT then
               idle_cnt <= idle_cnt + 1;
            end if;
            if idle_cnt = C_TIMEOUT then
               bits     <= 0;
               idle_cnt <= 0;
            end if;
            if fall_v then
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
                     if frame_v(8 downto 1) = C_PASSED then
                        -- A keyboard plugged in: the LEDs again, with all
                        -- the tries
                        resend <= '1';
                        tries  <= 0;
                     end if;
                     if state = ST_ANSWER then
                        -- FA after ED sends the LED byte, and FA after it
                        -- or FE ends the change; other bytes are keys
                        if frame_v(8 downto 1) = C_ACK and second = '0' then
                           second <= '1';
                           state  <= ST_IDLE;
                        elsif frame_v(8 downto 1) = C_ACK or
                              frame_v(8 downto 1) = C_RESEND then
                           tries <= 0;
                           finish;
                        end if;
                     end if;
                  end if;
               end if;
            end if;
         else
            bits     <= 0;
            idle_cnt <= 0;
         end if;

         -- The host's side
         case state is

            when ST_IDLE =>
               if bits = 0 and quiet_cnt = C_QUIET then
                  if second = '1' then
                     start("00000" & leds_new);
                  elsif still_cnt = C_STILL and
                        (resend = '1' or leds_i /= leds_sent) then
                     leds_new <= leds_i;
                     resend   <= '0';
                     if resend = '0' then
                        tries <= 0;
                     end if;
                     start(C_SET_LEDS);
                  end if;
               end if;

            when ST_HOLD =>
               -- The clock low for 100 us, then the data too, then the
               -- clock goes 1 us later
               if wait_cnt = C_QUIET then
                  data_out <= '0';
               end if;
               if wait_cnt = C_QUIET + C_FILTER then
                  clk_out  <= '1';
                  wait_cnt <= 0;
                  state    <= ST_SEND;
               end if;

            when ST_SEND =>
               if fall_v then
                  if tx_edges /= 10 then
                     data_out <= tx_bits(0);
                     tx_bits  <= '1' & tx_bits(9 downto 1);
                     tx_edges <= tx_edges + 1;
                  else
                     tx_ack <= not data_sync(1);
                     state  <= ST_DONE;
                  end if;
               end if;
               if wait_cnt = C_WAIT then
                  data_out <= '1';
                  finish;
               end if;

            when ST_DONE =>
               if clk_sync(1) = '1' and data_sync(1) = '1' then
                  if tx_ack = '1' then
                     wait_cnt <= 0;
                     state    <= ST_ANSWER;
                  else
                     finish;
                  end if;
               end if;
               if wait_cnt = C_WAIT then
                  finish;
               end if;

            when ST_ANSWER =>
               -- Without FA, the LED byte still follows ED, and the change
               -- is sent again after the LED byte
               if wait_cnt = C_WAIT then
                  if second = '0' then
                     second <= '1';
                     state  <= ST_IDLE;
                  else
                     if tries /= C_TRIES then
                        tries  <= tries + 1;
                        resend <= '1';
                     end if;
                     finish;
                  end if;
               end if;

         end case;

         clk_q  <= clk_out;
         data_q <= data_out;

         if rst_i = '1' then
            bits         <= 0;
            idle_cnt     <= 0;
            data_valid_o <= '0';
            state        <= ST_IDLE;
            leds_sent    <= "000";
            resend       <= '1';
            second       <= '0';
            tries        <= 0;
            clk_out      <= '1';
            data_out     <= '1';
            clk_q        <= '1';
            data_q       <= '1';
         end if;
      end if;
   end process p_ps2;

   ps2_clk_o  <= clk_q;
   ps2_data_o <= data_q;

end architecture synthesis;
