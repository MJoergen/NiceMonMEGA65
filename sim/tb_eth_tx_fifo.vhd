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
--
-- A second FIFO, of 64 bytes, is the exact test of the capacity. p_cap
-- writes to it with wr_valid_i held, and counts the bytes that wr_ready_o
-- takes, and p_cap_rd reads it only when p_cap says which frame to expect.
-- The FIFO takes exactly as many bytes as it has room for, and not one
-- more. The room is counted from the read pointer, which has moved by one
-- when the reader holds its first byte. p_cap checks:
-- 1) after a reset, a frame that never ends takes 64 bytes and no more,
--    and nothing of it reaches the reader;
-- 2) a frame of 64 bytes, the whole FIFO, goes in and comes out whole,
--    12 times in a row, with frames of other lengths between, so that the
--    pointers wrap at every place, and every read gives all of its space
--    back;
-- 3) with a frame of 20 bytes waiting, a frame of 45 bytes goes in, the
--    room that is left, and a byte more does not; then both come out whole
--    and in order.

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

   -- The FIFO of 64 bytes, and what p_cap says to p_cap_rd: the frame to
   -- expect, and a count that says it is new
   signal cap_rst    : std_logic                    := '1';
   signal cap_data   : std_logic_vector(7 downto 0) := (others => '0');
   signal cap_last   : std_logic                    := '0';
   signal cap_valid  : std_logic                    := '0';
   signal cap_wready : std_logic;
   signal cap_rdata  : std_logic_vector(7 downto 0);
   signal cap_rlast  : std_logic;
   signal cap_rvalid : std_logic;
   signal cap_rready : std_logic                    := '0';
   signal cap_k      : natural                      := 0;
   signal cap_len    : natural                      := 0;
   signal cap_arm    : natural                      := 0;
   signal cap_frames : natural                      := 0;
   signal cap_done   : boolean                      := false;

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


   i_eth_tx_fifo_cap : entity work.eth_tx_fifo
      generic map (
         G_ADDR_BITS => 6
      )
      port map (
         wr_clk_i   => wr_clk,
         wr_rst_i   => cap_rst,
         wr_data_i  => cap_data,
         wr_last_i  => cap_last,
         wr_valid_i => cap_valid,
         wr_ready_o => cap_wready,
         rd_clk_i   => rd_clk,
         rd_rst_i   => cap_rst,
         rd_data_o  => cap_rdata,
         rd_last_o  => cap_rlast,
         rd_valid_o => cap_rvalid,
         rd_ready_i => cap_rready
      ); -- i_eth_tx_fifo_cap


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
               if not cap_done then
                  wait until cap_done;
               end if;
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

   p_cap : process
      variable frames_v : natural := 0;
      variable acc_v    : natural;
      variable len_v    : natural;

      procedure tick (n : natural) is
      begin
         for c in 1 to n loop
            wait until rising_edge(wr_clk);
         end loop;
      end procedure tick;

      procedure reset is
      begin
         cap_rst <= '1';
         tick(20);
         cap_rst <= '0';
         tick(10);
      end procedure reset;

      -- Offer a frame of len bytes, the last one marked or not, for window
      -- cycles, and count the bytes that the FIFO takes.
      procedure put (id : natural; len : natural; last : boolean; window : natural;
                     variable acc : out natural) is
         variable i_v : natural := 0;
      begin
         for c in 1 to window loop
            if i_v < len then
               cap_data  <= byte_of(id, i_v);
               cap_last  <= '1' when last and i_v = len - 1 else '0';
               cap_valid <= '1';
            else
               cap_valid <= '0';
            end if;
            wait until rising_edge(wr_clk);
            if cap_valid = '1' and cap_wready = '1' then
               i_v := i_v + 1;
            end if;
         end loop;
         cap_valid <= '0';
         cap_last  <= '0';
         acc       := i_v;
      end procedure put;

      -- A frame that must go in whole
      procedure fits (id : natural; len : natural) is
         variable n_v : natural;
      begin
         put(id, len, true, 4 * len + 100, n_v);
         assert n_v = len
            report "tb_eth_tx_fifo: " & integer'image(n_v) & " bytes of a frame of " &
                   integer'image(len) & " went in, and it fits"
            severity failure;
      end procedure fits;

      -- The reader takes the next frame, which must come whole.
      procedure take (id : natural; len : natural) is
      begin
         frames_v := frames_v + 1;
         cap_k    <= id;
         cap_len  <= len;
         cap_arm  <= cap_arm + 1;
         for c in 1 to 4000 loop
            wait until rising_edge(rd_clk);
            exit when cap_frames = frames_v;
         end loop;
         assert cap_frames = frames_v
            report "tb_eth_tx_fifo: frame " & integer'image(id) & " did not come"
            severity failure;
         -- The read pointer crosses to the write side.
         tick(30);
      end procedure take;

   begin
      wait until rst = '0';
      reset;

      -- 1) A frame that never ends takes the room and no more.
      put(1, 100, false, 300, acc_v);
      assert acc_v = 64
         report "tb_eth_tx_fifo: " & integer'image(acc_v) & " bytes went in, not 64"
         severity failure;
      assert cap_wready = '0' and cap_rvalid = '0'
         report "tb_eth_tx_fifo: the FIFO is not full, or a frame that is not whole came out"
         severity failure;

      -- 2) The whole FIFO, again and again
      reset;
      for n in 0 to 11 loop
         if n mod 4 = 3 then
            len_v := 14 + 3 * n;
         else
            len_v := 64;
         end if;
         fits(10 + n, len_v);
         take(10 + n, len_v);
      end loop;

      -- 3) The room that a waiting frame leaves
      reset;
      fits(100, 20);
      tick(60);
      fits(101, 45);
      put(102, 1, false, 60, acc_v);
      assert acc_v = 0
         report "tb_eth_tx_fifo: a byte went in, and the FIFO is full"
         severity failure;
      take(100, 20);
      take(101, 45);
      fits(103, 64);
      take(103, 64);

      report "tb_eth_tx_fifo: capacity PASS";
      cap_done <= true;
      wait;
   end process p_cap;


   p_cap_rd : process (rd_clk)
      variable seen_v   : natural := 0;
      variable i_v      : natural := 0;
      variable len_v    : natural := 0;
      variable active_v : boolean := false;
   begin
      if rising_edge(rd_clk) then
         if cap_arm /= seen_v then
            seen_v   := cap_arm;
            i_v      := 0;
            len_v    := cap_len;
            active_v := true;
         end if;

         if cap_rvalid = '1' and cap_rready = '1' then
            assert cap_rdata = byte_of(cap_k, i_v)
               report "tb_eth_tx_fifo: wrong byte " & integer'image(i_v) & " of frame " &
                      integer'image(cap_k) & " in the small FIFO"
               severity failure;
            assert (cap_rlast = '1') = (i_v = len_v - 1)
               report "tb_eth_tx_fifo: wrong last of byte " & integer'image(i_v) & " of frame " &
                      integer'image(cap_k) & " in the small FIFO"
               severity failure;
            i_v := i_v + 1;
            if i_v = len_v then
               active_v   := false;
               cap_frames <= cap_frames + 1;
            end if;
         end if;

         if active_v then
            cap_rready <= '1';
         else
            cap_rready <= '0';
         end if;
      end if;
   end process p_cap_rd;


   p_timeout : process
   begin
      wait for 2 ms;
      report "tb_eth_tx_fifo: timeout"
         severity failure;
      wait;
   end process p_timeout;

end architecture simulation;
