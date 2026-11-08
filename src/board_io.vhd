-- The board's devices at 0xFFFFFF90-9F (src/nicemon.vhd), with G_BOARD_IO
-- (the Nexys4DDR): the 16 LEDs, the levels of the two RGB LEDs, the
-- segments of the seven-segment display, the five buttons, and the 16
-- switches. On every board, also the size of the RAM and the UART's baud
-- rate. The network station's registers are at 0xFFFFFFB0-BF, in
-- src/devices.vhd.
--
-- THEORY OF OPERATION
-- nicemon serves one request in a cycle, the link's or the core's, and
-- gives it here with stb_i when it is to 0xFFFFFF90-9F; addr_i is the word's
-- offset. A write sets the register of its word in the same cycle. rdata_o
-- is the word at addr_i, combinationally, which nicemon registers for its
-- acknowledge in the next cycle. The registers, by their offset:
--   0  The LEDs, bit n for LED n. Read and write.
--   1  RGB LED 0: bits 11..8 red, 7..4 green, 3..0 blue. Read and write.
--   2  RGB LED 1, as 1.
--   3  The segments of digits 3..0, a byte each, digit 0 in bits 7..0.
--      Read and write.
--   4  The segments of digits 7..4, as 3.
--   5  The buttons, bit 0 for the center one, then up, left, right, and
--      down. Read only.
--   6  The switches, bit n for switch n. Read only.
--   E  The words of the RAM, G_RAM_WORDS, on every board. Read only.
--   F  The UART's baud rate in bit/s, on every board: G_UART_BAUDRATE
--      after reset. A write of one of C_UART_RATES (uart_pkg.vhd), 115200
--      to 2000000, or of G_UART_BAUDRATE, sets it, and a write of any
--      other value is dropped. A rate of C_UART_RATES whose bit would be
--      shorter than C_UART_DIV_MIN cycles is dropped too. uart_div_o is the bit's cycles,
--      G_CLOCK_HZ / rate rounded, which uart_serdes.vhd takes once its
--      line is quiet. Read and write.
-- The other words, and words 0 to 6 without G_BOARD_IO, read 0 and take
-- no write, so then the outputs stay 0. The buttons and the switches pass
-- through two registers, which synchronize them to the clock.
--
-- With G_FORMAL, it states the properties that formal/board_io.sby proves:
-- a write to a register's word sets it, the registers change only so, and
-- each word reads its register, its input, its constant, or 0; and the
-- baud rate is always one that a write may set, with its divisor.
--
-- RESET
-- Synchronous. Reset clears the writable registers, but for the baud
-- rate, which it sets to G_UART_BAUDRATE.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;
   use ieee.numeric_std_unsigned.all;

library work;
   use work.uart_pkg.all;

entity board_io is
   generic (
      G_BOARD_IO      : boolean;
      -- The words of the RAM, which word E reads
      G_RAM_WORDS     : natural := 0;
      -- The clock, and the UART's baud rate after reset, for word F
      G_CLOCK_HZ      : positive := 100_000_000;
      G_UART_BAUDRATE : positive := 230_400;
      -- The properties for formal/board_io.sby
      G_FORMAL        : boolean := false
   );
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;
      -- The request served in this cycle, when it is to 0xFFFFFF90-9F
      stb_i       : in  std_logic;
      we_i        : in  std_logic;
      addr_i      : in  std_logic_vector(3 downto 0);
      wdata_i     : in  std_logic_vector(31 downto 0);
      rdata_o     : out std_logic_vector(31 downto 0);
      -- The board
      led_o       : out std_logic_vector(15 downto 0);
      rgb0_o      : out std_logic_vector(11 downto 0);
      rgb1_o      : out std_logic_vector(11 downto 0);
      seg_o       : out std_logic_vector(63 downto 0);
      btn_i       : in  std_logic_vector(4 downto 0);
      sw_i        : in  std_logic_vector(15 downto 0);
      -- The UART's baud rate, and the cycles of its bit
      uart_baud_o : out std_logic_vector(31 downto 0);
      uart_div_o  : out std_logic_vector(15 downto 0)
   );
end entity board_io;

