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

entity eth_tx_fifo is
   generic (
      G_ADDR_BITS : natural := 11
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
         G_ADDR_BITS => G_ADDR_BITS
      )
      port map (
         wr_clk_i  => wr_clk_i,
         wr_we_i   => ram_we,
         wr_addr_i => wr_ptr(G_ADDR_BITS - 1 downto 0),
         wr_data_i => wr_last_i & wr_data_i,
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
