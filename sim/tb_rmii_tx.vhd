-- Tests the RMII transmitter (src/eth/rmii_tx.vhd) with a model of the PHY.
--
-- THEORY OF OPERATION
-- p_send gives the frames of C_LENS to rmii_tx as eth_tx_fifo.vhd does: a
-- frame's first byte on valid_i at once, and each next byte two cycles
-- after the one before is taken. Frame k's byte i is k * 37 + i * 11,
-- modulo 256. The first frames follow each other at once, and the last
-- comes after a pause. p_phy takes TXD while TX_EN is '1', as the PHY
-- does, and checks each frame: TX_EN rises at a byte, the preamble is
-- seven bytes of 0x55 and the start frame delimiter 0xD5, then come the
-- frame's bytes, zeros up to 60 bytes, and the frame check sequence, which
-- p_phy checks with its own CRC; and between two frames TX_EN is '0' for
-- exactly 48 cycles, 12 bytes, when the second was waiting.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.env.all;

entity tb_rmii_tx is
end entity tb_rmii_tx;

architecture simulation of tb_rmii_tx is

   type     t_lens is array (natural range <>) of natural;
   constant C_LENS : t_lens := (1, 14, 59, 60, 61, 100, 1514, 42);

   signal clk   : std_logic;
   signal rst   : std_logic                    := '1';
   signal data  : std_logic_vector(7 downto 0) := (others => '0');
   signal last  : std_logic                    := '0';
   signal valid : std_logic                    := '0';
   signal ready : std_logic;
   signal txd   : std_logic_vector(1 downto 0);
   signal tx_en : std_logic;

   function byte_of (k : natural; i : natural) return std_logic_vector is
   begin
      return to_stdlogicvector((k * 37 + i * 11) mod 256, 8);
   end function byte_of;

   -- The CRC-32 of IEEE 802.3, a bit at a time, LSB first
   function crc_byte (
      c : std_logic_vector(31 downto 0);
      d : std_logic_vector(7 downto 0)
   ) return std_logic_vector is
      variable c_v : std_logic_vector(31 downto 0);
   begin
      c_v := c;

      for i in 0 to 7 loop
         if (c_v(0) xor d(i)) = '1' then
            c_v := ('0' & c_v(31 downto 1)) xor X"EDB88320";
         else
            c_v := '0' & c_v(31 downto 1);
         end if;
      end loop;

      return c_v;
   end function crc_byte;

begin

   p_clk : process
   begin
      clk <= '1', '0' after 10 ns;
      wait for 20 ns;
   end process p_clk;


   i_rmii_tx : entity work.rmii_tx
      port map (
         clk_i   => clk,
         rst_i   => rst,
         data_i  => data,
         last_i  => last,
         valid_i => valid,
         ready_o => ready,
         txd_o   => txd,
         tx_en_o => tx_en
      ); -- i_rmii_tx


   p_send : process
   begin
      for c in 1 to 5 loop
         wait until rising_edge(clk);
      end loop;
      rst <= '0';

      for k in C_LENS'range loop
         if k = C_LENS'high then
            for c in 1 to 300 loop
               wait until rising_edge(clk);
            end loop;
         end if;

         for i in 0 to C_LENS(k) - 1 loop
            data  <= byte_of(k, i);
            last  <= '1' when i = C_LENS(k) - 1 else '0';
            valid <= '1';
            wait until rising_edge(clk) and ready = '1';
            valid <= '0';
            data  <= (others => 'X');
            last  <= 'X';
            wait until rising_edge(clk);
            wait until rising_edge(clk);
         end loop;
      end loop;

      wait;
   end process p_send;


   p_phy : process
      variable crc_v  : std_logic_vector(31 downto 0);
      variable byte_v : std_logic_vector(7 downto 0);
      variable n_v    : natural;
      variable gap_v  : natural;
      variable want_v : std_logic_vector(7 downto 0);
      variable len_v  : natural;
   begin
      -- The CRC of "123456789" is 0xCBF43926.
      crc_v := X"FFFFFFFF";
      for i in 1 to 9 loop
         crc_v := crc_byte(crc_v, to_stdlogicvector(48 + i, 8));
      end loop;
      assert not crc_v = X"CBF43926"
         report "tb_rmii_tx: the testbench's CRC is wrong"
         severity failure;

      wait until rst = '0';

      for k in C_LENS'range loop
         -- The gap before the frame
         gap_v := 0;
         while tx_en /= '1' loop
            wait until rising_edge(clk);
            gap_v := gap_v + 1;
         end loop;
         if k > 0 and k < C_LENS'high then
            assert gap_v = 48
               report "tb_rmii_tx: a gap of " & integer'image(gap_v) & " cycles before frame " &
                      integer'image(k)
               severity failure;
         end if;

         -- The frame, a byte at a time, until TX_EN falls
         n_v   := 0;
         crc_v := X"FFFFFFFF";
         len_v := C_LENS(k);
         if len_v < 60 then
            len_v := 60;
         end if;
         loop
            for d in 0 to 3 loop
               assert tx_en = '1'
                  report "tb_rmii_tx: TX_EN falls inside byte " & integer'image(n_v) &
                         " of frame " &
                         integer'image(k)
                  severity failure;
               byte_v(2 * d + 1 downto 2 * d) := txd;
               wait until rising_edge(clk);
            end loop;

            if n_v < 7 then
               want_v := X"55";
            elsif n_v = 7 then
               want_v := X"D5";
            elsif n_v - 8 < C_LENS(k) then
               want_v := byte_of(k, n_v - 8);
            elsif n_v - 8 < len_v then
               want_v := X"00";
            else
               want_v := byte_v;
            end if;
            assert byte_v = want_v
               report "tb_rmii_tx: byte " & integer'image(n_v) & " of frame " & integer'image(k) &
                      " is wrong"
               severity failure;
            if n_v >= 8 then
               crc_v := crc_byte(crc_v, byte_v);
            end if;
            n_v := n_v + 1;

            exit when tx_en = '0';
         end loop;

         assert n_v = 8 + len_v + 4
            report "tb_rmii_tx: frame " & integer'image(k) & " has " & integer'image(n_v) &
                   " bytes on the wire"
            severity failure;
         assert crc_v = X"DEBB20E3"
            report "tb_rmii_tx: the frame check sequence of frame " & integer'image(k) & " is wrong"
            severity failure;
      end loop;

      report "tb_rmii_tx: PASS, " & integer'image(C_LENS'length) & " frames";
      finish;
   end process p_phy;

end architecture simulation;
