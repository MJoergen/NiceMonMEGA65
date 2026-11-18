-- The ROM: 2^G_ADDR_BITS words of 32 bits, in block RAM, with a 64-bit read
-- port A for the instruction bus and a 32-bit port B for the data bus,
-- which reads and writes. It holds the program that the core boots from
-- (the monitor and BASIC in a release), at the bottom of the address
-- space, as the ROM of QNICE-FPGA does. src/mem.vhd decides which writes
-- reach it: those to BASIC's half, until it is locked (issue #153).
-- With G_WRITE false, port B takes no writes, and the ROM is a ROM to
-- Vivado, which packs it into fewer block RAMs, as the Nexys4DDR needs.
--
-- THEORY OF OPERATION
-- Port A takes a pair address a and reads the aligned pair of words 2a and
-- 2a + 1, word 2a in bits 31..0, as src/ram.vhd does. The words are kept
-- in two banks, the even words and the odd ones, and port B reads the bank
-- that bit 0 of its address selects. Each port reads in the cycle after
-- the address is given, as block RAM does. A write on port B, with a byte
-- enable for each of b_we_i's bits, goes to the bank of bit 0 of its
-- address, with G_WRITE; a read on port B in the cycle of a write returns the word
-- before it, and port A, at the address that is written, may read either
-- word. The words at configuration come from G_INIT_FILE,
-- a .bin file (ISA.md §10.4): one line per word, an 8-digit hex address, a
-- space, and the 8-digit hex word.
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
      G_INIT_FILE : string;
      G_WRITE     : boolean := true
   );
   port (
      clk_i     : in  std_logic;

      a_addr_i  : in  std_logic_vector(G_ADDR_BITS - 2 downto 0);
      a_data_o  : out std_logic_vector(63 downto 0);

      b_addr_i  : in  std_logic_vector(G_ADDR_BITS - 1 downto 0);
      b_we_i    : in  std_logic_vector(3 downto 0);
      b_wdata_i : in  std_logic_vector(31 downto 0);
      b_data_o  : out std_logic_vector(31 downto 0)
   );
end entity rom;

architecture synthesis of rom is

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
            if addr_v(0) = odd then
               mem_v(to_integer(addr_v(G_ADDR_BITS - 1 downto 1))) := data_v;
            end if;
         end if;
      end loop;
      file_close(f);
      return mem_v;
   end function load;

   -- The reads of each bank by each port, and the bank that port B reads.
   -- Each read is a register of its own, so that Vivado maps each bank to
   -- block RAM.
   signal a_even : std_logic_vector(31 downto 0);
   signal a_odd  : std_logic_vector(31 downto 0);
   signal b_even : std_logic_vector(31 downto 0);
   signal b_odd  : std_logic_vector(31 downto 0);
   signal b_sel  : std_logic;

begin

   gen_write : if G_WRITE generate

      signal mem_even : t_mem := load(G_INIT_FILE, '0');
      signal mem_odd  : t_mem := load(G_INIT_FILE, '1');

      attribute ram_style : string;
      attribute ram_style of mem_even : signal is "block";
      attribute ram_style of mem_odd  : signal is "block";

   begin

      p_a_even : process (clk_i)
      begin
         if rising_edge(clk_i) then
            a_even <= mem_even(to_integer(a_addr_i));
         end if;
      end process p_a_even;

      p_a_odd : process (clk_i)
      begin
         if rising_edge(clk_i) then
            a_odd <= mem_odd(to_integer(a_addr_i));
         end if;
      end process p_a_odd;

      p_b_even : process (clk_i)
      begin
         if rising_edge(clk_i) then
            b_even <= mem_even(to_integer(b_addr_i(G_ADDR_BITS - 1 downto 1)));

            for i in 0 to 3 loop
               if b_we_i(i) = '1' and b_addr_i(0) = '0' then
                  mem_even(to_integer(b_addr_i(G_ADDR_BITS - 1 downto 1)))(8 * i + 7 downto 8 * i) <= b_wdata_i(8 * i + 7 downto 8 * i);
               end if;
            end loop;

         end if;
      end process p_b_even;

      p_b_odd : process (clk_i)
      begin
         if rising_edge(clk_i) then
            b_odd <= mem_odd(to_integer(b_addr_i(G_ADDR_BITS - 1 downto 1)));

            for i in 0 to 3 loop
               if b_we_i(i) = '1' and b_addr_i(0) = '1' then
                  mem_odd(to_integer(b_addr_i(G_ADDR_BITS - 1 downto 1)))(8 * i + 7 downto 8 * i) <= b_wdata_i(8 * i + 7 downto 8 * i);
               end if;
            end loop;

         end if;
      end process p_b_odd;

   end generate gen_write;

   gen_read_only : if not G_WRITE generate

      constant C_EVEN : t_mem := load(G_INIT_FILE, '0');
      constant C_ODD  : t_mem := load(G_INIT_FILE, '1');

      signal mem_even : t_mem := C_EVEN;
      signal mem_odd  : t_mem := C_ODD;

      attribute rom_style : string;
      attribute rom_style of mem_even : signal is "block";
      attribute rom_style of mem_odd  : signal is "block";

   begin

      p_a : process (clk_i)
      begin
         if rising_edge(clk_i) then
            a_even <= mem_even(to_integer(a_addr_i));
            a_odd  <= mem_odd(to_integer(a_addr_i));
         end if;
      end process p_a;

      p_b : process (clk_i)
      begin
         if rising_edge(clk_i) then
            b_even <= mem_even(to_integer(b_addr_i(G_ADDR_BITS - 1 downto 1)));
            b_odd  <= mem_odd(to_integer(b_addr_i(G_ADDR_BITS - 1 downto 1)));
         end if;
      end process p_b;

   end generate gen_read_only;

   p_b_sel : process (clk_i)
   begin
      if rising_edge(clk_i) then
         b_sel <= b_addr_i(0);
      end if;
   end process p_b_sel;

   a_data_o <= a_odd & a_even;
   b_data_o <= b_odd when b_sel = '1' else
               b_even;

end architecture synthesis;
