-- Tests the FIFO of Ethernet frames to send (src/eth/eth_tx_fifo.vhd).
--
-- THEORY OF OPERATION
-- The FIFO has 256 bytes here, and its two clocks are 100 MHz on the write
-- side and 50 MHz on the read side, as on the MEGA65. p_write writes
-- C_FRAMES frames, with wr_valid_i from an LFSR, and frame k has 14 to 213
-- bytes, whose byte i is k * 37 + i * 11, modulo 256; written counts the
-- frames written whole. p_read takes the bytes, with rd_ready_i from an
-- LFSR for the first half of the frames and at '1' for the rest, as
-- rmii_tx.vhd takes them. It checks that the frames come in order, whole,
-- with their bytes and the last one marked; that a frame's first byte
-- comes only after the frame was written whole; and, with rd_ready_i at
-- '1', that each byte of a frame after its first comes two cycles after
-- the one before.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.env.all;

entity tb_eth_tx_fifo is
end entity tb_eth_tx_fifo;

architecture simulation of tb_eth_tx_fifo is

   constant C_FRAMES : natural := 60;

   signal wr_clk   : std_logic;
   signal rd_clk   : std_logic;
   signal rst      : std_logic                    := '1';
   signal wr_data  : std_logic_vector(7 downto 0) := (others => '0');
   signal wr_last  : std_logic                    := '0';
   signal wr_valid : std_logic                    := '0';
   signal wr_ready : std_logic;
   signal rd_data  : std_logic_vector(7 downto 0);
   signal rd_last  : std_logic;
   signal rd_valid : std_logic;
   signal rd_ready : std_logic                    := '0';

   signal written : natural := 0;

   function byte_of (k : natural; i : natural) return std_logic_vector is
   begin
      return to_stdlogicvector((k * 37 + i * 11) mod 256, 8);
   end function byte_of;

   function len_of (k : natural) return natural is
   begin
      return 14 + (k * 29) mod 200;
   end function len_of;

begin

   p_wr_clk : process
   begin
      wr_clk <= '1', '0' after 5 ns;
      wait for 10 ns;
   end process p_wr_clk;

   p_rd_clk : process
   begin
      rd_clk <= '1', '0' after 10 ns;
      wait for 20 ns;
   end process p_rd_clk;


   i_eth_tx_fifo : entity work.eth_tx_fifo
      generic map (
         G_ADDR_BITS => 8
      )
      port map (
         wr_clk_i   => wr_clk,
         wr_rst_i   => rst,
         wr_data_i  => wr_data,
         wr_last_i  => wr_last,
         wr_valid_i => wr_valid,
         wr_ready_o => wr_ready,
         rd_clk_i   => rd_clk,
         rd_rst_i   => rst,
         rd_data_o  => rd_data,
         rd_last_o  => rd_last,
         rd_valid_o => rd_valid,
         rd_ready_i => rd_ready
      ); -- i_eth_tx_fifo


   p_write : process
      variable lfsr_v : std_logic_vector(15 downto 0) := X"1D0F";
      variable i_v    : natural;
   begin
      for c in 1 to 10 loop
         wait until rising_edge(rd_clk);
      end loop;
      rst <= '0';

      for k in 0 to C_FRAMES - 1 loop
         i_v := 0;
         while i_v < len_of(k) loop
            lfsr_v   := lfsr_v(14 downto 0) &
                        (lfsr_v(15) xor lfsr_v(13) xor lfsr_v(12) xor lfsr_v(10));
            wr_valid <= lfsr_v(0) or lfsr_v(1);
            wr_data  <= byte_of(k, i_v);
            wr_last  <= '1' when i_v = len_of(k) - 1 else '0';
            wait until rising_edge(wr_clk);
            if wr_valid = '1' and wr_ready = '1' then
               i_v := i_v + 1;
            end if;
         end loop;
         wr_valid <= '0';
         written  <= k + 1;
      end loop;

      wait;
   end process p_write;


   p_read : process
      variable lfsr_v : std_logic_vector(15 downto 0) := X"ACE1";
      variable k_v    : natural                       := 0;
      variable i_v    : natural                       := 0;
      -- Cycles since the last byte taken
      variable since_v : natural                       := 0;
   begin
      wait until rising_edge(rd_clk);
      since_v := since_v + 1;

      if rd_valid = '1' and rd_ready = '1' then
         if i_v = 0 then
            assert written > k_v
               report "tb_eth_tx_fifo: frame " & integer'image(k_v) & " comes before it is whole"
               severity failure;
         elsif k_v >= C_FRAMES / 2 then
            assert since_v = 2
               report "tb_eth_tx_fifo: byte " & integer'image(i_v) & " of frame " &
                      integer'image(k_v) &
                      " comes " & integer'image(since_v) & " cycles after the one before"
               severity failure;
         end if;

         assert rd_data = byte_of(k_v, i_v)
            report "tb_eth_tx_fifo: wrong byte " & integer'image(i_v) & " of frame " &
                   integer'image(k_v)
            severity failure;
         assert (rd_last = '1') = (i_v = len_of(k_v) - 1)
            report "tb_eth_tx_fifo: wrong last of byte " & integer'image(i_v) & " of frame " &
                   integer'image(k_v)
            severity failure;
         since_v := 0;
         i_v     := i_v + 1;

         if rd_last = '1' then
            i_v := 0;
            k_v := k_v + 1;
            if k_v = C_FRAMES then
               report "tb_eth_tx_fifo: PASS, " & integer'image(C_FRAMES) & " frames";
               finish;
            end if;
         end if;
      end if;

      lfsr_v := lfsr_v(14 downto 0) & (lfsr_v(15) xor lfsr_v(13) xor lfsr_v(12) xor lfsr_v(10));
      if k_v < C_FRAMES / 2 then
         rd_ready <= lfsr_v(0);
      else
         rd_ready <= '1';
      end if;
   end process p_read;

   p_timeout : process
   begin
      wait for 2 ms;
      report "tb_eth_tx_fifo: timeout"
         severity failure;
      wait;
   end process p_timeout;

end architecture simulation;