architecture synthesis of board_io is

   -- The cycles of a bit at a rate, rounded
   pure function divisor (rate : positive) return natural is
   begin
      return uart_divisor(G_CLOCK_HZ, rate);
   end function divisor;

   -- The divisor of a rate that word F takes, or 0 for one it drops: one
   -- of C_UART_RATES whose bit is long enough, or G_UART_BAUDRATE
   pure function rate_div (rate : std_logic_vector(31 downto 0)) return natural is
   begin
      if rate = std_logic_vector(to_unsigned(G_UART_BAUDRATE, 32)) then
         return divisor(G_UART_BAUDRATE);
      end if;
      for i in C_UART_RATES'range loop
         if rate = std_logic_vector(to_unsigned(C_UART_RATES(i), 32)) and
            divisor(C_UART_RATES(i)) >= C_UART_DIV_MIN then
            return divisor(C_UART_RATES(i));
         end if;
      end loop;
      return 0;
   end function rate_div;

   constant C_BAUD : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(G_UART_BAUDRATE, 32));
   constant C_DIV  : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(divisor(G_UART_BAUDRATE), 16));

   signal led      : std_logic_vector(15 downto 0) := (others => '0');
   signal rgb0     : std_logic_vector(11 downto 0) := (others => '0');
   signal rgb1     : std_logic_vector(11 downto 0) := (others => '0');
   signal seg      : std_logic_vector(63 downto 0) := (others => '0');
   signal btn      : std_logic_vector(4 downto 0)  := (others => '0');
   signal sw       : std_logic_vector(15 downto 0) := (others => '0');
   signal btn_sync : std_logic_vector(4 downto 0)  := (others => '0');
   signal sw_sync  : std_logic_vector(15 downto 0) := (others => '0');
   signal baud     : std_logic_vector(31 downto 0) := C_BAUD;
   signal div      : std_logic_vector(15 downto 0) := C_DIV;

   attribute async_reg : string;
   attribute async_reg of btn_sync : signal is "TRUE";
   attribute async_reg of sw_sync  : signal is "TRUE";
   attribute async_reg of btn      : signal is "TRUE";
   attribute async_reg of sw       : signal is "TRUE";

