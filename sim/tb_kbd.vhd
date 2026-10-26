-- Tests the keyboard: the driver (src/kbd_m65.vhd) and the ASCII mapping
-- (src/kbd_m65_ascii.vhd), with a model of the keyboard's own FPGA.
--
-- THEORY OF OPERATION
-- p_keyboard models the keyboard. It finds the sync pulse, a clock that
-- stays high for longer than a period, and then sends the state of key k
-- after the k-th falling edge of the clock, low while the key is pressed.
-- Keys 76 and 77 are copies of keys 0 and 1, as on the real keyboard.
-- p_main presses and releases keys, and checks the bytes that kbd_m65_ascii sends.
-- p_rx takes the bytes. The modules get a slow G_CLOCK_HZ, so that the test
-- is fast: half a period of the keyboard clock is 10 cycles, and the keys are
-- sampled every 31250 cycles.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.env.all;

entity tb_kbd is
end entity tb_kbd;

architecture simulation of tb_kbd is

   constant C_CLOCK_HZ : natural := 6_250_000;
   -- Clock cycles in half a period of the keyboard clock
   constant C_HALF : natural := C_CLOCK_HZ / 625_000;
   -- The sample period of kbd_m65_ascii, and the repeat
   constant C_SAMPLE : time    := (C_CLOCK_HZ / 200) * 10 ns;
   constant C_DELAY  : time    := 100 * C_SAMPLE;
   constant C_RATE   : time    := 10 * C_SAMPLE;
   -- Long enough for a press or a release to be seen
   constant C_HOLD : time    := 5 * C_SAMPLE;

   constant C_ESC : character := character'val(27);
   constant C_CR  : character := character'val(13);

   signal clk : std_logic;
   signal rst : std_logic;

   signal kb_clk : std_logic;
   signal kb_out : std_logic;
   signal kb_in  : std_logic := '1';
   signal matrix : std_logic_vector(79 downto 0);

   signal valid : std_logic;
   signal ready : std_logic := '1';
   signal data  : std_logic_vector(7 downto 0);

   -- The keys held down
   signal held : std_logic_vector(79 downto 0) := (others => '0');

   signal rx_str : string(1 to 256);
   signal rx_len : natural := 0;

begin

   p_clk : process
   begin
      clk <= '1', '0' after 5 ns;
      wait for 10 ns;
   end process p_clk;

   i_kbd_m65 : entity work.kbd_m65
      generic map (
         G_CLOCK_HZ => C_CLOCK_HZ
      )
      port map (
         clk_i       => clk,
         rst_i       => rst,
         matrix_o    => matrix,
         power_rgb_i => X"00FF00",
         drive_rgb_i => X"000000",
         kb_clk_o    => kb_clk,
         kb_data_o   => kb_out,
         kb_data_i   => kb_in
      ); -- i_kbd_m65

   i_kbd_m65_ascii : entity work.kbd_m65_ascii
      generic map (
         G_CLOCK_HZ => C_CLOCK_HZ
      )
      port map (
         clk_i        => clk,
         rst_i        => rst,
         matrix_i     => matrix,
         data_valid_o => valid,
         data_ready_i => ready,
         data_o       => data
      ); -- i_kbd_m65_ascii


   p_keyboard : process
      variable key_v  : natural;
      variable high_v : natural;

      impure function line(k : natural) return std_logic is
      begin
         if k = 76 then
            return not held(0);
         elsif k = 77 then
            return not held(1);
         elsif k < 80 then
            return not held(k);
         end if;
         return '1';
      end function line;

   begin
      key_v := 200;
      loop
         wait until rising_edge(clk);
         if kb_clk = '1' then
            high_v := high_v + 1;
            if high_v = 3 * C_HALF then
               -- The sync pulse
               key_v := 0;
               kb_in <= line(0);
            end if;
         else
            if high_v /= 0 and key_v < 200 then
               -- A falling edge
               key_v := key_v + 1;
               kb_in <= line(key_v);
            end if;
            high_v := 0;
         end if;
      end loop;
   end process p_keyboard;


   p_rx : process (clk)
   begin
      if rising_edge(clk) then
         if valid = '1' and ready = '1' then
            rx_str(rx_len + 1) <= character'val(to_integer(data));
            rx_len             <= rx_len + 1;
         end if;
      end if;
   end process p_rx;


   p_main : process
      variable pos_v : natural := 0;

      procedure press(k : natural) is
      begin
         held(k) <= '1';
         wait for C_HOLD;
      end procedure press;

      procedure lift(k : natural) is
      begin
         held(k) <= '0';
         wait for C_HOLD;
      end procedure lift;

      procedure tap(k : natural) is
      begin
         press(k);
         lift(k);
      end procedure tap;

      -- The bytes sent since the last check must be s.
      procedure expect(s : string) is
      begin
         assert rx_len = pos_v + s'length and rx_str(pos_v + 1 to rx_len) = s
            report "tb_kbd: expected """ & s & """, got """ &
                   rx_str(pos_v + 1 to rx_len) & """"
            severity failure;
         pos_v := rx_len;
      end procedure expect;

   begin
      rst <= '1';
      wait for 100 ns;
      wait until rising_edge(clk);
      rst <= '0';
      wait for C_HOLD;

      report "tb_kbd: keys";
      tap(10);                       -- A
      tap(56);                       -- 1
      tap(60);                       -- SPACE
      expect("a1 ");

      report "tb_kbd: RETURN and INST/DEL, which come from keys 76 and 77";
      tap(1);
      tap(0);
      expect(C_CR & character'val(127));

      report "tb_kbd: SHIFT";
      press(15);
      tap(17);                       -- R
      tap(56);                       -- 1
      lift(15);
      press(52);
      tap(45);                       -- :
      lift(52);
      expect("R![");

      report "tb_kbd: CAPS LOCK";
      press(72);
      tap(10);                       -- A
      tap(8);                        -- 3
      lift(72);
      tap(10);
      expect("A3a");

      report "tb_kbd: CTRL";
      press(58);
      tap(20);                       -- C
      lift(58);
      tap(63);                       -- RUN/STOP
      expect(character'val(3) & character'val(3));
      press(58);
      tap(0);                        -- INST/DEL stays DEL
      lift(58);
      expect("" & character'val(127));

      report "tb_kbd: the cursor keys";
      tap(73);                       -- up
      tap(7);                        -- down
      press(15);
      tap(2);                        -- SHIFT-right is left
      lift(15);
      tap(2);
      expect(C_ESC & "[A" & C_ESC & "[B" & C_ESC & "[D" & C_ESC & "[C");

      report "tb_kbd: two keys at once, and a key without a byte";
      held(9)  <= '1';               -- W
      held(62) <= '1';               -- Q
      held(4)  <= '1';               -- F1
      wait for C_HOLD;
      held(9)  <= '0';
      held(62) <= '0';
      held(4)  <= '0';
      wait for C_HOLD;
      expect("wq");

      report "tb_kbd: the bytes wait while they are not taken";
      ready <= '0';
      tap(73);                       -- up
      ready <= '1';
      wait for C_HOLD;
      expect(C_ESC & "[A");

      report "tb_kbd: repeat";
      held(23) <= '1';               -- X
      wait for C_DELAY + 2 * C_RATE + C_RATE / 2;
      held(23) <= '0';
      wait for C_HOLD;
      expect("xxxx");

      report "tb_kbd: PASS";
      stop(0);
   end process p_main;

end architecture simulation;
