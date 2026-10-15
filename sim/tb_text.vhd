-- Tests the text display (src/video/text.vhd) at 1280x1024 @ 60 Hz.
--
-- THEORY OF OPERATION
-- p_write fills the screen through the write port, in the system clock
-- domain: a line of text in the default colours, a line in the colour of
-- print.nasm, the 256 codes in many colours, and the 48 words after the 2000
-- of the screen, which must not show. It keeps a model of the screen.
--
-- p_check waits for the writes, then checks one whole frame in the VGA clock
-- domain: the number of visible pixels in each line and of visible lines,
-- the widths of the sync pulses, and the colour of every visible pixel, as
-- the model and the font (font_pkg.vhd) give it. With G_PPM_FILE it also
-- writes the frame as a PPM picture.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.textio.all;

library work;
   use work.video_pkg.all;
   use work.font_pkg.all;

entity tb_text is
   generic (
      G_PPM_FILE : string := ""
   );
end entity tb_text;

architecture simulation of tb_text is

   constant C_MODE : video_mode_t := C_VIDEO_1280X1024;

   type t_scr is array (0 to 2047) of std_logic_vector(31 downto 0);

   signal clk     : std_logic := '1';
   signal vga_clk : std_logic := '1';
   signal running : boolean   := true;

   signal scr_we   : std_logic := '0';
   signal scr_addr : std_logic_vector(10 downto 0);
   signal scr_data : std_logic_vector(31 downto 0);
   signal model    : t_scr := (others => (others => '0'));
   signal written  : boolean := false;

   signal hs    : std_logic;
   signal vs    : std_logic;
   signal de    : std_logic;
   signal red   : std_logic_vector(7 downto 0);
   signal green : std_logic_vector(7 downto 0);
   signal blue  : std_logic_vector(7 downto 0);

   -- The colour (RGB, 8 bits each) that the pixel (x, y) of the visible area
   -- must have
   function expected(scr : t_scr; x, y : natural) return std_logic_vector is
      constant C_Y0  : natural := (C_MODE.v_visible - 800) / 2;
      constant C_X0  : natural := (C_MODE.h_visible - 1280) / 2;
      variable word  : std_logic_vector(31 downto 0);
      variable glyph : std_logic_vector(15 downto 0);
      variable c     : std_logic_vector(7 downto 0);
   begin
      if x < C_X0 or x >= C_X0 + 1280 or y < C_Y0 or y >= C_Y0 + 800 then
         return X"000000";
      end if;
      word  := scr((y - C_Y0) / 32 * 80 + (x - C_X0) / 16);
      glyph := C_FONT(to_integer(word(7 downto 0)) * 32 + (y - C_Y0) mod 32);
      if glyph(15 - (x - C_X0) mod 16) = '1' then
         c := word(23 downto 16);
         if word(31 downto 16) = 0 then
            c := X"FF";
         end if;
      else
         c := word(31 downto 24);
         if word(31 downto 16) = 0 then
            c := X"00";
         end if;
      end if;
      -- RGB 3-3-2, with each colour's bits repeated to 8 bits
      return c(7 downto 5) & c(7 downto 5) & c(7 downto 6) &
             c(4 downto 2) & c(4 downto 2) & c(4 downto 3) &
             c(1 downto 0) & c(1 downto 0) & c(1 downto 0) & c(1 downto 0);
   end function expected;

