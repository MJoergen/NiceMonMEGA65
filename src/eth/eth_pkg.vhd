-- What the Ethernet files share: the CRC-32 of IEEE 802.3, the frame check
-- sequence of Ethernet frames, as rx_fcs.vhd checks it and rmii_tx.vhd
-- appends it, and the Gray code in which the FIFOs (eth_rx_fifo.vhd and
-- eth_tx_fifo.vhd) pass their pointers between the clock domains.
--
-- THEORY OF OPERATION
-- The register starts at all ones, and each byte goes into it LSB first, as
-- the bits are sent, with the polynomial 0x04C11DB7 in its reflected form,
-- 0xEDB88320. The sender appends the complement of the register, LSB first,
-- so when the four bytes of the frame check sequence have gone in too, the
-- register of a good frame holds C_CRC_RESIDUE, whatever the frame.
-- Successive numbers differ in one bit of their Gray code, so a pointer
-- that moves by one at a time can cross to another clock bit by bit.
--
-- RESET
-- None; a package.

library ieee;
   use ieee.std_logic_1164.all;

package eth_pkg is

   constant C_CRC_INIT    : std_logic_vector(31 downto 0) := X"FFFFFFFF";
   constant C_CRC_POLY    : std_logic_vector(31 downto 0) := X"EDB88320";
   constant C_CRC_RESIDUE : std_logic_vector(31 downto 0) := X"DEBB20E3";

   -- The register after the byte d, LSB first
   function crc_byte (
      c : std_logic_vector(31 downto 0);
      d : std_logic_vector(7 downto 0)
   ) return std_logic_vector;

   function to_gray (b : std_logic_vector) return std_logic_vector;
   function from_gray (g : std_logic_vector) return std_logic_vector;

end package eth_pkg;

package body eth_pkg is

   function crc_byte (
      c : std_logic_vector(31 downto 0);
      d : std_logic_vector(7 downto 0)
   ) return std_logic_vector is
      variable c_v : std_logic_vector(31 downto 0);
   begin
      c_v := c;

      for i in 0 to 7 loop
         if (c_v(0) xor d(i)) = '1' then
            c_v := ('0' & c_v(31 downto 1)) xor C_CRC_POLY;
         else
            c_v := '0' & c_v(31 downto 1);
         end if;
      end loop;

      return c_v;
   end function crc_byte;

   function to_gray (b : std_logic_vector) return std_logic_vector is
      variable b_v : std_logic_vector(b'length - 1 downto 0);
   begin
      b_v := b;
      return b_v xor ('0' & b_v(b_v'high downto 1));
   end function to_gray;

   function from_gray (g : std_logic_vector) return std_logic_vector is
      variable g_v : std_logic_vector(g'length - 1 downto 0);
      variable b_v : std_logic_vector(g'length - 1 downto 0);
   begin
      g_v           := g;
      b_v(b_v'high) := g_v(g_v'high);

      for i in b_v'high - 1 downto 0 loop
         b_v(i) := b_v(i + 1) xor g_v(i);
      end loop;

      return b_v;
   end function from_gray;

end package body eth_pkg;
