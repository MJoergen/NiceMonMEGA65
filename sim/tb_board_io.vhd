-- Tests the drivers of the Nexys4DDR's seven-segment display (src/seg7.vhd)
-- and RGB LEDs (src/rgb_pwm.vhd).
--
-- THEORY OF OPERATION
-- The display gets a different byte in each digit. Over several scans of the
-- eight digits, the testbench checks at every clock cycle that exactly one
-- anode is low, that the cathodes are the inverse of the byte of the digit
-- that the anode selects, and that every digit was lit. An RGB LED gets
-- levels 0, 5, and 15, and the testbench counts the cycles that each output
-- is high over a few periods: 0, 5/16, and 15/16 of them.

library ieee;
   use ieee.std_logic_1164.all;

entity tb_board_io is
end entity tb_board_io;

architecture simulation of tb_board_io is

   constant C_CLOCK_HZ : natural := 8_000_000;
   -- Cycles per digit and per PWM period
   constant C_DIGIT  : natural := C_CLOCK_HZ / 8_000;
   constant C_DIV    : natural := 2;
   constant C_PERIOD : natural := 16 * C_DIV;

   constant C_SEG : std_logic_vector(63 downto 0) := X"8040201008040201";

   signal clk : std_logic := '0';
   signal an  : std_logic_vector(7 downto 0);
   signal ca  : std_logic_vector(7 downto 0);
   signal rgb : std_logic_vector(2 downto 0);

begin

   clk <= not clk after 5 ns;


   i_seg7 : entity work.seg7
      generic map (
         G_CLOCK_HZ => C_CLOCK_HZ
      )
      port map (
         clk_i => clk,
         seg_i => C_SEG,
         an_o  => an,
         ca_o  => ca
      ); -- i_seg7


   i_rgb_pwm : entity work.rgb_pwm
      generic map (
         G_DIV => C_DIV
      )
      port map (
         clk_i   => clk,
         red_i   => X"0",
         green_i => X"5",
         blue_i  => X"F",
         rgb_o   => rgb
      ); -- i_rgb_pwm


   p_check : process

      type t_counts is array (0 to 2) of natural;

      variable lit_v   : std_logic_vector(7 downto 0) := (others => '0');
      variable ones_v  : natural;
      variable high_v  : std_logic_vector(2 downto 0);
      variable count_v : t_counts := (0, 0, 0);
   begin
      wait for 100 ns;

      -- Two full scans of the display
      for i in 1 to 16 * C_DIGIT loop
         wait until rising_edge(clk);
         wait for 1 ns;
         ones_v := 0;
         for d in 0 to 7 loop
            if an(d) = '0' then
               ones_v := ones_v + 1;
               assert ca = not C_SEG(8 * d + 7 downto 8 * d)
                  report "tb_board_io: wrong segments for digit " & integer'image(d)
                  severity failure;
               lit_v(d) := '1';
            end if;
         end loop;
         assert ones_v = 1
            report "tb_board_io: " & integer'image(ones_v) & " digits are lit"
            severity failure;
      end loop;
      assert lit_v = X"FF"
         report "tb_board_io: a digit was never lit"
         severity failure;

      -- Four PWM periods
      for i in 1 to 4 * C_PERIOD loop
         wait until rising_edge(clk);
         wait for 1 ns;
         for c in 0 to 2 loop
            if rgb(c) = '1' then
               count_v(c) := count_v(c) + 1;
            end if;
         end loop;
      end loop;
      assert count_v(2) = 0
         report "tb_board_io: red level 0 is not dark"
         severity failure;
      assert count_v(1) = 4 * 5 * C_DIV
         report "tb_board_io: green level 5 has " & integer'image(count_v(1)) & " cycles"
         severity failure;
      assert count_v(0) = 4 * 15 * C_DIV
         report "tb_board_io: blue level 15 has " & integer'image(count_v(0)) & " cycles"
         severity failure;

      report "tb_board_io: PASS";
      std.env.finish;
   end process p_check;

end architecture simulation;
