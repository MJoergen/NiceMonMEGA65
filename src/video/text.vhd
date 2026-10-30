-- The text display: shows the screen of the NiceMon system, 80x25
-- characters, on a video output in the video mode G_MODE (see video_pkg.vhd),
-- with a cursor and a display offset for scrolling, as the VGA of QNICE-FPGA
-- has.
--
-- THEORY OF OPERATION
-- The screen is the 2^G_SCR_ADDR_BITS words at 0xFFFF0000 (src/nicemon.vhd),
-- 32768 on the MEGA65 boards and 8192 on the Nexys4DDR, of which the first
-- 2000 are the emulator's 80x25
-- characters, row by row. Each word is a character in bits 7..0 and its
-- color above (nice_cpu's runtime/ABI.md, nice_screen_put). This module keeps
-- a copy of the screen in a memory of its own (scr_ram.vhd), with a write
-- port in the system clock domain, which takes every write to the screen
-- (scr_*_i), and a read port in the VGA clock domain. So the copy is a
-- crossing of the clock domains, and the block RAM makes it.
--
-- The display shows the 2000 words from the display offset, offs_i, so a
-- program scrolls by adding 80 to the offset and writing the next row after
-- the words shown. The offset wraps at the end of the screen. The cursor is
-- at column cur_x_i and row cur_y_i of the display, and cur_mode_i says how
-- it is shown: bit 0 shows it, bit 1 makes it blink, about twice a second,
-- and bit 2 makes it small, the bottom 4 lines of the character, where it is
-- otherwise the whole character. The cursor swaps the colors of its
-- character. These values are the screen's registers of scr_regs.vhd, in the
-- system clock domain, and ctl_we_i is '1' for a cycle when one of them is
-- written. They cross to the VGA clock domain through a handshake: the
-- values are held while a request goes to the VGA clock, which takes them
-- and acknowledges; a write meanwhile is passed on after the acknowledge.
-- So the display never sees a value half written, and the paths between
-- the clocks need not be timed.
--
-- The overlay is the on-board debugger's (src/dbg/dbg.vhd, doc/DEBUGGER.md):
-- 29 rows of 80 words, in a memory of its own, 2^12 words written by the
-- debugger (ovl_*_i) in the system clock domain, and read in the VGA clock
-- domain, as the copy of the screen is. Its rows 0 to 24 are the page, which
-- replaces the program's 25 rows while page_i is '1', and hides the cursor;
-- its rows 25 to 28 are the strip, which is shown under them while strip_i
-- is '1', and is black otherwise. A word of the overlay is at row * 80 +
-- column, with no display offset. strip_i and page_i cross to the VGA clock
-- through synchronizers of their own: they change rarely, and a frame half
-- changed does no harm.
--
-- The characters are 16x32 pixels, from the Spleen font (font_pkg.vhd), with
-- the 256 codes of ISO 8859-1. So the 29 rows are 1280x928 pixels, in the
-- middle of the visible area, which is black around them. The program's 25
-- rows are at their top, in every state of the debugger, so that nothing
-- moves when the strip appears. The color of a word is
-- two colors of 12 bits, red, green, and blue with 4 bits each: the
-- background in bits 31..20, and the foreground in bits 19..8 (nice_cpu's
-- doc/SYSTEM.md §1). Each 4-bit component n becomes the byte n * 0x11, so 0xF
-- is full intensity and 0x0 is none. Unlike in NICE's original IDE of 2004,
-- the foreground is not inverted, so a word with only a character, such as
-- 0x41, is black on black.
--
-- The pixel counters (pix.vhd) give the pixel of stage 0. The pipeline:
--   1: the position in the text, the address of the character, with the
--      display offset, and in the overlay, whether it is the cursor's, and
--      whether the overlay is shown there
--   2: the word of the character, read from the copy of the screen, and the
--      word of the overlay
--   3: the row of the glyph, read from the font, for the word shown, and
--      the colors, swapped for the cursor
--   4: the color of the pixel, and the outputs
-- The sync signals and the visible area go through the same stages, so the
-- outputs all belong to the same pixel. The outputs are registers, with
-- the color 0 outside the visible area.
--
-- RESET
-- None. The copy of the screen starts as zeros, as the screen does, the
-- display offset is 0, and the cursor is off. The overlay starts as zeros.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

library work;
   use work.video_pkg.all;
   use work.font_pkg.all;

entity text is
   generic (
      G_MODE          : t_video_mode;
      G_SCR_ADDR_BITS : natural := 15
   );
   port (
      -- The writes to the screen, in the system clock domain
      clk_i       : in  std_logic;
      scr_we_i    : in  std_logic;
      scr_addr_i  : in  std_logic_vector(G_SCR_ADDR_BITS - 1 downto 0);
      scr_data_i  : in  std_logic_vector(31 downto 0);
      -- The screen's registers, in the system clock domain
      ctl_we_i    : in  std_logic;
      cur_x_i     : in  std_logic_vector(6 downto 0);
      cur_y_i     : in  std_logic_vector(4 downto 0);
      cur_mode_i  : in  std_logic_vector(2 downto 0);
      offs_i      : in  std_logic_vector(G_SCR_ADDR_BITS - 1 downto 0);
      -- The debugger's overlay, in the system clock domain
      ovl_we_i    : in  std_logic;
      ovl_addr_i  : in  std_logic_vector(11 downto 0);
      ovl_data_i  : in  std_logic_vector(31 downto 0);
      strip_i     : in  std_logic;
      page_i      : in  std_logic;

      -- The video output, in the VGA clock domain
      vga_clk_i   : in  std_logic;
      vga_hs_o    : out std_logic;
      vga_vs_o    : out std_logic;
      vga_de_o    : out std_logic;  -- '1' in the visible area
      vga_red_o   : out std_logic_vector(7 downto 0);
      vga_green_o : out std_logic_vector(7 downto 0);
      vga_blue_o  : out std_logic_vector(7 downto 0)
   );
end entity text;

architecture synthesis of text is

   constant C_COLS        : natural := 80;
   constant C_ROWS        : natural := 25;  -- The program's
   constant C_ALL_ROWS    : natural := 29;  -- With the debugger's strip
   constant C_CHAR_WIDTH  : natural := 16;
   constant C_CHAR_HEIGHT : natural := 32;
   -- The lines of the character that the small cursor covers
   constant C_SMALL_CURSOR : natural := 4;

   -- The top left pixel of the text
   constant C_X0 : natural := (G_MODE.h_visible - C_COLS * C_CHAR_WIDTH) / 2;
   constant C_Y0 : natural := (G_MODE.v_visible - C_ALL_ROWS * C_CHAR_HEIGHT) / 2;

   constant C_HS_START : natural := G_MODE.h_visible + G_MODE.h_front;
   constant C_VS_START : natural := G_MODE.v_visible + G_MODE.v_front;

   -- The screen's registers, held for the handshake, in the system clock
   -- domain. ctl_dirty is '1' while a write waits for the handshake.
   signal ctl_dirty  : std_logic := '0';
   signal ctl_req    : std_logic := '0';
   signal ctl_ack_s  : std_logic_vector(1 downto 0) := "00";
   signal cur_x_r    : std_logic_vector(6 downto 0) := (others => '0');
   signal cur_y_r    : std_logic_vector(4 downto 0) := (others => '0');
   signal cur_mode_r : std_logic_vector(2 downto 0) := (others => '0');
   signal offs_r     : std_logic_vector(G_SCR_ADDR_BITS - 1 downto 0) := (others => '0');

   -- The registers as the display uses them, in the VGA clock domain
   signal ctl_req_s    : std_logic_vector(1 downto 0) := "00";
   signal ctl_ack      : std_logic := '0';
   signal cur_x_vga    : std_logic_vector(6 downto 0) := (others => '0');
   signal cur_y_vga    : std_logic_vector(4 downto 0) := (others => '0');
   signal cur_mode_vga : std_logic_vector(2 downto 0) := (others => '0');
   signal offs_vga     : std_logic_vector(G_SCR_ADDR_BITS - 1 downto 0) := (others => '0');

   -- The overlay's mode bits, synchronized to the VGA clock
   signal strip_s : std_logic_vector(1 downto 0) := "00";
   signal page_s  : std_logic_vector(1 downto 0) := "00";

   attribute async_reg : string;
   attribute async_reg of ctl_ack_s : signal is "TRUE";
   attribute async_reg of ctl_req_s : signal is "TRUE";
   attribute async_reg of strip_s   : signal is "TRUE";
   attribute async_reg of page_s    : signal is "TRUE";

   -- The frames shown, for the blinking of the cursor
   signal frame_cnt : std_logic_vector(4 downto 0) := (others => '0');

   -- Stage 0
   signal pix_x : std_logic_vector(10 downto 0);
   signal pix_y : std_logic_vector(10 downto 0);

   -- Stage 1. text_1 is '1' when the pixel is in the text, addr_1 is the
   -- address of its character, ovl_addr_1 that in the overlay, ovl_1 is '1'
   -- when the overlay is shown there, cur_1 is '1' when the character is the
   -- cursor's, and line_1 and col_1 are its row and column in the glyph.
   signal hs_1       : std_logic := not G_MODE.sync_active;
   signal vs_1       : std_logic := not G_MODE.sync_active;
   signal vis_1      : std_logic := '0';
   signal text_1     : std_logic := '0';
   signal addr_1     : std_logic_vector(G_SCR_ADDR_BITS - 1 downto 0) := (others => '0');
   signal ovl_addr_1 : std_logic_vector(11 downto 0) := (others => '0');
   signal ovl_1      : std_logic := '0';
   signal cur_1      : std_logic := '0';
   signal line_1     : std_logic_vector(4 downto 0) := (others => '0');
   signal col_1      : std_logic_vector(3 downto 0) := (others => '0');

   -- Stage 2
   signal hs_2       : std_logic := not G_MODE.sync_active;
   signal vs_2       : std_logic := not G_MODE.sync_active;
   signal vis_2      : std_logic := '0';
   signal text_2     : std_logic := '0';
   signal word_2     : std_logic_vector(31 downto 0);
   signal ovl_word_2 : std_logic_vector(31 downto 0);
   signal ovl_2      : std_logic := '0';
   signal cur_2      : std_logic := '0';
   signal line_2     : std_logic_vector(4 downto 0) := (others => '0');
   signal col_2      : std_logic_vector(3 downto 0) := (others => '0');

   -- Stage 3
   signal hs_3    : std_logic := not G_MODE.sync_active;
   signal vs_3    : std_logic := not G_MODE.sync_active;
   signal vis_3   : std_logic := '0';
   signal text_3  : std_logic := '0';
   signal glyph_3 : std_logic_vector(C_CHAR_WIDTH - 1 downto 0) := (others => '0');
   signal fg_3    : std_logic_vector(11 downto 0) := (others => '0');
   signal bg_3    : std_logic_vector(11 downto 0) := (others => '0');
   signal col_3   : std_logic_vector(3 downto 0) := (others => '0');

   -- Stage 4
   signal hs_4    : std_logic := not G_MODE.sync_active;
   signal vs_4    : std_logic := not G_MODE.sync_active;
   signal de_4    : std_logic := '0';
   signal color_4 : std_logic_vector(11 downto 0) := (others => '0');

begin

   assert C_COLS * C_CHAR_WIDTH <= G_MODE.h_visible and
          C_ALL_ROWS * C_CHAR_HEIGHT <= G_MODE.v_visible
      report "The text does not fit in the visible area"
      severity failure;

   assert G_SCR_ADDR_BITS >= 11
      report "text: the screen must hold its 2000 words"
      severity failure;


   ---------------------------------------------------------------------------
   -- The copy of the screen. It is written in the system clock domain, and
   -- read in the VGA clock domain, for stage 2 of the pipeline.
   ---------------------------------------------------------------------------

   i_scr_ram : entity work.scr_ram
      generic map (
         G_ADDR_BITS => G_SCR_ADDR_BITS
      )
      port map (
         wr_clk_i  => clk_i,
         wr_we_i   => scr_we_i,
         wr_addr_i => scr_addr_i,
         wr_data_i => scr_data_i,
         rd_clk_i  => vga_clk_i,
         rd_addr_i => addr_1,
         rd_data_o => word_2
      ); -- i_scr_ram


   ---------------------------------------------------------------------------
   -- The debugger's overlay, likewise
   ---------------------------------------------------------------------------

   i_ovl_ram : entity work.scr_ram
      generic map (
         G_ADDR_BITS => 12
      )
      port map (
         wr_clk_i  => clk_i,
         wr_we_i   => ovl_we_i,
         wr_addr_i => ovl_addr_i,
         wr_data_i => ovl_data_i,
         rd_clk_i  => vga_clk_i,
         rd_addr_i => ovl_addr_1,
         rd_data_o => ovl_word_2
      ); -- i_ovl_ram


   ---------------------------------------------------------------------------
   -- The screen's registers, from the system clock to the VGA clock. The
   -- system side holds the values and raises the request; the VGA side
   -- takes them and raises the acknowledge, which the system side waits for
   -- before it lowers the request and takes the next write. It is a
   -- four-phase handshake: req rises, ack rises, req falls, ack falls.
   -- While req is high, cur_x_r, cur_y_r, cur_mode_r, and offs_r do not
   -- change, because they are loaded only when req and the acknowledge
   -- seen by the system side are both low. So the VGA side reads them
   -- stable, and only the two request and acknowledge bits are
   -- synchronized.
   ---------------------------------------------------------------------------

   p_ctl_sys : process (clk_i)
   begin
      if rising_edge(clk_i) then
         ctl_ack_s <= ctl_ack_s(0) & ctl_ack;
         if ctl_req = '0' and ctl_ack_s(1) = '0' and ctl_dirty = '1' then
            ctl_req    <= '1';
            ctl_dirty  <= '0';
            cur_x_r    <= cur_x_i;
            cur_y_r    <= cur_y_i;
            cur_mode_r <= cur_mode_i;
            offs_r     <= offs_i;
         elsif ctl_req = '1' and ctl_ack_s(1) = '1' then
            ctl_req <= '0';
         end if;
         if ctl_we_i = '1' then
            ctl_dirty <= '1';
         end if;
      end if;
   end process p_ctl_sys;

   p_ctl_vga : process (vga_clk_i)
   begin
      if rising_edge(vga_clk_i) then
         ctl_req_s <= ctl_req_s(0) & ctl_req;
         if ctl_req_s(1) = '1' and ctl_ack = '0' then
            cur_x_vga    <= cur_x_r;
            cur_y_vga    <= cur_y_r;
            cur_mode_vga <= cur_mode_r;
            offs_vga     <= offs_r;
            ctl_ack      <= '1';
         elsif ctl_req_s(1) = '0' then
            ctl_ack <= '0';
         end if;
      end if;
   end process p_ctl_vga;

   p_ovl_vga : process (vga_clk_i)
   begin
      if rising_edge(vga_clk_i) then
         strip_s <= strip_s(0) & strip_i;
         page_s  <= page_s(0) & page_i;
      end if;
   end process p_ovl_vga;


   ---------------------------------------------------------------------------
   -- The pipeline, in the VGA clock domain
   ---------------------------------------------------------------------------

   i_pix : entity work.pix
      generic map (
         G_MODE => G_MODE
      )
      port map (
         clk_i   => vga_clk_i,
         pix_x_o => pix_x,
         pix_y_o => pix_y
      ); -- i_pix

   p_pipeline : process (vga_clk_i)
      variable x_v    : std_logic_vector(10 downto 0);
      variable y_v    : std_logic_vector(10 downto 0);
      variable row_v  : std_logic_vector(4 downto 0);
      variable col_v  : std_logic_vector(6 downto 0);
      variable addr_v : std_logic_vector(11 downto 0);
      variable prog_v : std_logic;
      variable word_v : std_logic_vector(31 downto 0);
      variable fg_v   : std_logic_vector(11 downto 0);
      variable bg_v   : std_logic_vector(11 downto 0);
      variable show_v : std_logic;
   begin
      if rising_edge(vga_clk_i) then
         -- The cursor blinks with bit 4 of the frame counter: 16 frames on
         -- and 16 off, which is about twice a second at 60 Hz.
         if pix_x = 0 and pix_y = 0 then
            frame_cnt <= frame_cnt + 1;
         end if;

         -- Stage 1. Outside the text the address is not used.
         x_v := pix_x - C_X0;
         y_v := pix_y - C_Y0;
         hs_1 <= not G_MODE.sync_active;
         vs_1 <= not G_MODE.sync_active;
         if pix_x >= C_HS_START and pix_x < C_HS_START + G_MODE.h_sync then
            hs_1 <= G_MODE.sync_active;
         end if;
         if pix_y >= C_VS_START and pix_y < C_VS_START + G_MODE.v_sync then
            vs_1 <= G_MODE.sync_active;
         end if;
         vis_1 <= '1' when pix_x < G_MODE.h_visible and pix_y < G_MODE.v_visible else '0';
         -- prog_v is '1' in the program's rows, and '0' in the strip's.
         prog_v := '0';
         if pix_y < C_Y0 + C_ROWS * C_CHAR_HEIGHT then
            prog_v := '1';
         end if;
         text_1 <= '0';
         if pix_x >= C_X0 and pix_x < C_X0 + C_COLS * C_CHAR_WIDTH and
            pix_y >= C_Y0 and pix_y < C_Y0 + C_ALL_ROWS * C_CHAR_HEIGHT and
            (prog_v = '1' or strip_s(1) = '1') then
            text_1 <= '1';
         end if;
         -- The characters are 16x32 pixels, so the row is y / 32 and the
         -- column is x / 16.
         -- row * 80 = row * 64 + row * 16
         row_v  := y_v(9 downto 5);
         col_v  := x_v(10 downto 4);
         addr_v := ('0' & row_v & "000000") + ("000" & row_v & "0000") + ("00000" & col_v);
         -- In the program's rows addr_v is below 2000, so 11 bits of it are
         -- the address in the screen.
         addr_1     <= offs_vga + addr_v(10 downto 0);
         ovl_addr_1 <= addr_v;
         ovl_1      <= not prog_v or page_s(1);
         cur_1      <= '0';
         if row_v = cur_y_vga and col_v = cur_x_vga and prog_v = '1' and page_s(1) = '0' then
            cur_1 <= '1';
         end if;
         line_1 <= y_v(4 downto 0);
         col_1  <= x_v(3 downto 0);

         -- Stage 2. word_2 is read by i_scr_ram.
         hs_2   <= hs_1;
         vs_2   <= vs_1;
         vis_2  <= vis_1;
         text_2 <= text_1;
         ovl_2  <= ovl_1;
         cur_2  <= cur_1;
         line_2 <= line_1;
         col_2  <= col_1;

         -- Stage 3. The cursor swaps the colors of its character.
         word_v := word_2;
         if ovl_2 = '1' then
            word_v := ovl_word_2;
         end if;
         glyph_3 <= C_FONT(to_integer(word_v(7 downto 0) & line_2));
         fg_v   := word_v(19 downto 8);
         bg_v   := word_v(31 downto 20);
         show_v := '0';
         if cur_2 = '1' and cur_mode_vga(0) = '1' then
            show_v := '1';
            if cur_mode_vga(1) = '1' and frame_cnt(4) = '0' then
               show_v := '0';
            end if;
            if cur_mode_vga(2) = '1' and line_2 < C_CHAR_HEIGHT - C_SMALL_CURSOR then
               show_v := '0';
            end if;
         end if;
         if show_v = '1' then
            fg_3 <= bg_v;
            bg_3 <= fg_v;
         else
            fg_3 <= fg_v;
            bg_3 <= bg_v;
         end if;
         hs_3   <= hs_2;
         vs_3   <= vs_2;
         vis_3  <= vis_2;
         text_3 <= text_2;
         col_3  <= col_2;

         -- Stage 4. The leftmost pixel of the glyph is its bit 15.
         color_4 <= (others => '0');
         if text_3 = '1' then
            if glyph_3(C_CHAR_WIDTH - 1 - to_integer(col_3)) = '1' then
               color_4 <= fg_3;
            else
               color_4 <= bg_3;
            end if;
         end if;
         de_4 <= vis_3;
         hs_4 <= hs_3;
         vs_4 <= vs_3;
      end if;
   end process p_pipeline;

   -- Each component is expanded to 8 bits by repeating its 4 bits, so that the
   -- full range is used (0xF is 0xFF).
   vga_hs_o    <= hs_4;
   vga_vs_o    <= vs_4;
   vga_de_o    <= de_4;
   vga_red_o   <= color_4(11 downto 8) & color_4(11 downto 8);
   vga_green_o <= color_4(7 downto 4) & color_4(7 downto 4);
   vga_blue_o  <= color_4(3 downto 0) & color_4(3 downto 0);

end architecture synthesis;
