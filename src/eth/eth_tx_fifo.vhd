-- The FIFO of Ethernet frames to send, from the system clock domain to the
-- PHY's clock domain. It takes whole frames a byte at a time, with the last
-- byte of each marked, and gives them to rmii_tx.vhd only when they are
-- whole, so that a frame, once started, is never short of a byte.
--
-- THEORY OF OPERATION
-- The memory (eth_ram.vhd) has 2^G_ADDR_BITS bytes, each with a bit that
-- marks the last of a frame. The pointers have a bit more, so that a full
-- FIFO differs from an empty one. The write side takes a byte when
-- wr_valid_i and wr_ready_o are both '1', and writes it at wr_ptr;
-- wr_ready_o is '0' while the FIFO is full. The frame stays invisible to the
-- reader until its last byte, when the committed pointer cmt_ptr moves to
-- its end.
-- The read side reads a byte when there is one before cmt_ptr, and holds it
-- on rd_data_o and rd_last_o with rd_valid_o until rd_ready_i, so a byte
-- takes at least two cycles.
-- The pointers cross between the clocks as in eth_rx_fifo.vhd: the read
-- pointer in Gray code, through two registers, and the committed pointer as
-- a value that is stable when it is read, after cmt_toggle, which flips at
-- each commit, has passed two registers on the read side. Commits are at
-- least a frame apart, more than the few cycles of the read clock that
-- takes (contract a).
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) A frame has at least 14 bytes, an Ethernet header, so that commits
--    are at least 14 cycles of wr_clk_i apart, which is more than four
--    cycles of rd_clk_i, as long as wr_clk_i is no more than three times as
--    fast as rd_clk_i.
-- b) A frame has at most 2^G_ADDR_BITS bytes, or it never fits.
-- c) wr_rst_i and rd_rst_i are both held for longer than three cycles of
--    each clock, at the same time, so that the pointers each side sees of
--    the other are 0 when each side starts. A reset of one side alone
--    leaves the two sides out of step for good.
--
-- With G_FORMAL, it states the properties that formal/eth_tx_fifo.sby
-- proves across both clocks, under the contracts, which it assumes, with
-- commits 14 cycles of wr_clk_i apart whatever the frames' lengths, and
-- one reset of both sides at the start. The read pointer that the write
-- side sees is at or before the real one, which is at or before the
-- committed pointer that the read side has, which is at or before
-- cmt_ptr, which is at or before wr_ptr, all within 2^G_ADDR_BITS bytes;
-- wr_ready_o is '0' exactly when the write side sees the FIFO full; a
-- write never lands on a byte not yet read; a byte taken moves wr_ptr on
-- by one, and cmt_ptr moves only to the end of a last byte; the read side
-- takes cmt_ptr only after it has stood still for two cycles of
-- rd_clk_i, and then has it exactly; a byte offered stays until it is
-- taken; and a byte that the solver picks, written at any pointer, stays
-- in the memory until its turn, and is then the byte read, with its mark.
-- The memory shows the solver the picked byte's word (eth_ram.vhd).
--
-- RESET
-- Synchronous, on each side to its clock: wr_rst_i on the write side and
-- rd_rst_i on the read side. Reset empties the FIFO.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

library work;
   use work.eth_pkg.all;

entity eth_tx_fifo is
   generic (
      G_ADDR_BITS : natural := 11;
      -- The properties for formal/eth_tx_fifo.sby
      G_FORMAL    : boolean := false
   );
   port (
      -- The write side, in the system clock domain
      wr_clk_i   : in  std_logic;
      wr_rst_i   : in  std_logic;
      wr_data_i  : in  std_logic_vector(7 downto 0);
      wr_last_i  : in  std_logic;
      wr_valid_i : in  std_logic;
      wr_ready_o : out std_logic;

      -- The read side, in the PHY's clock domain
      rd_clk_i   : in  std_logic;
      rd_rst_i   : in  std_logic;
      rd_data_o  : out std_logic_vector(7 downto 0) := (others => '0');
      rd_last_o  : out std_logic                    := '0';
      rd_valid_o : out std_logic;
      rd_ready_i : in  std_logic
   );
end entity eth_tx_fifo;

