-- The UART's baud rates: those that 0xFFFFFF9F takes (board_io.vhd), which
-- the on-board debugger offers too (dbg/dbg_set.vhd), and the cycles of a
-- bit at a rate.
--
-- THEORY OF OPERATION
-- C_UART_RATES lists the rates in bit/s, from the slowest. Every one is a
-- rate of termios, so that nicelink.py's --baud takes it, and the board's
-- USB serial chip, which makes its rates from 12 MHz, makes them all, and
-- 1, 1.5, and 2 Mbaud exactly. uart_divisor() rounds G_CLOCK_HZ / rate to
-- the nearest cycle: at 100 MHz and 90 MHz every rate is made to within
-- 0.5 %. A rate whose bit is shorter than C_UART_DIV_MIN cycles is not
-- taken, as the receiver samples a bit in its middle, and a bit of few
-- cycles rounds too far; that happens only at the slow clocks of the
-- testbenches.
--
-- RESET
-- None; constants and functions only.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;

package uart_pkg is

   type t_uart_rates is array (natural range <>) of positive;

   constant C_UART_RATES   : t_uart_rates := (115_200, 230_400, 460_800, 921_600, 1_000_000, 1_500_000, 2_000_000);
   constant C_UART_DIV_MIN : positive     := 8;

   -- The cycles of a bit at a rate, rounded
   pure function uart_divisor (clock_hz : positive; rate : positive) return natural;

   -- The index of a rate in C_UART_RATES, or -1 when it is not there
   pure function uart_rate_index (rate : std_logic_vector(31 downto 0)) return integer;

end package uart_pkg;

package body uart_pkg is

   pure function uart_divisor (clock_hz : positive; rate : positive) return natural is
   begin
      return (clock_hz + rate / 2) / rate;
   end function uart_divisor;

   pure function uart_rate_index (rate : std_logic_vector(31 downto 0)) return integer is
   begin
      for i in C_UART_RATES'range loop
         if rate = std_logic_vector(to_unsigned(C_UART_RATES(i), 32)) then
            return i;
         end if;
      end loop;
      return -1;
   end function uart_rate_index;

end package body uart_pkg;
