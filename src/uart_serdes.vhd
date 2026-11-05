-- Copied from https://github.com/MJoergen/cmod-s7 (src/uart_serdes.vhd, commit d3d544d), MIT License.
-- Changed here: the receiver forwarded bytes with bit 7 set one bit early, so
-- they came out wrong, and passed on frames with a bad Stop bit. It now takes
-- all ten bits and checks the Start and Stop bits, and starts a frame on a
-- falling edge only. A bit now takes G_DIVISOR clock cycles, not G_DIVISOR + 1.
-- The layout and names follow doc/CODING_STYLE.md.
-- Added here: rx_break_o pulses for a break, a frame whose ten bits are all 0.
-- And the bit's cycles come from div_i, which is taken once the line is
-- quiet, so that the baud rate can change while the system runs.
--
-- THEORY OF OPERATION
-- A bit takes divisor cycles, which is G_DIVISOR after reset. When div_i
-- differs from it, the new value is taken in a cycle where neither a
-- change of div_i nor the transmitter's last byte is less than G_QUIET
-- cycles ago, no byte is offered, and the receiver is idle, with no Start
-- bit beginning. So no frame is sent or received with two bit times, and
-- the bytes sent soon after the change, such as the debug link's answer
-- to the write that set the new rate, go out at the old one, however long
-- the line was quiet before it.
--
-- RESET
-- Synchronous. Reset ends the frames, and takes G_DIVISOR.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;

-- This provides a byte-level interface to UART serial interface.
-- Protocol is 8-N-1, i.e. one start bit, 8 data bits, no parity, and one stop bit.
-- Data is transferred LSB first.

entity uart_serdes is
   generic (
      -- The cycles of a bit after reset, and those of a quiet transmitter
      -- before a new div_i is taken
      G_DIVISOR : positive;
      G_QUIET   : natural
   );
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;
      -- The cycles of a bit, 1 or more
      div_i      : in  std_logic_vector(15 downto 0);
      -- Byte level interface
      tx_valid_i : in  std_logic;
      tx_ready_o : out std_logic;
      tx_data_i  : in  std_logic_vector(7 downto 0);
      rx_valid_o : out std_logic;
      rx_ready_i : in  std_logic;
      rx_data_o  : out std_logic_vector(7 downto 0);
      -- A pulse for a break: a frame of ten 0 bits, the Stop bit included
      rx_break_o : out std_logic;
      -- UART serial interface
      uart_tx_o  : out std_logic;
      uart_rx_i  : in  std_logic
   );
end entity uart_serdes;

architecture synthesis of uart_serdes is

   type t_state is (
      IDLE_ST,
      BUSY_ST
   );

   signal tx_data  : std_logic_vector(9 downto 0) := (others => '1');
   signal tx_state : t_state                      := IDLE_ST;
   signal divisor  : natural range 1 to 2 ** 16 - 1 := G_DIVISOR;
   signal quiet    : natural range 0 to G_QUIET      := 0;
   signal div_d    : std_logic_vector(15 downto 0)   := (others => '0');

   signal tx_counter : natural range 0 to 2 ** 16 - 1;

   signal rx_data    : std_logic_vector(10 downto 0);
   signal rx_state   : t_state                      := IDLE_ST;
   signal rx_counter : natural range 0 to 2 ** 16 - 1;
   signal rx_prev    : std_logic                    := '1';

begin

   assert G_DIVISOR < 2 ** 16
      report "uart_serdes: G_DIVISOR must fit div_i"
      severity failure;

   --------------------------------------------
   -- The bit's cycles: div_i, once the line is quiet
   --------------------------------------------

   p_div : process (clk_i)
   begin
      if rising_edge(clk_i) then
         div_d <= div_i;
         if tx_state = BUSY_ST or tx_valid_i = '1' or div_i /= div_d then
            quiet <= G_QUIET;
         elsif quiet > 0 then
            quiet <= quiet - 1;
         elsif rx_state = IDLE_ST and not (rx_prev = '1' and uart_rx_i = '0') and to_integer(unsigned(div_i)) > 0 then
            divisor <= to_integer(unsigned(div_i));
         end if;

         if rst_i = '1' then
            divisor <= G_DIVISOR;
            quiet   <= 0;
         end if;
      end if;
   end process p_div;


   --------------------------------------------
   -- Handler UART Transmission
   --------------------------------------------

   tx_ready_o <= '1' when tx_state = IDLE_ST else
                 '0';

   uart_tx_o <= tx_data(0);

   p_tx : process (clk_i)
   begin
      if rising_edge(clk_i) then

         case tx_state is

            when IDLE_ST =>
               if tx_valid_i = '1' then
                  tx_data    <= "1" & tx_data_i & "0"; -- Stop + Data + Start
                  tx_counter <= divisor - 1;
                  tx_state   <= BUSY_ST;
               end if;

            when BUSY_ST =>
               if tx_counter > 0 then
                  tx_counter <= tx_counter - 1;
               else
                  if or (tx_data(9 downto 1)) = '1' then
                     tx_counter <= divisor - 1;
                     tx_data    <= "0" & tx_data(9 downto 1);
                  else
                     tx_data(0) <= '1';
                     tx_state   <= IDLE_ST;
                  end if;
               end if;

         end case;

         if rst_i = '1' then
            tx_data(0) <= '1';
            tx_state   <= IDLE_ST;
         end if;
      end if;
   end process p_tx;


   --------------------------------------------
   -- Handler UART Reception
   --------------------------------------------

   p_rx : process (clk_i)
   begin
      if rising_edge(clk_i) then
         rx_prev    <= uart_rx_i;
         rx_break_o <= '0';
         if rx_ready_i = '1' then
            rx_valid_o <= '0';
         end if;

         case rx_state is

            when IDLE_ST =>
               -- A falling edge, so that a Stop bit that was low is not taken as a Start bit.
               if rx_prev = '1' and uart_rx_i = '0' then
                  rx_data     <= (others => '1');
                  rx_data(10) <= '0';          -- Marker: reaches bit 0 after ten samples
                  rx_counter  <= divisor / 2;
                  rx_state    <= BUSY_ST;
               end if;

            when BUSY_ST =>
               if rx_counter > 0 then
                  rx_counter <= rx_counter - 1;
               else
                  rx_counter <= divisor - 1;
                  rx_data    <= uart_rx_i & rx_data(10 downto 1);
               end if;

               if rx_data(0) = '0' then
                  -- Start + 8 data + Stop sampled. Only forward if Start and Stop are correct.
                  if rx_data(1) = '0' and rx_data(10) = '1' then
                     rx_data_o  <= rx_data(9 downto 2);
                     rx_valid_o <= '1';
                  end if;
                  if or(rx_data(10 downto 1)) = '0' then
                     rx_break_o <= '1';
                  end if;
                  rx_state <= IDLE_ST;
               end if;

         end case;

         if rst_i = '1' then
            rx_valid_o <= '0';
            rx_break_o <= '0';
            rx_state   <= IDLE_ST;
         end if;
      end if;
   end process p_rx;

end architecture synthesis;