begin

   clk     <= not clk after 10 ns when running;       -- 50 MHz
   vga_clk <= not vga_clk after 4.63 ns when running; -- 108 MHz

   i_text : entity work.text
      generic map (
         G_MODE => C_MODE
      )
      port map (
         clk_i       => clk,
         scr_we_i    => scr_we,
         scr_addr_i  => scr_addr,
         scr_data_i  => scr_data,
         vga_clk_i   => vga_clk,
         vga_hs_o    => hs,
         vga_vs_o    => vs,
         vga_de_o    => de,
         vga_red_o   => red,
         vga_green_o => green,
         vga_blue_o  => blue
      ); -- i_text

   p_write : process
      procedure put(addr : natural; data : std_logic_vector(31 downto 0)) is
      begin
         scr_we   <= '1';
         scr_addr <= to_slv(addr, 11);
         scr_data <= data;
         model(addr) <= data;
         wait until rising_edge(clk);
         scr_we <= '0';
      end procedure put;

      procedure print(addr : natural; s : string; colour : std_logic_vector(23 downto 0)) is
      begin
         for i in s'range loop
            put(addr + i - s'low, colour & to_slv(character'pos(s(i)), 8));
         end loop;
      end procedure print;

      variable colour_v : std_logic_vector(23 downto 0);
   begin
      wait until rising_edge(clk);
      print(0, "NiceMon on the MEGA65: 80x25 characters, white on black.", X"000000");
      print(80, "Blue on orange, as in print.nasm", X"C80FF0");
      -- The last column of a row, and the last word of the screen
      print(80 + 79, "!", X"00E000");
      print(1999, "#", X"031C00");
      -- The 256 codes, from row 4, in colours from the code and the row
      for i in 0 to 20 * 80 - 1 loop
         colour_v := to_slv((i * 40503) mod 2 ** 24, 24);
         put(4 * 80 + i, colour_v & to_slv(i mod 256, 8));
      end loop;
      -- Words beyond the screen
      for i in 2000 to 2047 loop
         put(i, X"FFFFFF41");
      end loop;
      written <= true;
      wait;
   end process p_write;

   p_check : process
      file     ppm    : text;
      variable l      : line;
      variable x, y   : natural;
      variable errors : natural := 0;
      variable rgb    : std_logic_vector(23 downto 0);
      variable hs_len : natural;
      variable vs_len : natural;
   begin
      wait until written;
      -- Start at the end of a vertical sync pulse, so that the frame after it
      -- is checked whole.
      wait until rising_edge(vga_clk) and vs = C_MODE.sync_active;
      wait until rising_edge(vga_clk) and vs /= C_MODE.sync_active;

      if G_PPM_FILE /= "" then
         file_open(ppm, G_PPM_FILE, write_mode);
         write(l, string'("P3 1280 1024 255"));
         writeline(ppm, l);
      end if;

      y := 0;
      loop
         -- One line: the visible pixels, then the blanking
         x := 0;
         wait until rising_edge(vga_clk) and de = '1';
         while de = '1' loop
            rgb := red & green & blue;
            if rgb /= expected(model, x, y) then
               errors := errors + 1;
               if errors <= 10 then
                  report "Pixel (" & integer'image(x) & ", " & integer'image(y) & ") is " &
                         to_hstring(rgb) & ", not " & to_hstring(expected(model, x, y))
                     severity error;
               end if;
            end if;
            if G_PPM_FILE /= "" then
               write(l, integer'image(to_integer(red)) & " " & integer'image(to_integer(green)) &
                        " " & integer'image(to_integer(blue)));
               writeline(ppm, l);
            end if;
            x := x + 1;
            wait until rising_edge(vga_clk);
         end loop;
         assert x = C_MODE.h_visible
            report "Line " & integer'image(y) & " has " & integer'image(x) & " visible pixels"
            severity failure;
         -- The horizontal sync pulse after the line
         wait until rising_edge(vga_clk) and hs = C_MODE.sync_active;
         hs_len := 0;
         while hs = C_MODE.sync_active loop
            hs_len := hs_len + 1;
            wait until rising_edge(vga_clk);
         end loop;
         assert hs_len = C_MODE.h_sync
            report "The horizontal sync pulse is " & integer'image(hs_len) & " pixels"
            severity failure;
         y := y + 1;
         exit when y = C_MODE.v_visible;
      end loop;

      if G_PPM_FILE /= "" then
         file_close(ppm);
      end if;

      -- The vertical sync pulse, in lines, after the visible lines
      wait until rising_edge(vga_clk) and vs = C_MODE.sync_active;
      vs_len := 0;
      while vs = C_MODE.sync_active loop
         if hs = C_MODE.sync_active then
            vs_len := vs_len + 1;
         end if;
         wait until rising_edge(vga_clk);
      end loop;
      assert vs_len = C_MODE.v_sync * C_MODE.h_sync
         report "The vertical sync pulse is " & integer'image(vs_len) & " horizontal sync pixels"
         severity failure;

      assert errors = 0
         report integer'image(errors) & " pixels are wrong"
         severity failure;
      report "1280x1024 pixels checked";
      running <= false;
      wait;
   end process p_check;

end architecture simulation;
