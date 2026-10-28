-- Tests the FIFO of received Ethernet frames (src/eth/eth_rx_fifo.vhd).
--
-- THEORY OF OPERATION
-- The FIFO has 256 bytes here, and its two clocks are 50 MHz and 90 MHz.
-- p_write sends C_FRAMES frames as rmii_rx.vhd and rx_fcs.vhd send them: a
-- byte every fourth cycle, then the four bytes of a check sequence, and
-- wr_ok_i three cycles after the last byte, or wr_bad_i for every seventh
-- frame. Frame k has 60 to 149 bytes before its check sequence, and its
-- byte i is k * 37 + i * 11, modulo 256. p_drop counts wr_drop_o.
-- p_read takes the bytes, with rd_ready_i from an LFSR, and holds
-- rd_ready_i at '0' over C_STALL, so that frames find the FIFO full. It
-- checks that each frame it gets is a good one, later than the last, with
-- its bytes and without its check sequence, and the last byte marked; and,
-- at the end, that every good frame came, or was counted by wr_drop_o.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.env.all;

entity tb_eth_rx_fifo is
end entity tb_eth_rx_fifo;

architecture simulation of tb_eth_rx_fifo is

   constant C_FRAMES : natural := 60;

   signal wr_clk   : std_logic;
   signal rd_clk   : std_logic;
   signal rst      : std_logic := '1';
   signal wr_data  : std_logic_vector(7 downto 0) := (others => '0');
   signal wr_valid : std_logic := '0';
   signal wr_ok    : std_logic := '0';
   signal wr_bad   : std_logic := '0';
   signal wr_drop  : std_logic;
   signal rd_data  : std_logic_vector(7 downto 0);
   signal rd_last  : std_logic;
   signal rd_valid : std_logic;
   signal rd_ready : std_logic := '0';

   signal sent  : boolean := false;
   signal drops : natural := 0;
   -- The reader stalls while this is true.
   signal stall : boolean := false;

   function byte_of (k : natural; i : natural) return std_logic_vector is
   begin
      return to_stdlogicvector((k * 37 + i * 11) mod 256, 8);
   end function byte_of;

   function len_of (k : natural) return natural is
   begin
      return 60 + (k * 29) mod 90;
   end function len_of;

   function good (k : natural) return boolean is
   begin
      return k mod 7 /= 3;
   end function good;

