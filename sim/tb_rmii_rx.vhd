-- Tests the RMII receiver (src/eth/rmii_rx.vhd) with a model of the PHY.
--
-- THEORY OF OPERATION
-- p_phy sends the frames of C_FRAMES, each after an idle gap: CRS_DV rises
-- with RXD at "00" for a few cycles, then come the preamble, the start of
-- frame delimiter, and the bytes, LSB first, a di-bit a cycle. Frame k's
-- byte i is k * 37 + i * 11, modulo 256. A frame with a toggle drops the
-- carrier that many nibbles before its end, so CRS_DV toggles over them, as
-- a PHY's does when it still holds the frame's di-bits. A frame with an
-- odd nibble ends half a byte late, and a false carrier sends "10" instead
-- of a frame. A frame with rxer sets RX_ER for one di-bit in its middle.
-- p_check takes the bytes and the ends of the frames, and checks them
-- against what p_phy sent: every frame but the false carrier ends once,
-- with err_o only for the odd nibble and RX_ER.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.env.all;

entity tb_rmii_rx is
end entity tb_rmii_rx;

architecture simulation of tb_rmii_rx is

   type t_frame is record
      len    : natural; -- bytes
      toggle : natural; -- nibbles at the end with the carrier gone
      odd    : boolean; -- a nibble more at the end
      falsec : boolean; -- a false carrier, and no frame
      rxer   : boolean; -- RX_ER in the middle
   end record t_frame;

   type t_frames is array (natural range <>) of t_frame;

   constant C_FRAMES : t_frames := (
      (64,  0, false, false, false),
      (60,  6, false, false, false),
      (1,   0, false, false, false),
      (0,   0, true,  true,  false),
      (100, 1, false, false, false),
      (20,  0, true,  false, false),
      (64,  0, false, false, true),
      (64,  2, false, false, false)
   );

   signal clk    : std_logic;
   signal rst    : std_logic := '1';
   signal rxd    : std_logic_vector(1 downto 0) := "00";
   signal crs_dv : std_logic := '0';
   signal rx_er  : std_logic := '0';

   signal data  : std_logic_vector(7 downto 0);
   signal valid : std_logic;
   signal eof   : std_logic;
   signal err   : std_logic;

   signal sent : boolean := false;

   function byte_of (k : natural; i : natural) return std_logic_vector is
   begin
      return to_stdlogicvector((k * 37 + i * 11) mod 256, 8);
   end function byte_of;

begin

   p_clk : process
   begin
      clk <= '1', '0' after 10 ns;
      wait for 20 ns;
   end process p_clk;


   i_rmii_rx : entity work.rmii_rx
      port map (
         clk_i    => clk,
         rst_i    => rst,
         rxd_i    => rxd,
         crs_dv_i => crs_dv,
         rx_er_i  => rx_er,
         data_o   => data,
         valid_o  => valid,
         eof_o    => eof,
         err_o    => err
      ); -- i_rmii_rx


   p_phy : process
      -- The di-bits after the preamble, and how many there are
      variable dibits_v : std_logic_vector(2 * 4 * 101 + 1 downto 0);
      variable n_v      : natural;
      -- The first di-bit with the carrier gone
      variable gone_v : natural;

      procedure send (d : std_logic_vector(1 downto 0); dv : std_logic) is
      begin
         rxd    <= d;
         crs_dv <= dv;
         wait until rising_edge(clk);
      end procedure send;

   begin
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      rst <= '0';

      for k in C_FRAMES'range loop
         for c in 1 to 20 loop
            send("00", '0');
         end loop;
         for c in 1 to 5 loop
            send("00", '1');
         end loop;

         if C_FRAMES(k).falsec then
            for c in 1 to 30 loop
               send("10", '1');
            end loop;
         else
            -- The preamble and the start of frame delimiter
            for c in 1 to 31 loop
               send("01", '1');
            end loop;
            send("11", '1');

            n_v := 0;
            for i in 0 to C_FRAMES(k).len - 1 loop
               for d in 0 to 3 loop
                  dibits_v(2 * n_v + 1 downto 2 * n_v) := byte_of(k, i)(2 * d + 1 downto 2 * d);
                  n_v                                  := n_v + 1;
               end loop;
            end loop;
            if C_FRAMES(k).odd then
               dibits_v(2 * n_v + 3 downto 2 * n_v) := "1001";
               n_v                                  := n_v + 2;
            end if;

            gone_v := n_v - 2 * C_FRAMES(k).toggle;
            for j in 0 to n_v - 1 loop
               rx_er <= '1' when C_FRAMES(k).rxer and j = n_v / 2 else '0';
               if j < gone_v or j mod 2 = 1 then
                  send(dibits_v(2 * j + 1 downto 2 * j), '1');
               else
                  send(dibits_v(2 * j + 1 downto 2 * j), '0');
               end if;
            end loop;
            rx_er <= '0';
         end if;
      end loop;

      for c in 1 to 20 loop
         send("00", '0');
      end loop;
      sent <= true;
      wait;
   end process p_phy;


   p_check : process
      variable k_v : natural := 0;
      variable i_v : natural := 0;
   begin
      wait until rising_edge(clk);

      -- The false carriers give nothing.
      while k_v <= C_FRAMES'high and C_FRAMES(k_v).falsec loop
         k_v := k_v + 1;
      end loop;

      if valid = '1' then
         assert k_v <= C_FRAMES'high and i_v < C_FRAMES(k_v).len
            report "tb_rmii_rx: a byte too many in frame " & integer'image(k_v)
            severity failure;
         assert data = byte_of(k_v, i_v)
            report "tb_rmii_rx: wrong byte " & integer'image(i_v) & " in frame " & integer'image(k_v)
            severity failure;
         i_v := i_v + 1;
      end if;

      if eof = '1' then
         assert k_v <= C_FRAMES'high
            report "tb_rmii_rx: an end with no frame"
            severity failure;
         assert i_v = C_FRAMES(k_v).len
            report "tb_rmii_rx: frame " & integer'image(k_v) & " has " & integer'image(i_v) & " bytes"
            severity failure;
         assert (err = '1') = (C_FRAMES(k_v).odd or C_FRAMES(k_v).rxer)
            report "tb_rmii_rx: wrong error of frame " & integer'image(k_v)
            severity failure;
         k_v := k_v + 1;
         i_v := 0;
      end if;

      if sent then
         assert k_v = C_FRAMES'length and i_v = 0
            report "tb_rmii_rx: only " & integer'image(k_v) & " frames ended"
            severity failure;
         report "tb_rmii_rx: PASS";
         finish;
      end if;
   end process p_check;

end architecture simulation;
