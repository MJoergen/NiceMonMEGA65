-- What the Ethernet files share: the CRC-32 of IEEE 802.3, the frame check
-- sequence of Ethernet frames, as rx_fcs.vhd checks it and rmii_tx.vhd
-- appends it; the Gray code in which the FIFOs (eth_rx_fifo.vhd and
-- eth_tx_fifo.vhd) pass their pointers between the clock domains; the
-- bytes of a frame, and of a word in the order they are sent; and the
-- ones' complement sum of the checksums of IPv4, ICMP, and TCP, as
-- eth_icmp.vhd and eth_tcp.vhd check and compute them; and the address of
-- a TCP host and the header fields of a TCP segment, as the files of the
-- TCP server pass them.
--
-- THEORY OF OPERATION
-- The register starts at all ones, and each byte goes into it LSB first, as
-- the bits are sent, with the polynomial 0x04C11DB7 in its reflected form,
-- 0xEDB88320. The sender appends the complement of the register, LSB first,
-- so when the four bytes of the frame check sequence have gone in too, the
-- register of a good frame holds C_CRC_RESIDUE, whatever the frame.
-- Successive numbers differ in one bit of their Gray code, so a pointer
-- that moves by one at a time can cross to another clock bit by bit.
-- A word's bytes come out most significant first, as the network has them.
-- The ones' complement sum of two words adds them and their carry, so that
-- a header whose checksum is right adds up to 0xFFFF (RFC 1071).
--
-- RESET
-- None; a package.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

package eth_pkg is

   constant C_CRC_INIT    : std_logic_vector(31 downto 0) := X"FFFFFFFF";
   constant C_CRC_POLY    : std_logic_vector(31 downto 0) := X"EDB88320";
   constant C_CRC_RESIDUE : std_logic_vector(31 downto 0) := X"DEBB20E3";

   type t_bytes is array (natural range <>) of std_logic_vector(7 downto 0);

   -- A TCP host: its MAC address, IP address, and port
   type t_host is record
      mac      : std_logic_vector(47 downto 0);
      ip       : std_logic_vector(31 downto 0);
      tcp_port : std_logic_vector(15 downto 0);
   end record t_host;

   constant C_HOST_NONE : t_host := (
      mac      => (others => '0'),
      ip       => (others => '0'),
      tcp_port => (others => '0')
   );

   -- A TCP segment: its source, its sequence and acknowledgment numbers,
   -- its flags, and its window
   type t_seg is record
      host  : t_host;
      seq   : std_logic_vector(31 downto 0);
      ack   : std_logic_vector(31 downto 0);
      flags : std_logic_vector(7 downto 0);
      win   : std_logic_vector(15 downto 0);
   end record t_seg;

   -- The register after the byte d, LSB first
   function crc_byte (
      c : std_logic_vector(31 downto 0);
      d : std_logic_vector(7 downto 0)
   ) return std_logic_vector;

   function to_gray (b : std_logic_vector) return std_logic_vector;
   function from_gray (g : std_logic_vector) return std_logic_vector;

   -- The bytes of a word, most significant first
   function b2 (v : std_logic_vector(15 downto 0)) return t_bytes;
   function b4 (v : std_logic_vector(31 downto 0)) return t_bytes;
   function b6 (v : std_logic_vector(47 downto 0)) return t_bytes;

   -- The ones' complement sum of two words
   function ones_add (
      a : std_logic_vector(15 downto 0);
      b : std_logic_vector(15 downto 0)
   ) return std_logic_vector;

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

   function b2 (v : std_logic_vector(15 downto 0)) return t_bytes is
   begin
      return (v(15 downto 8), v(7 downto 0));
   end function b2;

   function b4 (v : std_logic_vector(31 downto 0)) return t_bytes is
   begin
      return (v(31 downto 24), v(23 downto 16), v(15 downto 8), v(7 downto 0));
   end function b4;

   function b6 (v : std_logic_vector(47 downto 0)) return t_bytes is
   begin
      return (v(47 downto 40), v(39 downto 32), v(31 downto 24), v(23 downto 16),
              v(15 downto 8), v(7 downto 0));
   end function b6;

   function ones_add (
      a : std_logic_vector(15 downto 0);
      b : std_logic_vector(15 downto 0)
   ) return std_logic_vector is
      variable s_v : std_logic_vector(16 downto 0);
   begin
      s_v := ('0' & a) + ('0' & b);
      return s_v(15 downto 0) + s_v(16);
   end function ones_add;

end package body eth_pkg;
