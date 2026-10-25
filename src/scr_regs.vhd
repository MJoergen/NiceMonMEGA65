-- The screen's registers at 0xFFFFFF80-8F (src/nicemon.vhd), numbered as
-- QNICE-FPGA's VGA registers at 0xFF30, for a display of the screen
-- (src/video/text.vhd).
--
-- THEORY OF OPERATION
-- nicemon serves one request in a cycle, the link's or the core's, and
-- gives it here with stb_i when it is to 0xFFFFFF80-8F; addr_i is the word's
-- offset. A write sets the register of its word in the same cycle. rdata_o
-- is the word at addr_i, combinationally, which nicemon registers for its
-- acknowledge in the next cycle. The registers, by their offset:
--   0  The state. Bits 11..4 are kept and read back: bit 6 shows the
--      cursor, bit 5 makes it blink, bit 4 makes it small, and bit 10
--      enables the display offset. The other bits read 0.
--   1  The cursor's column, bits 6..0.
--   2  The cursor's row, bits 4..0.
--   5  The display offset, in words, bits G_SCR_ADDR_BITS - 1..0: the
--      display shows the 2000 words from it, so adding 80 scrolls a line.
-- The words 3, 4, and 6-F read 0 and take no write.
--
-- The registers go out on cur_x_o, cur_y_o, cur_mode_o (bit 0 shown, bit 1
-- blinking, bit 2 small), and offs_o, which is 0 while bit 10 of the state
-- is 0. ctl_we_o is '1' for a cycle after any write to 0xFFFFFF80-8F, and
-- after clear_i or reset, which clear the registers, so that the display
-- takes them.
--
-- With G_FORMAL, it states the properties that formal/scr_regs.sby proves:
-- a write to a register's word sets it, the registers change only so or by
-- a clear or reset, each word reads its register, or 0, and ctl_we_o
-- follows each write, clear, and reset.
--
-- RESET
-- Synchronous. Reset clears the registers, as clear_i does.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity scr_regs is
   generic (
      G_SCR_ADDR_BITS : natural;
      -- The properties for formal/scr_regs.sby
      G_FORMAL        : boolean := false
   );
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;
      -- The clear of the memory, which clears the registers too
      clear_i    : in  std_logic;
      -- The request served in this cycle, when it is to 0xFFFFFF80-8F
      stb_i      : in  std_logic;
      we_i       : in  std_logic;
      addr_i     : in  std_logic_vector(3 downto 0);
      wdata_i    : in  std_logic_vector(31 downto 0);
      rdata_o    : out std_logic_vector(31 downto 0);
      -- The display
      ctl_we_o   : out std_logic;
      cur_x_o    : out std_logic_vector(6 downto 0);
      cur_y_o    : out std_logic_vector(4 downto 0);
      cur_mode_o : out std_logic_vector(2 downto 0);
      offs_o     : out std_logic_vector(G_SCR_ADDR_BITS - 1 downto 0)
   );
end entity scr_regs;

architecture synthesis of scr_regs is

   signal state  : std_logic_vector(11 downto 4)            := (others => '0');
   signal cur_x  : std_logic_vector(6 downto 0)             := (others => '0');
   signal cur_y  : std_logic_vector(4 downto 0)             := (others => '0');
   signal offs   : std_logic_vector(G_SCR_ADDR_BITS - 1 downto 0) := (others => '0');
   signal ctl_we : std_logic                                := '0';