begin

   p_wr_clk : process
   begin
      wr_clk <= '1', '0' after 10 ns;
      wait for 20 ns;
   end process p_wr_clk;

   p_rd_clk : process
   begin
      rd_clk <= '1', '0' after 5.555 ns;
      wait for 11.111 ns;
   end process p_rd_clk;


   i_eth_rx_fifo : entity work.eth_rx_fifo
      generic map (
         G_ADDR_BITS => 8
      )
      port map (
         wr_clk_i   => wr_clk,
         wr_rst_i   => rst,
         wr_data_i  => wr_data,
         wr_valid_i => wr_valid,
         wr_ok_i    => wr_ok,
         wr_bad_i   => wr_bad,
         wr_drop_o  => wr_drop,
         rd_clk_i   => rd_clk,
         rd_rst_i   => rst,
         rd_data_o  => rd_data,
         rd_last_o  => rd_last,
         rd_valid_o => rd_valid,
         rd_ready_i => rd_ready
      ); -- i_eth_rx_fifo


   p_write : process
      procedure byte (d : std_logic_vector(7 downto 0)) is
      begin
         wr_data  <= d;
         wr_valid <= '1';
         wait until rising_edge(wr_clk);
         wr_valid <= '0';
         for c in 1 to 3 loop
            wait until rising_edge(wr_clk);
         end loop;
      end procedure byte;

   begin
      for c in 1 to 10 loop
         wait until rising_edge(wr_clk);
      end loop;
      rst <= '0';

      for k in 0 to C_FRAMES - 1 loop
         -- The gap between frames, and the reader's stall over frames 20-29
         for c in 1 to 10 + (k mod 5) * 7 loop
            wait until rising_edge(wr_clk);
         end loop;
         stall <= k >= 20 and k < 30;

         for i in 0 to len_of(k) - 1 loop
            byte(byte_of(k, i));
         end loop;
         for i in 0 to 3 loop
            byte(X"EE");
         end loop;

         if good(k) then
            wr_ok <= '1';
         else
            wr_bad <= '1';
         end if;
         wait until rising_edge(wr_clk);
         wr_ok  <= '0';
         wr_bad <= '0';
      end loop;

      stall <= false;
      for c in 1 to 2000 loop
         wait until rising_edge(wr_clk);
      end loop;
      sent <= true;
      wait;
   end process p_write;

   p_drop : process (wr_clk)
   begin
      if rising_edge(wr_clk) then
         if wr_drop = '1' then
            drops <= drops + 1;
         end if;
      end if;
   end process p_drop;


   p_read : process
      variable lfsr_v : std_logic_vector(15 downto 0) := X"ACE1";
      -- The frame being received, the next byte of it, and the next one
      -- that may come
      variable k_v    : natural := 0;
      variable i_v    : natural := 0;
      variable next_v : natural := 0;
      variable in_v   : boolean := false;
      variable got_v  : natural := 0;
      variable skip_v : natural := 0;
   begin
      wait until rising_edge(rd_clk);

      if rd_valid = '1' and rd_ready = '1' then
         if not in_v then
            -- The first byte: the next good frame that has it, and the good
            -- frames before that were dropped.
            k_v := next_v;
            while k_v < C_FRAMES and not (good(k_v) and byte_of(k_v, 0) = rd_data) loop
               if good(k_v) then
                  skip_v := skip_v + 1;
               end if;
               k_v := k_v + 1;
            end loop;
            assert k_v < C_FRAMES
               report "tb_eth_rx_fifo: a frame that was not sent, after frame " &
                      integer'image(next_v)
               severity failure;
            in_v := true;
            i_v  := 0;
         end if;

         assert rd_data = byte_of(k_v, i_v)
            report "tb_eth_rx_fifo: wrong byte " & integer'image(i_v) & " of frame " &
                   integer'image(k_v)
            severity failure;
         assert (rd_last = '1') = (i_v = len_of(k_v) - 1)
            report "tb_eth_rx_fifo: wrong last of byte " & integer'image(i_v) & " of frame " &
                   integer'image(k_v)
            severity failure;
         i_v := i_v + 1;

         if rd_last = '1' then
            in_v   := false;
            got_v  := got_v + 1;
            next_v := k_v + 1;
         end if;
      end if;

      lfsr_v   := lfsr_v(14 downto 0) & (lfsr_v(15) xor lfsr_v(13) xor lfsr_v(12) xor lfsr_v(10));
      rd_ready <= '1' when lfsr_v(0) = '1' and not stall else
                  '0';

      if sent then
         -- The good frames after the last one received were dropped too.
         for k in next_v to C_FRAMES - 1 loop
            if good(k) then
               skip_v := skip_v + 1;
            end if;
         end loop;
         assert not in_v
            report "tb_eth_rx_fifo: frame " & integer'image(k_v) & " did not end"
            severity failure;
         assert skip_v = drops
            report "tb_eth_rx_fifo: " & integer'image(skip_v) & " frames are missing, and " &
                   integer'image(drops) & " were dropped"
            severity failure;
         assert drops > 0 and got_v > 30
            report "tb_eth_rx_fifo: " & integer'image(got_v) & " frames came, and " &
                   integer'image(drops) & " were dropped"
            severity failure;
         report "tb_eth_rx_fifo: PASS, " & integer'image(got_v) & " frames, " &
                integer'image(drops) & " dropped";
         finish;
      end if;
   end process p_read;

end architecture simulation;
