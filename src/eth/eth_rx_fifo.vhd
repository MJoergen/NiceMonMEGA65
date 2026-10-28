-- The FIFO of received Ethernet frames, from the PHY's clock domain to the
-- system clock domain. It takes the bytes of rmii_rx.vhd and the verdict
-- of rx_fcs.vhd, and gives the good frames only, without their frame check
-- sequence, a byte at a time, with the last byte of each marked.
--
-- THEORY OF OPERATION
-- The memory (eth_ram.vhd) has 2^G_ADDR_BITS bytes, each with a bit that
-- marks the last of a frame. The pointers have a bit more, so that a full
-- FIFO differs from an empty one. The write side writes each byte at
-- wr_ptr as it comes, and the frame stays invisible to the reader until
-- wr_ok_i. Then the last byte before the check sequence, five before
-- wr_ptr, is written again with its mark, and the committed pointer cmt_ptr
-- moves to the end of that byte, which drops the check sequence. wr_bad_i
-- sets wr_ptr back to cmt_ptr, which drops the frame. A byte that finds the
-- FIFO full drops the rest of its frame too; at its wr_ok_i, wr_drop_o is
-- '1' for a cycle, and wr_ptr goes back as for wr_bad_i.
-- The read side reads a byte when there is one before cmt_ptr, and holds it
-- on rd_data_o and rd_last_o with rd_valid_o until rd_ready_i, so a byte
-- takes at least two cycles.
-- The read pointer moves by one at a time, so it crosses to the write side
-- in Gray code, through two registers. The committed pointer moves a frame
-- at a time, so it crosses as a value that is stable when it is read: at
-- each commit cmt_toggle flips, and when the flip has passed two registers
-- on the read side, that side takes cmt_ptr, which by then has long
-- settled. Commits are a frame apart, far more than the few cycles that
-- takes. The write side sees the read pointer late, and the read side the
-- committed pointer, so each sees the FIFO a little fuller than it is,
-- which is safe.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) A frame with wr_ok_i has at least 5 bytes, its check sequence and one
--    more (rx_fcs.vhd gives wr_ok_i only for 64 or more).
-- b) wr_ok_i and wr_bad_i are at the end of a frame, after its last byte
--    and before the first of the next, and never with wr_valid_i.
-- c) wr_rst_i and rd_rst_i are both held for longer than three cycles of
--    each clock, at the same time, so that the pointers each side sees of
--    the other are 0 when each side starts.
--
-- RESET
-- Synchronous, on each side to its clock: wr_rst_i on the write side and
-- rd_rst_i on the read side. Reset empties the FIFO.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

library work;
   use work.eth_pkg.all;

entity eth_rx_fifo is
   generic (
      G_ADDR_BITS : natural := 11
   );
   port (
      -- The write side, in the PHY's clock domain
      wr_clk_i   : in  std_logic;
      wr_rst_i   : in  std_logic;
      wr_data_i  : in  std_logic_vector(7 downto 0);
      wr_valid_i : in  std_logic;
      wr_ok_i    : in  std_logic;
      wr_bad_i   : in  std_logic;
      wr_drop_o  : out std_logic := '0';

      -- The read side, in the system clock domain
      rd_clk_i   : in  std_logic;
      rd_rst_i   : in  std_logic;
      rd_data_o  : out std_logic_vector(7 downto 0) := (others => '0');
      rd_last_o  : out std_logic                    := '0';
      rd_valid_o : out std_logic;
      rd_ready_i : in  std_logic
   );
end entity eth_rx_fifo;

architecture synthesis of eth_rx_fifo is

   subtype t_ptr is std_logic_vector(G_ADDR_BITS downto 0);

   -- The write side
   signal wr_ptr     : t_ptr                         := (others => '0');
   signal cmt_ptr    : t_ptr                         := (others => '0');
   signal cmt_toggle : std_logic                     := '0';
   -- A byte of this frame found the FIFO full.
   signal overflow : std_logic                     := '0';
   -- The last five bytes, the newest in bits 7..0
   signal hist : std_logic_vector(39 downto 0) := (others => '0');
   -- The read pointer, in Gray code, through two registers
   signal rd_gray_s0 : t_ptr                         := (others => '0');
   signal rd_gray_s1 : t_ptr                         := (others => '0');
   signal used       : t_ptr;
   signal full       : std_logic;
   signal ram_we     : std_logic;
   signal ram_waddr  : t_ptr;
   signal ram_wdata  : std_logic_vector(8 downto 0);

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

   attribute async_reg : string;
   attribute async_reg of rd_gray_s0 : signal is "TRUE";
   attribute async_reg of rd_gray_s1 : signal is "TRUE";
   attribute async_reg of cmt_sync   : signal is "TRUE";

begin

   ---------------------------------------------------------------------------
   -- The write side
   ---------------------------------------------------------------------------

   -- The bytes in the memory, committed or not, as the write side sees them
   used <= wr_ptr - from_gray(rd_gray_s1);
   full <= used(G_ADDR_BITS);

   ram_we    <= '1' when overflow = '0' and wr_ok_i = '1' else
                '1' when overflow = '0' and wr_valid_i = '1' and full = '0' else
                '0';
   ram_waddr <= wr_ptr - 5 when wr_ok_i = '1' else
                wr_ptr;
   ram_wdata <= '1' & hist(39 downto 32) when wr_ok_i = '1' else
                '0' & wr_data_i;

   p_write : process (wr_clk_i)
   begin
      if rising_edge(wr_clk_i) then
         wr_drop_o  <= '0';
         rd_gray_s0 <= rd_gray;
         rd_gray_s1 <= rd_gray_s0;

         if wr_valid_i = '1' then
            hist <= hist(31 downto 0) & wr_data_i;
            if overflow = '0' then
               if full = '1' then
                  overflow <= '1';
               else
                  wr_ptr <= wr_ptr + 1;
               end if;
            end if;
         end if;

         if wr_ok_i = '1' then
            if overflow = '1' then
               wr_drop_o <= '1';
               wr_ptr    <= cmt_ptr;
            else
               wr_ptr     <= wr_ptr - 4;
               cmt_ptr    <= wr_ptr - 4;
               cmt_toggle <= not cmt_toggle;
            end if;
            overflow <= '0';
         end if;

         if wr_bad_i = '1' then
            wr_ptr   <= cmt_ptr;
            overflow <= '0';
         end if;

         if wr_rst_i = '1' then
            wr_ptr     <= (others => '0');
            cmt_ptr    <= (others => '0');
            cmt_toggle <= '0';
            overflow   <= '0';
            wr_drop_o  <= '0';
            rd_gray_s0 <= (others => '0');
            rd_gray_s1 <= (others => '0');
         end if;
      end if;
   end process p_write;


   i_eth_ram : entity work.eth_ram
      generic map (
         G_ADDR_BITS => G_ADDR_BITS
      )
      port map (
         wr_clk_i  => wr_clk_i,
         wr_we_i   => ram_we,
         wr_addr_i => ram_waddr(G_ADDR_BITS - 1 downto 0),
         wr_data_i => ram_wdata,
         rd_clk_i  => rd_clk_i,
         rd_addr_i => rd_ptr(G_ADDR_BITS - 1 downto 0),
         rd_data_o => ram_rdata
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

end architecture synthesis;