architecture synthesis of eth_tx_fifo is

   subtype t_ptr is std_logic_vector(G_ADDR_BITS downto 0);

   -- The write side
   signal wr_ptr     : t_ptr     := (others => '0');
   signal cmt_ptr    : t_ptr     := (others => '0');
   signal cmt_toggle : std_logic := '0';
   -- The read pointer, in Gray code, through two registers
   signal rd_gray_s0 : t_ptr     := (others => '0');
   signal rd_gray_s1 : t_ptr     := (others => '0');
   signal used       : t_ptr;
   signal wr_ready   : std_logic;
   signal ram_we     : std_logic;

   -- The read side
   signal rd_ptr  : t_ptr                        := (others => '0');
   signal rd_gray : t_ptr                        := (others => '0');
   -- cmt_toggle through two registers, and its value before
   signal cmt_sync : std_logic_vector(2 downto 0) := "000";
   signal cmt_rd   : t_ptr                        := (others => '0');
   -- A byte was read from the memory in the cycle before.
   signal fetch     : std_logic                    := '0';
   signal ram_rdata : std_logic_vector(8 downto 0);
   signal rd_valid  : std_logic                    := '0';

   -- The word of the memory that the properties follow, with G_FORMAL
   signal f_addr : std_logic_vector(G_ADDR_BITS - 1 downto 0) := (others => '0');
   signal f_word : std_logic_vector(8 downto 0);

   attribute async_reg : string;
   attribute async_reg of rd_gray_s0 : signal is "TRUE";
   attribute async_reg of rd_gray_s1 : signal is "TRUE";
   attribute async_reg of cmt_sync   : signal is "TRUE";

