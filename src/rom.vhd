-- The ROM: 2^G_ADDR_BITS words of 32 bits, in block RAM, with a read port A
-- for the instruction bus and a read port B for the data bus. It holds the
-- monitor, which the core boots from, at the bottom of the address space,
-- as the ROM of QNICE-FPGA does.
--
-- THEORY OF OPERATION
-- Each port reads in the cycle after the address is given, as block RAM
-- does. The words come from G_INIT_FILE, a .bin file (ISA.md §10.4): one
-- line per word, an 8-digit hex address, a space, and the 8-digit hex word.
-- A word at an address beyond the ROM is an error, so that a monitor that
-- outgrows the ROM is caught. Vivado reads the file during synthesis, and
-- GHDL when it elaborates.
--
-- RESET
-- None.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.textio.all;

entity rom is
   generic (
      G_ADDR_BITS : natural;
      G_INIT_FILE : string
   );
   port (
      clk_i    : in  std_logic;

      a_addr_i : in  std_logic_vector(G_ADDR_BITS - 1 downto 0);
      a_data_o : out std_logic_vector(31 downto 0);

      b_addr_i : in  std_logic_vector(G_ADDR_BITS - 1 downto 0);
      b_data_o : out std_logic_vector(31 downto 0)
   );
end entity rom;

architecture synthesis of rom is

   type t_mem is array (0 to 2 ** G_ADDR_BITS - 1) of std_logic_vector(31 downto 0);

   impure function load(name : string) return t_mem is
      file     f      : text;
      variable l      : line;
      variable addr_v : std_logic_vector(31 downto 0);
      variable data_v : std_logic_vector(31 downto 0);
      variable mem_v  : t_mem := (others => (others => '0'));
   begin
      file_open(f, name, read_mode);
      while not endfile(f) loop
         readline(f, l);
         if l'length > 0 then
            hread(l, addr_v);
            hread(l, data_v);
            assert to_integer(addr_v) < 2 ** G_ADDR_BITS
               report "rom: " & name & " has a word at " & to_hstring(addr_v) &
                      ", beyond the ROM"
               severity failure;
            mem_v(to_integer(addr_v)) := data_v;
         end if;
      end loop;
      file_close(f);
      return mem_v;
   end function load;

   signal mem : t_mem := load(G_INIT_FILE);

   attribute rom_style : string;
   attribute rom_style of mem : signal is "block";

begin

   p_a : process (clk_i)
   begin
      if rising_edge(clk_i) then
         a_data_o <= mem(to_integer(a_addr_i));
      end if;
   end process p_a;

   p_b : process (clk_i)
   begin
      if rising_edge(clk_i) then
         b_data_o <= mem(to_integer(b_addr_i));
      end if;
   end process p_b;

end architecture synthesis;
