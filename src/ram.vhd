-- The on-chip memory: 2^G_ADDR_BITS words of 32 bits, in block RAM, with a
-- read-only 64-bit port A for the instruction bus and a read-write 32-bit
-- port B for the data bus.
--
-- THEORY OF OPERATION
-- Port A takes a pair address a, the low G_ADDR_BITS - 1 bits of the core's
-- instruction bus address, and reads the aligned pair of words 2a and
-- 2a + 1, word 2a in bits 31..0, as MICROARCH.md §1 of nice_cpu requires.
-- Port B takes the low G_ADDR_BITS bits of the word address. So the memory
-- repeats through the whole address space. The words are kept in two banks,
-- the even words and the odd ones: port A reads both, and port B reaches
-- the bank that bit 0 of its address selects. Each port reads in the cycle
-- after the address is given, as block RAM does. When both ports reach the
-- same word in one cycle, port A reads the value from before port B's
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

      a_addr_i  : in  std_logic_vector(G_ADDR_BITS - 2 downto 0);
      a_data_o  : out std_logic_vector(63 downto 0);

      b_addr_i  : in  std_logic_vector(G_ADDR_BITS - 1 downto 0);
      b_we_i    : in  std_logic;
      b_wdata_i : in  std_logic_vector(31 downto 0);
      b_rdata_o : out std_logic_vector(31 downto 0)
   );
end entity ram;

architecture synthesis of ram is

   -- One bank: the even or the odd words
   type t_mem is array (0 to 2 ** (G_ADDR_BITS - 1) - 1) of std_logic_vector(31 downto 0);

   -- The words of the file whose address has bit 0 equal to odd
   impure function load(name : string; odd : std_logic) return t_mem is
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
               if addr_v(0) = odd then
                  mem_v(to_integer(addr_v(G_ADDR_BITS - 1 downto 1))) := data_v;
               end if;
            end if;
         end loop;
         file_close(f);
      end if;
      return mem_v;
   end function load;

   signal mem_even : t_mem := load(G_INIT_FILE, '0');
   signal mem_odd  : t_mem := load(G_INIT_FILE, '1');

   -- Port B's reads of both banks, and the bank it reads
   signal b_even : std_logic_vector(31 downto 0);
   signal b_odd  : std_logic_vector(31 downto 0);
   signal b_sel  : std_logic;

begin

   p_a : process (clk_i)
   begin
      if rising_edge(clk_i) then
         a_data_o <= mem_odd(to_integer(a_addr_i)) & mem_even(to_integer(a_addr_i));
      end if;
   end process p_a;

   p_b_even : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if b_we_i = '1' and b_addr_i(0) = '0' then
            mem_even(to_integer(b_addr_i(G_ADDR_BITS - 1 downto 1))) <= b_wdata_i;
         end if;
         b_even <= mem_even(to_integer(b_addr_i(G_ADDR_BITS - 1 downto 1)));
      end if;
   end process p_b_even;

   p_b_odd : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if b_we_i = '1' and b_addr_i(0) = '1' then
            mem_odd(to_integer(b_addr_i(G_ADDR_BITS - 1 downto 1))) <= b_wdata_i;
         end if;
         b_odd <= mem_odd(to_integer(b_addr_i(G_ADDR_BITS - 1 downto 1)));
      end if;
   end process p_b_odd;

   p_b_sel : process (clk_i)
   begin
      if rising_edge(clk_i) then
         b_sel <= b_addr_i(0);
      end if;
   end process p_b_sel;

   b_rdata_o <= b_odd when b_sel = '1' else
                b_even;

end architecture synthesis;
