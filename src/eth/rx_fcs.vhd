-- The check of a received Ethernet frame's frame check sequence, the CRC-32
-- of IEEE 802.3 in its last four bytes. The bytes come from rmii_rx.vhd, and
-- at the end of each frame ok_o or bad_o is '1' for a cycle.
--
-- THEORY OF OPERATION
-- The CRC register (eth_pkg.vhd) takes each byte of valid_i, and when the
-- four bytes of the frame check sequence have gone in too, the register of
-- a good frame holds the residue 0xDEBB20E3, whatever the frame. eof_i then
-- gives ok_o when the register holds it and the frame has at least
-- C_MIN_LEN bytes, 64 with its check sequence, the least that IEEE 802.3
-- allows, and bad_o when it does not, or when err_i is '1'. The register
-- and the count of bytes start again after each eof_i.
-- ok_o and bad_o come a cycle after eof_i.
--
-- RESET
-- Synchronous, to clk_i. Reset starts the register again, with neither
-- ok_o nor bad_o.

library ieee;
   use ieee.std_logic_1164.all;

library work;
   use work.eth_pkg.all;

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

   constant C_MIN_LEN : natural := 64;

   signal crc : std_logic_vector(31 downto 0) := C_CRC_INIT;
   -- The bytes of the frame, up to C_MIN_LEN
   signal len : natural range 0 to C_MIN_LEN  := 0;

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
            if crc = C_CRC_RESIDUE and len = C_MIN_LEN and err_i = '0' then
               ok_o <= '1';
            else
               bad_o <= '1';
            end if;
            crc <= C_CRC_INIT;
            len <= 0;
         end if;

         if rst_i = '1' then
            crc   <= C_CRC_INIT;
            len   <= 0;
            ok_o  <= '0';
            bad_o <= '0';
         end if;
      end if;
   end process p_fcs;

end architecture synthesis;
