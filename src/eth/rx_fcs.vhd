-- The check of a received Ethernet frame's frame check sequence, the CRC-32
-- of IEEE 802.3 in its last four bytes. The bytes come from rmii_rx.vhd, and
-- at the end of each frame ok_o or bad_o is '1' for a cycle.
--
-- THEORY OF OPERATION
-- The CRC register starts at all ones, and each byte of valid_i goes into
-- it LSB first, as the bits are sent, with the polynomial 0x04C11DB7 in its
-- reflected form, 0xEDB88320. The sender appends the complement of the
-- register, LSB first, so when the four bytes of the frame check sequence
-- have gone in too, the register of a good frame holds the residue
-- 0xDEBB20E3, whatever the frame. eof_i then gives ok_o when the register
-- holds it and the frame has at least C_MIN_LEN bytes, 64 with its check
-- sequence, the least that IEEE 802.3 allows, and bad_o when it does not,
-- or when err_i is '1'. The register and the count of bytes start again
-- after each eof_i.
-- ok_o and bad_o come a cycle after eof_i.
--
-- RESET
-- Synchronous, to clk_i. Reset starts the register again, with neither
-- ok_o nor bad_o.

library ieee;
   use ieee.std_logic_1164.all;

entity rx_fcs is
   port (
      clk_i   : in  std_logic;
      rst_i   : in  std_logic;
      -- The frame, from rmii_rx.vhd
      data_i  : in  std_logic_vector(7 downto 0);
      valid_i : in  std_logic;
      eof_i   : in  std_logic;
      err_i   : in  std_logic;
      -- The end of a frame, with its check sequence right, or wrong
      ok_o    : out std_logic;
      bad_o   : out std_logic
   );
end entity rx_fcs;

architecture synthesis of rx_fcs is

   constant C_POLY    : std_logic_vector(31 downto 0) := X"EDB88320";
   constant C_RESIDUE : std_logic_vector(31 downto 0) := X"DEBB20E3";
   constant C_MIN_LEN : natural                       := 64;

   signal crc : std_logic_vector(31 downto 0) := (others => '1');
   -- The bytes of the frame, up to C_MIN_LEN
   signal len : natural range 0 to C_MIN_LEN  := 0;

   -- The register after the byte d, LSB first
   function crc_byte (
      c : std_logic_vector(31 downto 0);
      d : std_logic_vector(7 downto 0)
   ) return std_logic_vector is
      variable c_v : std_logic_vector(31 downto 0);
   begin
      c_v := c;

      for i in 0 to 7 loop
         if (c_v(0) xor d(i)) = '1' then
            c_v := ('0' & c_v(31 downto 1)) xor C_POLY;
         else
            c_v := '0' & c_v(31 downto 1);
         end if;
      end loop;

      return c_v;
   end function crc_byte;

begin

   p_fcs : process (clk_i)
   begin
      if rising_edge(clk_i) then
         ok_o  <= '0';
         bad_o <= '0';

         if valid_i = '1' then
            crc <= crc_byte(crc, data_i);
            if len < C_MIN_LEN then
               len <= len + 1;
            end if;
         end if;

         if eof_i = '1' then
            if crc = C_RESIDUE and len = C_MIN_LEN and err_i = '0' then
               ok_o <= '1';
            else
               bad_o <= '1';
            end if;
            crc <= (others => '1');
            len <= 0;
         end if;

         if rst_i = '1' then
            crc   <= (others => '1');
            len   <= 0;
            ok_o  <= '0';
            bad_o <= '0';
         end if;
      end if;
   end process p_fcs;

end architecture synthesis;