begin

   p_write : process (clk_i)
   begin
      if rising_edge(clk_i) then
         ctl_we <= '0';

         if stb_i = '1' and we_i = '1' then
            ctl_we <= '1';

            case addr_i is
               when X"0"   => state <= wdata_i(11 downto 4);
               when X"1"   => cur_x <= wdata_i(6 downto 0);
               when X"2"   => cur_y <= wdata_i(4 downto 0);
               when X"5"   => offs  <= wdata_i(G_SCR_ADDR_BITS - 1 downto 0);
               when others => null;
            end case;

         end if;

         if clear_i = '1' or rst_i = '1' then
            state  <= (others => '0');
            cur_x  <= (others => '0');
            cur_y  <= (others => '0');
            offs   <= (others => '0');
            ctl_we <= '1';
         end if;
      end if;
   end process p_write;

   p_read : process (all)
   begin
      rdata_o <= (others => '0');

      case addr_i is
         when X"0"   => rdata_o(11 downto 4) <= state;
         when X"1"   => rdata_o(6 downto 0) <= cur_x;
         when X"2"   => rdata_o(4 downto 0) <= cur_y;
         when X"5"   => rdata_o(G_SCR_ADDR_BITS - 1 downto 0) <= offs;
         when others => null;
      end case;
   end process p_read;

   ctl_we_o   <= ctl_we;
   cur_x_o    <= cur_x;
   cur_y_o    <= cur_y;
   cur_mode_o <= state(4) & state(5) & state(6);
   offs_o     <= offs when state(10) = '1' else
                 (others => '0');


   gen_formal : if G_FORMAL generate
      -- A write to the word of register n in this cycle: the state, the
      -- column, the row, and the offset
      signal f_wr : std_logic_vector(3 downto 0);
      -- A write, a clear, or a reset in this cycle
      signal f_any : std_logic;
   begin

      f_wr(0) <= stb_i and we_i when addr_i = X"0" else '0';
      f_wr(1) <= stb_i and we_i when addr_i = X"1" else '0';
      f_wr(2) <= stb_i and we_i when addr_i = X"2" else '0';
      f_wr(3) <= stb_i and we_i when addr_i = X"5" else '0';
      f_any   <= (stb_i and we_i) or clear_i or rst_i;

      -- psl default clock is rising_edge(clk_i);

      -- A write sets its register, and nothing else changes one but a clear
      -- or reset, which clears them all.
      -- psl f_state_wr : assert always
      --    {f_wr(0) and not clear_i and not rst_i} |=> {state = prev(wdata_i(11 downto 4))};
      -- psl f_cur_x_wr : assert always
      --    {f_wr(1) and not clear_i and not rst_i} |=> {cur_x = prev(wdata_i(6 downto 0))};
      -- psl f_cur_y_wr : assert always
      --    {f_wr(2) and not clear_i and not rst_i} |=> {cur_y = prev(wdata_i(4 downto 0))};
      -- psl f_offs_wr : assert always
      --    {f_wr(3) and not clear_i and not rst_i} |=>
      --    {offs = prev(wdata_i(G_SCR_ADDR_BITS - 1 downto 0))};
      -- psl f_state_keep : assert always {not f_wr(0) and not clear_i and not rst_i} |=> {stable(state)};
      -- psl f_cur_x_keep : assert always {not f_wr(1) and not clear_i and not rst_i} |=> {stable(cur_x)};
      -- psl f_cur_y_keep : assert always {not f_wr(2) and not clear_i and not rst_i} |=> {stable(cur_y)};
      -- psl f_offs_keep : assert always {not f_wr(3) and not clear_i and not rst_i} |=> {stable(offs)};
      -- psl f_clear : assert always
      --    {clear_i or rst_i} |=> {state = 0 and cur_x = 0 and cur_y = 0 and offs = 0};

      -- The display hears of each write, clear, and reset, and of nothing
      -- else.
      -- psl f_ctl_we : assert always {f_any} |=> {ctl_we_o};
      -- psl f_ctl_quiet : assert always {not f_any} |=> {not ctl_we_o};

      -- Each word reads its register, or 0.
      -- psl f_rd_state : assert always
      --    addr_i = X"0" -> rdata_o(31 downto 12) = 0 and rdata_o(11 downto 4) = state and
      --                     rdata_o(3 downto 0) = 0;
      -- psl f_rd_cur_x : assert always
      --    addr_i = X"1" -> rdata_o(31 downto 7) = 0 and rdata_o(6 downto 0) = cur_x;
      -- psl f_rd_cur_y : assert always
      --    addr_i = X"2" -> rdata_o(31 downto 5) = 0 and rdata_o(4 downto 0) = cur_y;
      -- psl f_rd_offs : assert always
      --    addr_i = X"5" -> rdata_o(31 downto G_SCR_ADDR_BITS) = 0 and
      --                     rdata_o(G_SCR_ADDR_BITS - 1 downto 0) = offs;
      -- psl f_rd_none : assert always
      --    (addr_i = X"3" or addr_i = X"4" or addr_i > X"5") -> rdata_o = 0;

      -- The offset goes out only while bit 10 of the state enables it.
      -- psl f_offs_on : assert always state(10) = '1' -> offs_o = offs;
      -- psl f_offs_off : assert always state(10) = '0' -> offs_o = 0;

      -- psl c_offs : cover {f_wr(0) and wdata_i(10) and not rst_i; f_wr(3) and not rst_i; offs_o /= 0};
   end generate gen_formal;

end architecture synthesis;
