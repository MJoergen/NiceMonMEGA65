-- Tests the PS/2 keyboard: the receiver (src/kbd_ps2.vhd) and the ASCII
-- mapping (src/kbd_ps2_ascii.vhd), with a model of the keyboard.
--
-- THEORY OF OPERATION
-- send() is the keyboard: it sends a frame on the two lines, with the clock
-- at 12.5 kHz, as a keyboard drives them. p_main sends the scan codes of
-- keys being pressed and released, and checks the bytes that kbd_ps2_ascii
-- sends. It also sends frames with a wrong parity, start, or stop bit, and
-- half a frame, which the receiver must drop. p_rx takes the bytes. The
-- system clock is 10 MHz, so that the filter and the timeout of the receiver
-- have their real lengths.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.env.all;

entity tb_ps2 is
end entity tb_ps2;

architecture simulation of tb_ps2 is

   constant C_CLOCK_HZ : natural := 10_000_000;
   -- Half a period of the keyboard's clock
   constant C_HALF : time := 40 us;

   constant C_ESC : character := character'val(27);
   constant C_CR  : character := character'val(13);
   constant C_DEL : character := character'val(127);

   signal clk : std_logic;
   signal rst : std_logic;

   signal ps2_clk  : std_logic := '1';
   signal ps2_data : std_logic := '1';

   signal code_valid : std_logic;
   signal code       : std_logic_vector(7 downto 0);

   signal valid : std_logic;
   signal ready : std_logic := '1';
   signal data  : std_logic_vector(7 downto 0);

   signal rx_str : string(1 to 256);
   signal rx_len : natural := 0;

begin

   p_clk : process
   begin
      clk <= '1', '0' after 50 ns;
      wait for 100 ns;
   end process p_clk;

   i_kbd_ps2 : entity work.kbd_ps2
      generic map (
         G_CLOCK_HZ => C_CLOCK_HZ
      )
      port map (
         clk_i        => clk,
         rst_i        => rst,
         ps2_clk_i    => ps2_clk,
         ps2_data_i   => ps2_data,
         data_valid_o => code_valid,
         data_o       => code
      ); -- i_kbd_ps2

   i_kbd_ps2_ascii : entity work.kbd_ps2_ascii
      port map (
         clk_i        => clk,
         rst_i        => rst,
         code_valid_i => code_valid,
         code_i       => code,
         data_valid_o => valid,
         data_ready_i => ready,
         data_o       => data
      ); -- i_kbd_ps2_ascii


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

      -- Send the first n bits of a frame of byte b, then a pause. bad flips
      -- the start ("01"), parity ("10"), or stop bit ("11").
      procedure send(b   : std_logic_vector(7 downto 0);
                     n   : natural                      := 11;
                     bad : std_logic_vector(1 downto 0) := "00") is
         variable frame_v : std_logic_vector(10 downto 0);
      begin
         frame_v := '1' & not (xor b) & b & '0';
         case bad is
            when "01"   => frame_v(0)  := '1';
            when "10"   => frame_v(9)  := not frame_v(9);
            when "11"   => frame_v(10) := '0';
            when others => null;
         end case;
         for i in 0 to n - 1 loop
            ps2_data <= frame_v(i);
            wait for C_HALF / 2;
            ps2_clk  <= '0';
            wait for C_HALF;
            ps2_clk  <= '1';
            wait for C_HALF / 2;
         end loop;
         ps2_data <= '1';
         wait for 4 * C_HALF;
      end procedure send;

      -- A key pressed and released, with E0 before its code if ext
      procedure tap(c : std_logic_vector(7 downto 0); ext : boolean := false) is
      begin
         if ext then
            send(X"E0");
         end if;
         send(c);
         if ext then
            send(X"E0");
         end if;
         send(X"F0");
         send(c);
      end procedure tap;

      procedure press(c : std_logic_vector(7 downto 0)) is
      begin
         send(c);
      end procedure press;

      procedure lift(c : std_logic_vector(7 downto 0)) is
      begin
         send(X"F0");
         send(c);
      end procedure lift;

      -- The bytes sent since the last check must be s.
      procedure expect(s : string) is
      begin
         assert rx_len = pos_v + s'length and rx_str(pos_v + 1 to rx_len) = s
            report "tb_ps2: expected """ & s & """, got """ &
                   rx_str(pos_v + 1 to rx_len) & """"
            severity failure;
         pos_v := rx_len;
      end procedure expect;

   begin
      rst <= '1';
      wait for 1 us;
      wait until rising_edge(clk);
      rst <= '0';
      wait for 10 us;

      report "tb_ps2: keys";
      tap(X"1C");                    -- A
      tap(X"16");                    -- 1
      tap(X"29");                    -- space
      tap(X"5A");                    -- Enter
      tap(X"66");                    -- Backspace
      expect("a1 " & C_CR & C_DEL);

      report "tb_ps2: SHIFT";
      press(X"12");
      tap(X"2D");                    -- R
      tap(X"16");                    -- 1
      lift(X"12");
      press(X"59");
      tap(X"54");                    -- [
      lift(X"59");
      tap(X"54");
      expect("R!{[");

      report "tb_ps2: CAPS LOCK, which a repeat does not switch back";
      press(X"58");
      press(X"58");
      lift(X"58");
      tap(X"1C");                    -- A
      tap(X"26");                    -- 3
      tap(X"58");
      tap(X"1C");
      expect("A3a");

      report "tb_ps2: CTRL, left and right";
      press(X"14");
      tap(X"21");                    -- C
      lift(X"14");
      send(X"E0");
      press(X"14");
      tap(X"1B");                    -- S
      send(X"E0");
      lift(X"14");
      tap(X"21");
      expect(character'val(3) & character'val(19) & "c");

      report "tb_ps2: the cursor keys, Delete, and the keypad";
      tap(X"75", true);              -- up
      tap(X"72", true);              -- down
      tap(X"74", true);              -- right
      tap(X"6B", true);              -- left
      tap(X"71", true);              -- Delete
      tap(X"6B");                    -- the keypad's 4
      tap(X"4A", true);              -- the keypad's /
      expect(C_ESC & "[A" & C_ESC & "[B" & C_ESC & "[C" & C_ESC & "[D" & C_DEL & "4/");

      report "tb_ps2: a key repeats as the keyboard repeats it";
      press(X"22");                  -- X
      press(X"22");
      press(X"22");
      lift(X"22");
      expect("xxx");

      report "tb_ps2: keys without a byte, and answers from the keyboard";
      tap(X"05");                    -- F1
      tap(X"11");                    -- Alt
      tap(X"1F", true);              -- the left Windows key
      send(X"AA");                   -- the self-test passed
      send(X"FA");                   -- acknowledge
      tap(X"1D");                    -- W
      expect("w");

      report "tb_ps2: bad frames are dropped";
      send(X"1C", 11, "01");         -- start bit
      send(X"1C", 11, "10");         -- parity
      send(X"1C", 11, "11");         -- stop bit
      tap(X"15");                    -- Q
      expect("q");

      report "tb_ps2: half a frame is dropped after a pause";
      send(X"F0", 5);
      wait for 300 us;
      tap(X"15");
      expect("q");

      report "tb_ps2: the bytes wait while they are not taken";
      ready <= '0';
      tap(X"75", true);              -- up
      tap(X"1C");                    -- A, while they wait, gives nothing
      ready <= '1';
      wait for 10 us;
      expect(C_ESC & "[A");

      report "tb_ps2: PASS";
      stop(0);
   end process p_main;

end architecture simulation;
