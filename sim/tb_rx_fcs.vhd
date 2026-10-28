-- Tests the check of the frame check sequence (src/eth/rx_fcs.vhd).
--
-- THEORY OF OPERATION
-- p_main sends frames as rmii_rx.vhd sends them, a byte every fourth
-- cycle and the end four cycles after the last, and checks that each gives
-- ok_o or bad_o as it should, once. C_ARP is an ARP request with its frame
-- check sequence from Python's zlib.crc32, so that the test does not rest
-- on its own CRC alone. The other frames get theirs from fcs_of, which is
-- checked first against the CRC-32 of "123456789", 0xCBF43926. The frames:
-- C_ARP, good; C_ARP with a bit of its data and then of its check sequence
-- flipped, bad; C_ARP with err_i, bad; frames of 64, 100, and 1518 bytes,
-- good; frames of 3 bytes and of 63 with a right check sequence, bad, as
-- too short; and C_ARP again, good, after the bad one.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.env.all;

entity tb_rx_fcs is
end entity tb_rx_fcs;

architecture simulation of tb_rx_fcs is

   type t_bytes is array (natural range <>) of std_logic_vector(7 downto 0);

   -- Who has 192.168.1.1? Tell 192.168.1.2, from 02:00:00:00:00:01
   constant C_ARP : t_bytes(0 to 63) := (
      X"FF", X"FF", X"FF", X"FF", X"FF", X"FF", X"02", X"00",
      X"00", X"00", X"00", X"01", X"08", X"06", X"00", X"01",
      X"08", X"00", X"06", X"04", X"00", X"01", X"02", X"00",
      X"00", X"00", X"00", X"01", X"C0", X"A8", X"01", X"02",
      X"00", X"00", X"00", X"00", X"00", X"00", X"C0", X"A8",
      X"01", X"01", X"00", X"00", X"00", X"00", X"00", X"00",
      X"00", X"00", X"00", X"00", X"00", X"00", X"00", X"00",
      X"00", X"00", X"00", X"00", X"26", X"B8", X"D1", X"1F"
   );

   signal clk   : std_logic;
   signal rst   : std_logic := '1';
   signal data  : std_logic_vector(7 downto 0) := (others => '0');
   signal valid : std_logic := '0';
   signal eof   : std_logic := '0';
   signal err   : std_logic := '0';
   signal ok    : std_logic;
   signal bad   : std_logic;

   -- The CRC-32 of IEEE 802.3, complemented, as it is sent
   function fcs_of (b : t_bytes) return std_logic_vector is
      variable c_v : std_logic_vector(31 downto 0) := (others => '1');
   begin
      for n in b'range loop
         for i in 0 to 7 loop
            if (c_v(0) xor b(n)(i)) = '1' then
               c_v := ('0' & c_v(31 downto 1)) xor X"EDB88320";
            else
               c_v := '0' & c_v(31 downto 1);
            end if;
         end loop;
      end loop;
      return not c_v;
   end function fcs_of;

   -- Bytes of k * 37 + i * 11, and their check sequence, LSB first
   function frame_of (k : natural; len : natural) return t_bytes is
      variable f_v : t_bytes(0 to len + 3);
      variable c_v : std_logic_vector(31 downto 0);
   begin
      for i in 0 to len - 1 loop
         f_v(i) := to_stdlogicvector((k * 37 + i * 11) mod 256, 8);
      end loop;
      c_v := fcs_of(f_v(0 to len - 1));
      for i in 0 to 3 loop
         f_v(len + i) := c_v(8 * i + 7 downto 8 * i);
      end loop;
      return f_v;
   end function frame_of;

begin

   p_clk : process
   begin
      clk <= '1', '0' after 10 ns;
      wait for 20 ns;
   end process p_clk;


   i_rx_fcs : entity work.rx_fcs
      port map (
         clk_i   => clk,
         rst_i   => rst,
         data_i  => data,
         valid_i => valid,
         eof_i   => eof,
         err_i   => err,
         ok_o    => ok,
         bad_o   => bad
      ); -- i_rx_fcs


   p_main : process
      constant C_DIGITS : string := "123456789";
      variable d_v      : t_bytes(0 to 8);
      variable f_v      : t_bytes(0 to 63);

      procedure send (b : t_bytes; e : std_logic; good : boolean; name : string) is
         variable ok_v  : natural := 0;
         variable bad_v : natural := 0;
      begin
         for n in b'range loop
            data  <= b(n);
            valid <= '1';
            wait until rising_edge(clk);
            valid <= '0';
            for c in 1 to 3 loop
               wait until rising_edge(clk);
            end loop;
         end loop;
         eof <= '1';
         err <= e;
         wait until rising_edge(clk);
         eof <= '0';
         err <= '0';
         for c in 1 to 10 loop
            wait until rising_edge(clk);
            if ok = '1' then
               ok_v := ok_v + 1;
            end if;
            if bad = '1' then
               bad_v := bad_v + 1;
            end if;
         end loop;
         if good then
            assert ok_v = 1 and bad_v = 0
               report "tb_rx_fcs: " & name & " is not good"
               severity failure;
         else
            assert ok_v = 0 and bad_v = 1
               report "tb_rx_fcs: " & name & " is not bad"
               severity failure;
         end if;
      end procedure send;

   begin
      for i in 1 to 9 loop
         d_v(i - 1) := to_stdlogicvector(character'pos(C_DIGITS(i)), 8);
      end loop;
      assert fcs_of(d_v) = X"CBF43926"
         report "tb_rx_fcs: the CRC-32 of 123456789 is wrong"
         severity failure;

      wait until rising_edge(clk);
      wait until rising_edge(clk);
      rst <= '0';
      wait until rising_edge(clk);

      send(C_ARP, '0', true, "the ARP request");
      f_v     := C_ARP;
      f_v(40) := C_ARP(40) xor X"10";
      send(f_v, '0', false, "the ARP request with a bit of its data flipped");
      f_v     := C_ARP;
      f_v(62) := C_ARP(62) xor X"01";
      send(f_v, '0', false, "the ARP request with a bit of its FCS flipped");
      send(C_ARP, '1', false, "the ARP request with err_i");
      send(frame_of(1, 60), '0', true, "the frame of 64 bytes");
      send(frame_of(2, 96), '0', true, "the frame of 100 bytes");
      send(frame_of(3, 1514), '0', true, "the frame of 1518 bytes");
      send(C_ARP(0 to 2), '0', false, "the frame of 3 bytes");
      send(frame_of(4, 59), '0', false, "the frame of 63 bytes");
      send(C_ARP, '0', true, "the ARP request after a bad frame");

      report "tb_rx_fcs: PASS";
      finish;
   end process p_main;

end architecture simulation;
