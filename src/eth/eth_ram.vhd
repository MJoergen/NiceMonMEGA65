-- The memory of the FIFOs of Ethernet frames (eth_rx_fifo.vhd and
-- eth_tx_fifo.vhd): 2^G_ADDR_BITS words of 9 bits in block RAM, written on
-- one clock and read on another.
--
-- THEORY OF OPERATION
-- The write port is in the clock domain of the FIFO's writer and the read
-- port in that of its reader, each clocked by its own clock, as in
-- video/scr_ram.vhd. The read gives the word in the cycle after the
-- address, as block RAM does. The memory is in an entity of its own so that
-- Vivado makes block RAM of it (video/scr_ram.vhd says why).
--
-- RESET
-- None.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity eth_ram is
   generic (
      G_ADDR_BITS : natural
   );
   port (
      wr_clk_i  : in  std_logic;
      wr_we_i   : in  std_logic;
      wr_addr_i : in  std_logic_vector(G_ADDR_BITS - 1 downto 0);
      wr_data_i : in  std_logic_vector(8 downto 0);

      rd_clk_i  : in  std_logic;
      rd_addr_i : in  std_logic_vector(G_ADDR_BITS - 1 downto 0);
      rd_data_o : out std_logic_vector(8 downto 0) := (others => '0')
   );
end entity eth_ram;

architecture synthesis of eth_ram is

   type t_mem is array (0 to 2 ** G_ADDR_BITS - 1) of std_logic_vector(8 downto 0);

   signal mem : t_mem := (others => (others => '0'));

   attribute ram_style : string;
   attribute ram_style of mem : signal is "block";

begin

   p_write : process (wr_clk_i)
   begin
      if rising_edge(wr_clk_i) then
         if wr_we_i = '1' then
            mem(to_integer(wr_addr_i)) <= wr_data_i;
         end if;
      end if;
   end process p_write;

   p_read : process (rd_clk_i)
   begin
      if rising_edge(rd_clk_i) then
         rd_data_o <= mem(to_integer(rd_addr_i));
      end if;
   end process p_read;

end architecture synthesis;
