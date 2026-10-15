-- The on-chip memory: 2^G_ADDR_BITS words of 32 bits, in block RAM, with a
-- read-only port A for the instruction bus and a read-write port B for the
-- data bus.
--
-- THEORY OF OPERATION
-- Both ports take the low G_ADDR_BITS bits of the word address, so the
-- memory repeats through the whole address space. Each port reads in the
-- cycle after the address is given, as block RAM does. When both ports reach
-- the same word in one cycle, port A reads the value from before port B's
-- write.
--
-- The memory is loaded at configuration time from G_INIT_FILE, a .bin file
-- (ISA.md §10.4): one line per word, an 8-digit hex address, a space, and the
-- 8-digit hex word. With G_INIT_FILE = "" the memory starts as zeros. Vivado
-- reads the file during synthesis.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.textio.all;

entity ram is
   generic (
      G_ADDR_BITS : natural;
      G_INIT_FILE : string := ""
   );
   port (
      clk_i     : in  std_logic;

      a_addr_i  : in  std_logic_vector(G_ADDR_BITS - 1 downto 0);
      a_data_o  : out std_logic_vector(31 downto 0);

      b_addr_i  : in  std_logic_vector(G_ADDR_BITS - 1 downto 0);
      b_we_i    : in  std_logic;
      b_wdata_i : in  std_logic_vector(31 downto 0);
      b_rdata_o : out std_logic_vector(31 downto 0)
   );
end entity ram;

architecture synthesis of ram is

   type t_mem is array (0 to 2 ** G_ADDR_BITS - 1) of std_logic_vector(31 downto 0);

   impure function load(name : string) return t_mem is
      file     f      : text;
      variable l      : line;
      variable addr_v : std_logic_vector(31 downto 0);
      variable data_v : std_logic_vector(31 downto 0);
      variable mem_v  : t_mem := (others => (others => '0'));
   begin
      if name /= "" then
         file_open(f, name, read_mode);
         while not endfile(f) loop
            readline(f, l);
            if l'length > 0 then
               hread(l, addr_v);
               hread(l, data_v);
               mem_v(to_integer(addr_v(G_ADDR_BITS - 1 downto 0))) := data_v;
            end if;
         end loop;
         file_close(f);
      end if;
      return mem_v;
   end function load;

   signal mem : t_mem := load(G_INIT_FILE);

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
         if b_we_i = '1' then
            mem(to_integer(b_addr_i)) <= b_wdata_i;
         end if;
         b_rdata_o <= mem(to_integer(b_addr_i));
      end if;
   end process p_b;

end architecture synthesis;
