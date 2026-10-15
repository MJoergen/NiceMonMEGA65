-- The copy of the screen of the text display (text.vhd): 2048 words of 32
-- bits in block RAM, written on one clock and read on another.
--
-- THEORY OF OPERATION
-- The write port is in the system clock domain and the read port in the VGA
-- clock domain. Each port is clocked by its own clock, so the memory is the
-- crossing between the clock domains, and no path between the clocks needs
-- to be timed. The read gives the word in the cycle after the address, as
-- block RAM does, and is 0 before the first read, as the word of stage 2 of
-- text.vhd was.
--
-- The memory is in an entity of its own because Vivado (2025.1) does not
-- make block RAM of the same memory written as a signal inside text.vhd,
-- whatever the coding: "Infeasible attribute ram_style = block ... trying to
-- implement using LUTRAM", which takes 352 RAM64M and reads the memory
-- asynchronously across the clocks. In an entity of its own it is two
-- RAMB36.
--
-- RESET
-- None. The copy starts as zeros, as the screen does.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity scr_ram is
   port (
      wr_clk_i  : in  std_logic;
      wr_we_i   : in  std_logic;
      wr_addr_i : in  std_logic_vector(10 downto 0);
      wr_data_i : in  std_logic_vector(31 downto 0);

      rd_clk_i  : in  std_logic;
      rd_addr_i : in  std_logic_vector(10 downto 0);
      rd_data_o : out std_logic_vector(31 downto 0) := (others => '0')
   );
end entity scr_ram;

architecture synthesis of scr_ram is

   type t_mem is array (0 to 2047) of std_logic_vector(31 downto 0);
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
