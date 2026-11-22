-- Tests the PS/2 keyboard: the receiver and the LEDs (src/kbd_ps2.vhd), the
-- ASCII mapping (src/kbd_ps2_ascii.vhd), and the debugger's Scroll Lock
-- detector (src/kbd_ps2_toggle.vhd), with a model of the keyboard.
--
-- THEORY OF OPERATION
-- ps2_kbd_model.vhd is the keyboard: send() has it send a frame on the two
-- lines, with the clock at 12.5 kHz, as a keyboard drives them, and it takes
-- the host's commands and answers them. p_main sends the scan codes of
-- keys being pressed and released, and checks the bytes that kbd_ps2_ascii
-- sends. It also sends frames with a wrong parity, start, or stop bit, and
-- half a frame, which the receiver must drop. It checks the commands that
-- set the LEDs, ED and the LED byte, at reset, after CAPS LOCK and Num Lock,
-- after the keyboard's AA, with a keyboard that answers late, hangs after
-- the LED byte, or does not answer, and that they wait until no keys have
-- come for 100 ms. p_rx
-- takes the bytes and the detector's pulses, and p_cmds the commands. The
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

   -- The lines, with their pull-ups, and the host's side of them
   signal ps2_clk      : std_logic;
   signal ps2_data     : std_logic;
   signal ps2_clk_out  : std_logic;
   signal ps2_data_out : std_logic;
   signal leds         : std_logic_vector(2 downto 0);

   -- The keyboard model's frames, and the commands it takes
   signal kbd_send   : std_logic := '0';
   signal kbd_byte   : std_logic_vector(7 downto 0) := X"00";
   signal kbd_bits   : natural range 1 to 11 := 11;
   signal kbd_bad    : std_logic_vector(1 downto 0) := "00";
   signal kbd_sent   : std_logic;
   signal kbd_answer : std_logic := '1';
   signal kbd_delay  : time      := 1 ms;
   signal kbd_hang   : std_logic := '0';
   signal kbd_cmd    : std_logic_vector(7 downto 0);
   signal kbd_cmds   : natural;
   signal kbd_errs   : natural;

   type t_cmds is array (natural range <>) of std_logic_vector(7 downto 0);

   signal cmd_log : t_cmds(1 to 64);

   signal code_valid : std_logic;
   signal code       : std_logic_vector(7 downto 0);

   signal valid : std_logic;
   signal ready : std_logic := '1';
   signal data  : std_logic_vector(7 downto 0);

   signal rx_str : string(1 to 256);
   signal rx_len : natural := 0;

   signal toggle  : std_logic;
   signal toggles : natural := 0;

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
         ps2_clk_i    => to_x01(ps2_clk),
         ps2_data_i   => to_x01(ps2_data),
         ps2_clk_o    => ps2_clk_out,
         ps2_data_o   => ps2_data_out,
         leds_i       => leds,
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
         data_o       => data,
         leds_o       => leds
      ); -- i_kbd_ps2_ascii

   -- The lines are open drain, with pull-ups
   ps2_clk  <= 'H';
   ps2_data <= 'H';
   ps2_clk  <= '0' when ps2_clk_out = '0' else 'Z';
   ps2_data <= '0' when ps2_data_out = '0' else 'Z';

   i_ps2_kbd_model : entity work.ps2_kbd_model
      generic map (
         G_HALF => C_HALF
      )
      port map (
         ps2_clk_io  => ps2_clk,
         ps2_data_io => ps2_data,
         send_i      => kbd_send,
         byte_i      => kbd_byte,
         bits_i      => kbd_bits,
         bad_i       => kbd_bad,
         sent_o      => kbd_sent,
         answer_i    => kbd_answer,
         delay_i     => kbd_delay,
         hang_i      => kbd_hang,
         cmd_o       => kbd_cmd,
         cmds_o      => kbd_cmds,
         errs_o      => kbd_errs
      ); -- i_ps2_kbd_model

   p_cmds : process (kbd_cmds)
   begin
      if kbd_cmds > 0 then
         cmd_log(kbd_cmds) <= kbd_cmd;
      end if;
   end process p_cmds;

   i_kbd_ps2_toggle : entity work.kbd_ps2_toggle
      port map (
         clk_i        => clk,
         rst_i        => rst,
         code_valid_i => code_valid,
         code_i       => code,
         toggle_o     => toggle
      ); -- i_kbd_ps2_toggle


   p_rx : process (clk)
   begin
      if rising_edge(clk) then
         if valid = '1' and ready = '1' then
            rx_str(rx_len + 1) <= character'val(to_integer(data));
            rx_len             <= rx_len + 1;
         end if;
         if toggle = '1' then
            toggles <= toggles + 1;
         end if;
      end if;
   end process p_rx;


   p_main : process
      variable pos_v     : natural := 0;
      variable cmd_pos_v : natural := 0;

      -- Send the first n bits of a frame of byte b, then a pause. bad flips
      -- the start ("01"), parity ("10"), or stop bit ("11").
      procedure send(b   : std_logic_vector(7 downto 0);
                     n   : natural                      := 11;
                     bad : std_logic_vector(1 downto 0) := "00") is
      begin
         kbd_byte <= b;
         kbd_bits <= n;
         kbd_bad  <= bad;
         kbd_send <= not kbd_send;
         wait for 0 ns;
         wait until kbd_sent = kbd_send;
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

      -- The commands that the keyboard took since the last check must be
      -- the bytes of v, which come within 5 s, and no more within 25 ms.
      procedure expect_cmds(v : std_logic_vector) is
         constant C_N : natural := v'length / 8;
         variable v_v : std_logic_vector(v'length - 1 downto 0);
      begin
         v_v := v;
         if kbd_cmds < cmd_pos_v + C_N then
            wait until kbd_cmds >= cmd_pos_v + C_N for 5 sec;
         end if;
         wait for 25 ms;
         assert kbd_cmds = cmd_pos_v + C_N and kbd_errs = 0
            report "tb_ps2: expected " & integer'image(C_N) & " commands, got " &
                   integer'image(kbd_cmds - cmd_pos_v) & ", and " &
                   integer'image(kbd_errs) & " bad ones"
            severity failure;
         for i in 0 to C_N - 1 loop
            assert cmd_log(cmd_pos_v + 1 + i) = v_v(v'length - 1 - 8 * i downto v'length - 8 - 8 * i)
               report "tb_ps2: command " & integer'image(i) & " is " &
                      to_hstring(cmd_log(cmd_pos_v + 1 + i)) & ", not " &
                      to_hstring(v_v(v'length - 1 - 8 * i downto v'length - 8 - 8 * i))
               severity failure;
         end loop;
         cmd_pos_v := kbd_cmds;
      end procedure expect_cmds;

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

      report "tb_ps2: the LEDs are set off at reset";
      expect_cmds(X"ED00");

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
      expect_cmds(X"ED04");          -- the CAPS LOCK LED on
      tap(X"58");
      tap(X"1C");
      expect("A3a");
      expect_cmds(X"ED00");          -- and off

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

      report "tb_ps2: CTRL with Backspace and Delete keeps DEL";
      press(X"14");
      tap(X"66");                    -- Backspace
      tap(X"71", true);              -- Delete
      lift(X"14");
      expect(C_DEL & C_DEL);

      report "tb_ps2: the cursor keys, Delete, and the keypad with Num Lock off";
      tap(X"75", true);              -- up
      tap(X"72", true);              -- down
      tap(X"74", true);              -- right
      tap(X"6B", true);              -- left
      tap(X"71", true);              -- Delete
      tap(X"6B");                    -- the keypad's 4, or the PIC24's left
      tap(X"4A", true);              -- the keypad's /
      tap(X"7C");                    -- the keypad's *
      expect(C_ESC & "[A" & C_ESC & "[B" & C_ESC & "[C" & C_ESC & "[D" & C_DEL &
             C_ESC & "[D" & "/*");

      report "tb_ps2: the Nexys4DDR's PIC24's up and down, the keypad's 8 and 2";
      tap(X"75");
      tap(X"72");
      tap(X"74");                    -- the keypad's 6
      tap(X"71");                    -- the keypad's dot
      tap(X"69");                    -- the keypad's 1, nothing
      tap(X"73");                    -- the keypad's 5, nothing
      tap(X"70");                    -- the keypad's 0, nothing
      tap(X"16");                    -- 1
      expect(C_ESC & "[A" & C_ESC & "[B" & C_ESC & "[C" & C_DEL & "1");

      report "tb_ps2: Num Lock on gives the keypad's digits, a held one switches once";
      press(X"77");
      press(X"77");                  -- the repeat of a held key
      lift(X"77");
      tap(X"69");
      tap(X"72");
      tap(X"7A");
      tap(X"6B");
      tap(X"73");
      tap(X"74");
      tap(X"6C");
      tap(X"75");
      tap(X"7D");
      tap(X"70");
      tap(X"71");
      tap(X"75", true);              -- up, with E0, stays up
      expect("1234567890." & C_ESC & "[A");
      expect_cmds(X"ED02");          -- the Num Lock LED on

      report "tb_ps2: Pause, CTRL with Num Lock, leaves Num Lock on";
      send(X"E1");
      send(X"14");
      send(X"77");
      send(X"E1");
      send(X"F0");
      send(X"14");
      send(X"F0");
      send(X"77");
      tap(X"6B");
      expect("4");
      expect_cmds("");

      report "tb_ps2: Num Lock again switches it off";
      tap(X"77");
      tap(X"6B");
      expect(C_ESC & "[D");
      expect_cmds(X"ED00");

      report "tb_ps2: the function keys, as xterm sends them";
      tap(X"05");                    -- F1
      tap(X"0C");                    -- F4
      tap(X"03");                    -- F5
      tap(X"83");                    -- F7, the code above 7F
      press(X"12");
      tap(X"78");                    -- F11, also with SHIFT
      lift(X"12");
      tap(X"07");                    -- F12
      expect(C_ESC & "OP" & C_ESC & "OS" & C_ESC & "[15~" & C_ESC & "[18~" &
             C_ESC & "[23~" & C_ESC & "[24~");

      report "tb_ps2: Home, Page Up, and Page Down, and the keypad's 7, 9, and 3";
      tap(X"6C", true);              -- Home
      tap(X"7D", true);              -- Page Up
      tap(X"7A", true);              -- Page Down
      tap(X"6C");                    -- the keypad's 7, Home with Num Lock off
      tap(X"77");                    -- Num Lock on
      tap(X"6C");                    -- the keypad's 7
      tap(X"7D");                    -- the keypad's 9
      tap(X"7A");                    -- the keypad's 3
      tap(X"77");                    -- Num Lock off again
      expect(C_ESC & "[H" & C_ESC & "[5~" & C_ESC & "[6~" & C_ESC & "[H" & "793");
      expect_cmds("");               -- no change after 100 ms

      report "tb_ps2: a key repeats as the keyboard repeats it";
      press(X"22");                  -- X
      press(X"22");
      press(X"22");
      lift(X"22");
      expect("xxx");

      report "tb_ps2: keys without a byte, and answers from the keyboard";
      tap(X"7E");                    -- Scroll Lock
      tap(X"11");                    -- Alt
      tap(X"1F", true);              -- the left Windows key
      send(X"AA");                   -- the self-test passed
      send(X"FA");                   -- acknowledge
      tap(X"1D");                    -- W
      expect("w");
      expect_cmds(X"ED00");          -- the LEDs again, after AA

      report "tb_ps2: a keyboard that answers late gets the LED byte";
      kbd_delay <= 50 ms;
      tap(X"58");                    -- CAPS LOCK on
      expect_cmds(X"ED04");
      tap(X"58");                    -- CAPS LOCK off
      expect_cmds(X"ED00");
      kbd_delay <= 1 ms;

      report "tb_ps2: a keyboard that hangs after the LED byte gets ED again";
      kbd_hang <= '1';
      tap(X"58");                    -- CAPS LOCK on
      wait until kbd_cmds = cmd_pos_v + 2;
      kbd_hang <= '0';
      expect_cmds(X"ED04ED04");
      tap(X"58");                    -- CAPS LOCK off
      expect_cmds(X"ED00");

      report "tb_ps2: a keyboard that does not answer gets ED and the LED " &
             "byte three times a change";
      kbd_answer <= '0';
      tap(X"58");                    -- CAPS LOCK on
      tap(X"1C");                    -- A
      expect_cmds(X"ED04ED04ED04");
      tap(X"58");                    -- CAPS LOCK off
      tap(X"1C");
      expect_cmds(X"ED00ED00ED00");
      expect("Aa");
      wait for 250 ms;               -- the wait for the last FA ends
      kbd_answer <= '1';

      report "tb_ps2: the LEDs change only after 100 ms without keys";
      tap(X"77");                    -- Num Lock on
      for i in 1 to 8 loop
         wait for 50 ms;
         tap(X"1C");
      end loop;
      expect_cmds("");
      expect("aaaaaaaa");
      expect_cmds(X"ED02");
      tap(X"77");                    -- Num Lock off
      expect_cmds(X"ED00");

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

      report "tb_ps2: Scroll Lock toggles once while held, and not in Ctrl+Break";
      -- The Scroll Lock above made the first pulse.
      assert toggles = 1
         report "tb_ps2: Scroll Lock gave " & integer'image(toggles) & " pulses, not 1"
         severity failure;
      press(X"7E");
      press(X"7E");
      press(X"7E");
      lift(X"7E");
      assert toggles = 2
         report "tb_ps2: a held Scroll Lock gave " & integer'image(toggles - 1) & " pulses, not 1"
         severity failure;
      press(X"14");                  -- CTRL, then Break
      send(X"E0");
      send(X"7E");
      send(X"E0");
      lift(X"7E");
      lift(X"14");
      tap(X"7E");
      assert toggles = 3
         report "tb_ps2: Ctrl+Break toggled, or Scroll Lock after it did not"
         severity failure;
      expect("");

      report "tb_ps2: PASS";
      stop(0);
   end process p_main;

end architecture simulation;