begin

   ---------------------------------------------------------------------------
   -- The write side
   ---------------------------------------------------------------------------

   -- The bytes in the memory, committed or not, as the write side sees them
   used     <= wr_ptr - from_gray(rd_gray_s1);
   wr_ready <= not used(G_ADDR_BITS);
   ram_we   <= wr_valid_i and wr_ready;

   p_write : process (wr_clk_i)
   begin
      if rising_edge(wr_clk_i) then
         rd_gray_s0 <= rd_gray;
         rd_gray_s1 <= rd_gray_s0;

         if ram_we = '1' then
            wr_ptr <= wr_ptr + 1;
            if wr_last_i = '1' then
               cmt_ptr    <= wr_ptr + 1;
               cmt_toggle <= not cmt_toggle;
            end if;
         end if;

         if wr_rst_i = '1' then
            wr_ptr     <= (others => '0');
            cmt_ptr    <= (others => '0');
            cmt_toggle <= '0';
            rd_gray_s0 <= (others => '0');
            rd_gray_s1 <= (others => '0');
         end if;
      end if;
   end process p_write;

   wr_ready_o <= wr_ready;


   i_eth_ram : entity work.eth_ram
      generic map (
         G_ADDR_BITS => G_ADDR_BITS,
         G_FORMAL    => G_FORMAL
      )
      port map (
         wr_clk_i  => wr_clk_i,
         wr_we_i   => ram_we,
         wr_addr_i => wr_ptr(G_ADDR_BITS - 1 downto 0),
         wr_data_i => wr_last_i & wr_data_i,
         rd_clk_i  => rd_clk_i,
         rd_addr_i => rd_ptr(G_ADDR_BITS - 1 downto 0),
         rd_data_o => ram_rdata,
         f_addr_i  => f_addr,
         f_data_o  => f_word
      ); -- i_eth_ram


   ---------------------------------------------------------------------------
   -- The read side
   ---------------------------------------------------------------------------

   p_read : process (rd_clk_i)
   begin
      if rising_edge(rd_clk_i) then
         cmt_sync <= cmt_sync(1 downto 0) & cmt_toggle;
         if cmt_sync(2) /= cmt_sync(1) then
            cmt_rd <= cmt_ptr;
         end if;

         if rd_ready_i = '1' then
            rd_valid <= '0';
         end if;

         -- The byte read in the cycle before
         if fetch = '1' then
            rd_data_o <= ram_rdata(7 downto 0);
            rd_last_o <= ram_rdata(8);
            rd_valid  <= '1';
         end if;

         -- The memory reads at rd_ptr in every cycle; this read is kept.
         fetch <= '0';
         if fetch = '0' and rd_ptr /= cmt_rd and (rd_valid = '0' or rd_ready_i = '1') then
            fetch  <= '1';
            rd_ptr <= rd_ptr + 1;
         end if;

         rd_gray <= to_gray(rd_ptr);

         if rd_rst_i = '1' then
            cmt_sync <= "000";
            cmt_rd   <= (others => '0');
            rd_valid <= '0';
            fetch    <= '0';
            rd_ptr   <= (others => '0');
            rd_gray  <= (others => '0');
         end if;
      end if;
   end process p_read;

   rd_valid_o <= rd_valid;


   gen_formal : if G_FORMAL generate
      constant C_SIZE : natural := 2 ** G_ADDR_BITS;

      -- The solver's time, a step of which may hold an edge of either clock
      signal f_gclk : std_logic;
      -- The read pointer, as rd_gray, rd_gray_s0, and rd_gray_s1 hold it
      signal f_r0 : t_ptr;
      signal f_r1 : t_ptr;
      signal f_r2 : t_ptr;
      -- The cycles of wr_clk_i since the last commit, as far as 13
      signal f_since : natural range 0 to 13 := 13;
      -- cmt_ptr at the last edge of rd_clk_i, and the edges since it
      -- changed, as far as 2
      signal f_cmt_seen : t_ptr                := (others => '0');
      signal f_cmt_age  : natural range 0 to 2 := 0;
      -- The byte that the solver picks, at any write: where it is, what it
      -- is, its mark, and whether it was written over before its turn
      signal f_pick   : std_logic;
      signal f_picked : std_logic                    := '0';
      signal f_ptr    : t_ptr                        := (others => '0');
      signal f_data   : std_logic_vector(7 downto 0) := (others => '0');
      signal f_last   : std_logic                    := '0';
      signal f_cancel : std_logic                    := '0';
      -- Its turn: it is read from the memory, and the cycle after
      signal f_turn   : std_logic;
      signal f_turned : std_logic                    := '0';
      signal f_t1     : std_logic                    := '0';
      -- The clocks and the reset in the step before, and the edges of each
      -- clock in the reset, as far as 4
      signal f_wr_clk : std_logic            := '0';
      signal f_rd_clk : std_logic            := '0';
      signal f_rst    : std_logic            := '1';
      signal f_wr_n   : natural range 0 to 4 := 0;
      signal f_rd_n   : natural range 0 to 4 := 0;

      attribute gclk : boolean;
      attribute gclk of f_gclk : signal is true;
      attribute anyseq : boolean;
      attribute anyseq of f_pick : signal is true;
   begin

      f_addr <= f_ptr(G_ADDR_BITS - 1 downto 0);

      f_r0 <= from_gray(rd_gray);
      f_r1 <= from_gray(rd_gray_s0);
      f_r2 <= from_gray(rd_gray_s1);

      p_f_write : process (wr_clk_i)
      begin
         if rising_edge(wr_clk_i) then
            if f_since < 13 then
               f_since <= f_since + 1;
            end if;
            if ram_we = '1' and wr_last_i = '1' then
               f_since <= 0;
            end if;

            if f_picked = '0' and ram_we = '1' and f_pick = '1' then
               f_picked <= '1';
               f_ptr    <= wr_ptr;
               f_data   <= wr_data_i;
               f_last   <= wr_last_i;
            elsif f_picked = '1' and ram_we = '1' and
                  wr_ptr(G_ADDR_BITS - 1 downto 0) = f_ptr(G_ADDR_BITS - 1 downto 0) then
               f_cancel <= '1';
            end if;

            if wr_rst_i = '1' then
               f_since  <= 13;
               f_picked <= '0';
               f_cancel <= '0';
            end if;
         end if;
      end process p_f_write;

      f_turn <= '1' when f_picked = '1' and f_cancel = '0' and f_turned = '0' and
                         fetch = '0' and rd_ptr /= cmt_rd and
                         (rd_valid = '0' or rd_ready_i = '1') and rd_ptr = f_ptr else
                '0';

      p_f_read : process (rd_clk_i)
      begin
         if rising_edge(rd_clk_i) then
            f_cmt_seen <= cmt_ptr;
            if cmt_ptr /= f_cmt_seen then
               f_cmt_age <= 0;
            elsif f_cmt_age < 2 then
               f_cmt_age <= f_cmt_age + 1;
            end if;

            f_t1 <= f_turn;
            if f_turn = '1' then
               f_turned <= '1';
            end if;

            if rd_rst_i = '1' then
               f_t1     <= '0';
               f_turned <= '0';
            end if;
         end if;
      end process p_f_read;

      p_f_steps : process (f_gclk)
      begin
         if rising_edge(f_gclk) then
            f_wr_clk <= wr_clk_i;
            f_rd_clk <= rd_clk_i;
            f_rst    <= wr_rst_i;
            if wr_clk_i = '1' and f_wr_clk = '0' and f_wr_n < 4 then
               f_wr_n <= f_wr_n + 1;
            end if;
            if rd_clk_i = '1' and f_rd_clk = '0' and f_rd_n < 4 then
               f_rd_n <= f_rd_n + 1;
            end if;
         end if;
      end process p_f_steps;

      -- In every step of the solver: the reset, and the pointers of the two
      -- sides

      -- psl default clock is rising_edge(f_gclk);

      -- psl f_contract_c_same : assume always wr_rst_i = rd_rst_i;
      -- psl f_contract_c_first : assume wr_rst_i;
      -- psl f_contract_c_long : assume always f_rst = '1' and (f_wr_n < 4 or f_rd_n < 4) ->
      --    wr_rst_i = '1';
      -- psl f_contract_c_once : assume always f_rst = '0' -> wr_rst_i = '0';

      -- psl f_wr_reset : assert always wr_rst_i = '1' and f_wr_n >= 2 ->
      --    (wr_ptr = 0 and cmt_ptr = 0 and cmt_toggle = '0' and rd_gray_s0 = 0 and
      --     rd_gray_s1 = 0 and f_since = 13 and f_picked = '0' and f_cancel = '0');
      -- psl f_rd_reset : assert always rd_rst_i = '1' and f_rd_n >= 2 ->
      --    (rd_ptr = 0 and rd_gray = 0 and cmt_sync = "000" and cmt_rd = 0 and
      --     rd_valid = '0' and fetch = '0' and f_turned = '0' and f_t1 = '0');

      -- psl f_lag0 : assert always not rd_rst_i -> rd_ptr - f_r0 <= 1;
      -- psl f_lag1 : assert always not rd_rst_i -> rd_ptr - f_r0 <= rd_ptr - f_r1;
      -- psl f_lag2 : assert always not rd_rst_i -> rd_ptr - f_r1 <= rd_ptr - f_r2;
      -- psl f_rd_cmt : assert always not rd_rst_i -> rd_ptr - f_r2 <= cmt_rd - f_r2;
      -- psl f_cmt_rd : assert always not rd_rst_i -> cmt_rd - f_r2 <= cmt_ptr - f_r2;
      -- psl f_cmt_wr : assert always not wr_rst_i -> cmt_ptr - f_r2 <= wr_ptr - f_r2;
      -- psl f_size : assert always not wr_rst_i -> wr_ptr - f_r2 <= C_SIZE;
      -- psl f_full : assert always not wr_rst_i -> (wr_ready = '0' <-> used = C_SIZE);
      -- psl f_room : assert always not wr_rst_i and ram_we = '1' -> wr_ptr - rd_ptr < C_SIZE;
      -- psl f_cmt_sync : assert always not wr_rst_i and
      --    cmt_sync(2) = cmt_sync(1) and cmt_sync(1) = cmt_sync(0) and
      --    cmt_sync(0) = cmt_toggle -> cmt_rd = cmt_ptr;
      -- psl f_word_kept : assert always wr_rst_i = '0' and f_picked = '1' and f_cancel = '0' ->
      --    f_word = f_last & f_data;
      -- psl f_ahead : assert always not wr_rst_i and
      --    f_picked = '1' and f_cancel = '0' and f_turned = '0' -> f_ptr - rd_ptr < C_SIZE;

      -- psl c_full : cover {not wr_ready and not wr_rst_i};
      -- psl c_wrap : cover {rd_ptr = C_SIZE and rd_rst_i = '0'};

      b_write : block is
      begin

         -- psl default clock is rising_edge(wr_clk_i);

         -- psl f_contract_a : assume always ram_we = '1' and wr_last_i = '1' -> f_since = 13;

         -- psl f_take : assert always {ram_we and not wr_rst_i} |=>
         --    {wr_ptr = prev(wr_ptr) + 1};
         -- psl f_no_take : assert always {not ram_we and not wr_rst_i} |=>
         --    {wr_ptr = prev(wr_ptr)};
         -- psl f_commit : assert always {ram_we and wr_last_i and not wr_rst_i} |=>
         --    {cmt_ptr = wr_ptr};
         -- psl f_no_commit : assert always {not (ram_we and wr_last_i) and not wr_rst_i} |=>
         --    {cmt_ptr = prev(cmt_ptr)};

         -- psl c_commit : cover {ram_we and wr_last_i and not wr_rst_i};

      end block b_write;

      b_read : block is
      begin

         -- psl default clock is rising_edge(rd_clk_i);

         -- psl f_hold : assert always {rd_valid and not rd_ready_i and not rd_rst_i} |=>
         --    {rd_valid = '1' and rd_data_o = prev(rd_data_o) and rd_last_o = prev(rd_last_o)};
         -- psl f_fetch : assert always not rd_rst_i and fetch -> not rd_valid;
         -- psl f_reads : assert always {rd_ptr /= cmt_rd and fetch = '0' and
         --    (rd_valid = '0' or rd_ready_i = '1') and rd_rst_i = '0'} |=> {fetch};
         -- psl f_stable : assert always {not rd_rst_i} |=>
         --    {rd_rst_i = '1' or cmt_rd = prev(cmt_rd) or
         --     (cmt_rd = prev(cmt_ptr) and prev(cmt_ptr) = prev(f_cmt_seen) and
         --      prev(f_cmt_age) >= 1)};
         -- psl f_read : assert always not rd_rst_i and f_t1 -> ram_rdata = f_last & f_data;
         -- psl f_byte : assert always {f_t1 and not rd_rst_i} |=>
         --    {rd_data_o = f_data and rd_last_o = f_last};

         -- psl c_byte : cover {f_t1 and f_last and not rd_rst_i};
         -- psl c_held : cover {rd_valid and not rd_ready_i and not rd_rst_i; rd_valid};

      end block b_read;

   end generate gen_formal;

end architecture synthesis;