begin

   assert divisor(G_UART_BAUDRATE) >= 1 and divisor(C_UART_RATES(0)) < 2 ** 16
      report "board_io: a bit of the UART must take 1 to 65535 cycles"
      severity failure;

   p_write : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if stb_i = '1' and we_i = '1' and G_BOARD_IO then

            case addr_i is
               when X"0"   => led              <= wdata_i(15 downto 0);
               when X"1"   => rgb0             <= wdata_i(11 downto 0);
               when X"2"   => rgb1             <= wdata_i(11 downto 0);
               when X"3"   => seg(31 downto 0)  <= wdata_i;
               when X"4"   => seg(63 downto 32) <= wdata_i;
               when others => null;
            end case;

         end if;

         if stb_i = '1' and we_i = '1' then

            case addr_i is
               when X"F"   =>
                  if rate_div(wdata_i) /= 0 then
                     baud <= wdata_i;
                     div  <= std_logic_vector(to_unsigned(rate_div(wdata_i), 16));
                  end if;
               when others => null;
            end case;

         end if;

         if rst_i = '1' then
            led  <= (others => '0');
            rgb0 <= (others => '0');
            rgb1 <= (others => '0');
            seg  <= (others => '0');
            baud <= C_BAUD;
            div  <= C_DIV;
         end if;
      end if;
   end process p_write;

   p_read : process (all)
   begin
      rdata_o <= (others => '0');
      if addr_i = X"E" then
         rdata_o <= std_logic_vector(to_unsigned(G_RAM_WORDS, 32));
      elsif addr_i = X"F" then
         rdata_o <= baud;
      elsif G_BOARD_IO then

         case addr_i is
            when X"0"   => rdata_o(15 downto 0) <= led;
            when X"1"   => rdata_o(11 downto 0) <= rgb0;
            when X"2"   => rdata_o(11 downto 0) <= rgb1;
            when X"3"   => rdata_o              <= seg(31 downto 0);
            when X"4"   => rdata_o              <= seg(63 downto 32);
            when X"5"   => rdata_o(4 downto 0)  <= btn;
            when X"6"   => rdata_o(15 downto 0) <= sw;
            when others => null;
         end case;

      end if;
   end process p_read;

   p_sync : process (clk_i)
   begin
      if rising_edge(clk_i) then
         btn_sync <= btn_i;
         btn      <= btn_sync;
         sw_sync  <= sw_i;
         sw       <= sw_sync;
      end if;
   end process p_sync;

   led_o  <= led;
   rgb0_o <= rgb0;
   rgb1_o <= rgb1;
   seg_o  <= seg;

   uart_baud_o <= baud;
   uart_div_o  <= div;


   gen_formal : if G_FORMAL generate
      -- A write to the word of register n in this cycle
      signal f_wr : std_logic_vector(4 downto 0);
      -- A write to word F, the baud rate, and whether it takes the word
      signal f_wr_baud : std_logic;
      signal f_wr_ok   : std_logic;
      -- The divisor of the rate held
      signal f_div : std_logic_vector(15 downto 0);
      signal f_ok  : std_logic;
   begin

      f_wr_baud <= stb_i and we_i when addr_i = X"F" else
                   '0';
      f_wr_ok   <= '1' when rate_div(wdata_i) /= 0 else
                   '0';
      f_div     <= std_logic_vector(to_unsigned(rate_div(baud), 16));
      f_ok      <= '1' when rate_div(baud) /= 0 else
                   '0';

      gen_wr : for n in 0 to 4 generate
         f_wr(n) <= '1' when stb_i = '1' and we_i = '1' and addr_i = n and G_BOARD_IO else
                    '0';
      end generate gen_wr;

      -- psl default clock is rising_edge(clk_i);

      -- A write sets its register, and nothing else changes one but reset.
      -- psl f_led_wr : assert always {f_wr(0) and not rst_i} |=> {led = prev(wdata_i(15 downto 0))};
      -- psl f_rgb0_wr : assert always {f_wr(1) and not rst_i} |=> {rgb0 = prev(wdata_i(11 downto 0))};
      -- psl f_rgb1_wr : assert always {f_wr(2) and not rst_i} |=> {rgb1 = prev(wdata_i(11 downto 0))};
      -- psl f_seg_lo_wr : assert always {f_wr(3) and not rst_i} |=> {seg(31 downto 0) = prev(wdata_i)};
      -- psl f_seg_hi_wr : assert always {f_wr(4) and not rst_i} |=> {seg(63 downto 32) = prev(wdata_i)};
      -- psl f_led_keep : assert always {not f_wr(0) and not rst_i} |=> {stable(led)};
      -- psl f_rgb0_keep : assert always {not f_wr(1) and not rst_i} |=> {stable(rgb0)};
      -- psl f_rgb1_keep : assert always {not f_wr(2) and not rst_i} |=> {stable(rgb1)};
      -- psl f_seg_lo_keep : assert always {not f_wr(3) and not rst_i} |=> {stable(seg(31 downto 0))};
      -- psl f_seg_hi_keep : assert always {not f_wr(4) and not rst_i} |=> {stable(seg(63 downto 32))};
      -- psl f_reset : assert always {rst_i} |=> {led = 0 and rgb0 = 0 and rgb1 = 0 and seg = 0};

      -- Words 7 to D are no registers, and read 0.
      -- psl f_rd_none : assert always addr_i >= X"7" and addr_i <= X"D" -> rdata_o = 0;

      -- Word E reads the words of the RAM, on every board, and a write to
      -- it changes nothing, as no register is written but by its word.
      -- psl f_rd_ram : assert always addr_i = X"E" -> rdata_o = G_RAM_WORDS;

      -- Word F holds the baud rate: a write of a rate it takes sets it, and
      -- of any other value leaves it, and it is always a rate that it
      -- takes, with that rate's divisor out.
      -- psl f_baud_wr : assert always {f_wr_baud and f_wr_ok and not rst_i} |=> {baud = prev(wdata_i)};
      -- psl f_baud_keep : assert always {not (f_wr_baud and f_wr_ok) and not rst_i} |=> {stable(baud)};
      -- psl f_baud_reset : assert always {rst_i} |=> {baud = G_UART_BAUDRATE};
      -- psl f_baud_inv : assert always f_ok and div = f_div;
      -- psl f_rd_baud : assert always addr_i = X"F" -> rdata_o = baud;
      -- psl f_baud_out : assert always uart_baud_o = baud and uart_div_o = div;

      -- psl c_seg_hi : cover {f_wr(4) and not rst_i};
      -- psl c_baud_new : cover {f_wr_baud = '1' and f_wr_ok = '1' and rst_i = '0' and wdata_i /= G_UART_BAUDRATE};
      -- psl c_baud_drop : cover {f_wr_baud and not f_wr_ok and not rst_i};

      gen_formal_io : if G_BOARD_IO generate
      begin
         -- Each word reads its register, or 0.
         -- psl f_rd_led : assert always
         --    addr_i = X"0" -> rdata_o(31 downto 16) = 0 and rdata_o(15 downto 0) = led;
         -- psl f_rd_rgb0 : assert always
         --    addr_i = X"1" -> rdata_o(31 downto 12) = 0 and rdata_o(11 downto 0) = rgb0;
         -- psl f_rd_rgb1 : assert always
         --    addr_i = X"2" -> rdata_o(31 downto 12) = 0 and rdata_o(11 downto 0) = rgb1;
         -- psl f_rd_seg_lo : assert always addr_i = X"3" -> rdata_o = seg(31 downto 0);
         -- psl f_rd_seg_hi : assert always addr_i = X"4" -> rdata_o = seg(63 downto 32);
         -- psl f_rd_btn : assert always
         --    addr_i = X"5" -> rdata_o(31 downto 5) = 0 and rdata_o(4 downto 0) = btn;
         -- psl f_rd_sw : assert always
         --    addr_i = X"6" -> rdata_o(31 downto 16) = 0 and rdata_o(15 downto 0) = sw;
         -- psl f_rd_none : assert always addr_i = X"7" -> rdata_o = 0;

         -- The buttons reach their register two cycles after their pins.
         -- psl f_btn_sync : assert always {not rst_i; not rst_i} |=> {btn = prev(btn_i, 2)};

         -- psl c_btn : cover {stb_i = '1' and we_i = '0' and addr_i = X"5" and btn /= 0 and rst_i = '0'};
      end generate gen_formal_io;

      gen_formal_none : if not G_BOARD_IO generate
      begin
         -- Without G_BOARD_IO, every word but 8 to F reads 0, and the
         -- outputs stay 0.
         -- psl f_none_rd : assert always addr_i < X"8" -> rdata_o = 0;
         -- psl f_none_out : assert always led = 0 and rgb0 = 0 and rgb1 = 0 and seg = 0;
      end generate gen_formal_none;

   end generate gen_formal;

end architecture synthesis;
