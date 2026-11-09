-- The memory of the NiceMon system (src/nicemon.vhd): the RAM, the ROM, and
-- the screen, on the core's instruction bus and on port B, which the core's
-- data bus and the debug link share, and the clear of the memory.
--
-- THEORY OF OPERATION
-- The RAM has 2^G_RAM_ADDR_BITS words and repeats through the address
-- space. The ROM, 2^G_ROM_ADDR_BITS words from G_ROM_FILE, is in front of
-- the RAM, and repeats with it, while rom_hidden_i is 0; a build without
-- G_ROM_FILE has no ROM, and reads 0 there. The screen is the
-- 2^G_SCR_ADDR_BITS words from 0xFFFF0000, memory of its own. Each is read
-- in the cycle after the address is given, as block RAM does.
--
-- Port A is the core's instruction bus, which never stalls. It reads an
-- aligned pair of words, the word at the lower address in bits 31..0, and
-- acknowledges it in the next cycle. A pair lies wholly in the RAM, the
-- ROM, the screen, or the I/O page, 0xFFFFFF00-FF, so the address of its
-- first word decides where it is read; a pair in the I/O page reads 0
-- (ISA.md §8.3). A reset of the core (core_rst_i) drops the acknowledges
-- of the fetches in flight, and an acknowledge that comes while CYC is low
-- is dropped, as Wishbone ignores it.
--
-- Port B takes the request that nicemon takes in this cycle, when it is to
-- memory (stb_i), and its address, which nicemon drives in every cycle.
-- A write goes to the screen or to the RAM, unless it is to the ROM while
-- the ROM is shown, where it is dropped. A read returns the word of the
-- memory of its address on rdata_o, in the next cycle.
--
-- Port B has the byte windows of nice_cpu's SYSTEM.md §9. An address A
-- whose top four bits are 1 to 5 reaches the word W = (A >> 2) AND
-- 0x03FFFFFF, which lies in the RAM, or in the ROM while it is shown, as
-- a plain address W does, and never in the screen. A write through the
-- byte windows, 2 and 3, writes bits 7..0 of the value to byte A mod 4 of
-- W, and one through the halfword windows, 4 and 5, bits 15..0 to
-- halfword bit 1 of A, with the RAM's byte enables, in one access. A read
-- returns the word W on rdata_o, and on rdata_win_o the value of its
-- window: that byte or halfword, zero-extended by windows 2 and 4 and
-- sign-extended by 3 and 5, or the whole word in window 1 and outside the
-- windows. The window and bits 1..0 of A are kept for the cycle of the
-- read's word. rdata_win_o is a LUT level or two later than rdata_o, too
-- late for the core's path from the RAM at 100 MHz, so nicemon registers
-- it and acknowledges a read through windows 2 to 5 a cycle later. Port A does
-- not decode the windows: a fetch there reads the RAM or the ROM that the
-- address aliases, which SYSTEM.md §9 allows. Every write to the
-- screen is also given out on scr_*_o, a cycle late, for a display that
-- keeps a copy (src/video/text.vhd). The register keeps the core's store
-- paths short, for the display lies far from the core on the FPGA.
--
-- A clear starts with clear_i, and writes 0 to one word of the RAM and one
-- of the screen in each cycle, the RAM under the ROM included, through
-- 2^C_CLR_BITS cycles, while clearing_o is high. Then clear_done_o is high
-- for a cycle. nicemon takes no request meanwhile.
--
-- With G_FORMAL, it states the properties that formal/mem.sby proves: each
-- write reaches the memory of its address, and no other, in the bytes of
-- its window, the clear writes
-- 0 to every word, a read returns the word of the memory of its address,
-- and each fetch is acknowledged once.
--
-- RESET
-- Synchronous. Reset ends a clear, and drops the acknowledges of the
-- fetches; the core's reset drops those too. The memory is not changed.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity mem is
   generic (
      G_RAM_ADDR_BITS : natural;
      -- The screen has 2^G_SCR_ADDR_BITS words.
      G_SCR_ADDR_BITS : natural;
      -- The ROM: 2^G_ROM_ADDR_BITS words from the .bin file G_ROM_FILE, or
      -- none when the file name is empty
      G_ROM_FILE      : string  := "";
      G_ROM_ADDR_BITS : natural;
      -- Start the RAM with any contents, for formal/nicemon.sby
      G_RAM_ANY       : boolean := false;
      -- The properties for formal/mem.sby; implies G_RAM_ANY
      G_FORMAL        : boolean := false
   );
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;
      -- Bit 3 of the link's control register: the ROM is hidden, and the
      -- RAM is at 0
      rom_hidden_i : in  std_logic;
      -- Port A: the core's instruction bus, with the pair address
      core_rst_i   : in  std_logic;
      ibus_cyc_i   : in  std_logic;
      ibus_stb_i   : in  std_logic;
      ibus_addr_i  : in  std_logic_vector(30 downto 0);
      ibus_ack_o   : out std_logic;
      ibus_data_o  : out std_logic_vector(63 downto 0);
      -- Port B: the address of the request, the core's or the link's, and
      -- stb_i when it is taken in this cycle and is to memory
      stb_i        : in  std_logic;
      we_i         : in  std_logic;
      addr_i       : in  std_logic_vector(31 downto 0);
      wdata_i      : in  std_logic_vector(31 downto 0);
      -- The word read by the request one cycle earlier, and its value
      -- through the request's byte window
      rdata_o      : out std_logic_vector(31 downto 0);
      rdata_win_o  : out std_logic_vector(31 downto 0);
      -- The clear: its start, while it runs, and a pulse at its end
      clear_i      : in  std_logic;
      clearing_o   : out std_logic;
      clear_done_o : out std_logic;
      -- The writes to the screen: the word's offset from 0xFFFF0000, and
      -- the word written
      scr_we_o     : out std_logic;
      scr_addr_o   : out std_logic_vector(G_SCR_ADDR_BITS - 1 downto 0);
      scr_data_o   : out std_logic_vector(31 downto 0)
   );
end entity mem;

architecture synthesis of mem is

   -- The screen: 0xFFFF0000 and the 2^G_SCR_ADDR_BITS words from it
   constant C_SCR_BITS : natural := G_SCR_ADDR_BITS;
   -- 0xFFFF0000 without its low C_SCR_BITS bits: bits 31..16 are '1' and
   -- the rest '0'. That holds only for C_SCR_BITS <= 16, which the assert
   -- below checks.
   constant C_SCR_BASE : std_logic_vector(31 downto C_SCR_BITS) := (31 downto 16 => '1', others => '0');

   -- The clearing counts through the larger of the RAM and the screen.
   constant C_CLR_BITS : natural := maximum(G_RAM_ADDR_BITS, C_SCR_BITS);

   -- Whether a memory address is in the ROM's range, which repeats with the
   -- RAM's
   function in_rom(addr : std_logic_vector(31 downto 0)) return boolean is
   begin
      return or(addr(G_RAM_ADDR_BITS - 1 downto G_ROM_ADDR_BITS)) = '0';
   end function in_rom;

   -- The memory that a memory address lands in: the screen, the ROM while
   -- it is shown, or else the RAM
   type t_mem is (MEM_RAM, MEM_ROM, MEM_SCR);

   -- The byte window of a data address (SYSTEM.md §9), by its top four
   -- bits, 1 to 5, or none
   type t_win is (WIN_NONE, WIN_WORD, WIN_BYTE, WIN_SBYTE, WIN_HALF, WIN_SHALF);

   function win_of(addr : std_logic_vector(31 downto 0)) return t_win is
   begin

      case addr(31 downto 28) is
         when "0001" => return WIN_WORD;
         when "0010" => return WIN_BYTE;
         when "0011" => return WIN_SBYTE;
         when "0100" => return WIN_HALF;
         when "0101" => return WIN_SHALF;
         when others => return WIN_NONE;
      end case;

   end function win_of;

   -- The word address that a data address reaches: (A >> 2) AND 0x03FFFFFF
   -- in a window, else A itself
   function word_of(addr : std_logic_vector(31 downto 0)) return std_logic_vector is
   begin
      if win_of(addr) = WIN_NONE then
         return addr;
      end if;
      return "000000" & addr(27 downto 2);
   end function word_of;

   -- The bytes that a write through window win changes, bit i for bits
   -- 8i + 7..8i, with lane = bits 1..0 of its address
   function lanes_of(win  : t_win;
                     lane : std_logic_vector(1 downto 0)) return std_logic_vector is
   begin

      case win is
         when WIN_BYTE | WIN_SBYTE =>

            case lane is
               when "00" => return "0001";
               when "01" => return "0010";
               when "10" => return "0100";
               when others => return "1000";
            end case;

         when WIN_HALF | WIN_SHALF =>
            if lane(1) = '1' then
               return "1100";
            end if;
            return "0011";
         when others =>
            return "1111";
      end case;

   end function lanes_of;

   -- The value of a write through window win, in every lane that it may
   -- change: bits 7..0 in each byte, or bits 15..0 in each halfword
   function lane_data(win  : t_win;
                      data : std_logic_vector(31 downto 0)) return std_logic_vector is
   begin

      case win is
         when WIN_BYTE | WIN_SBYTE =>
            return data(7 downto 0) & data(7 downto 0) & data(7 downto 0) & data(7 downto 0);
         when WIN_HALF | WIN_SHALF =>
            return data(15 downto 0) & data(15 downto 0);
         when others =>
            return data;
      end case;

   end function lane_data;

   -- What a read through window win returns of word, with lane = bits 1..0
   -- of its address
   function win_read(win  : t_win;
                     lane : std_logic_vector(1 downto 0);
                     word : std_logic_vector(31 downto 0)) return std_logic_vector is
      variable byte_v : std_logic_vector(7 downto 0);
      variable half_v : std_logic_vector(15 downto 0);
   begin

      case lane is
         when "00" => byte_v := word(7 downto 0);
         when "01" => byte_v := word(15 downto 8);
         when "10" => byte_v := word(23 downto 16);
         when others => byte_v := word(31 downto 24);
      end case;

      if lane(1) = '1' then
         half_v := word(31 downto 16);
      else
         half_v := word(15 downto 0);
      end if;

      case win is
         when WIN_BYTE => return X"000000" & byte_v;
         when WIN_SBYTE => return (31 downto 8 => byte_v(7)) & byte_v;
         when WIN_HALF => return X"0000" & half_v;
         when WIN_SHALF => return (31 downto 16 => half_v(15)) & half_v;
         when others => return word;
      end case;

   end function win_read;

   function mem_of(addr       : std_logic_vector(31 downto 0);
                   rom_hidden : std_logic) return t_mem is
   begin
      if addr(31 downto C_SCR_BITS) = C_SCR_BASE then
         return MEM_SCR;
      elsif rom_hidden = '0' and in_rom(addr) then
         return MEM_ROM;
      end if;
      return MEM_RAM;
   end function mem_of;

   -- The clear: the address, and a pulse when it is done
   signal clearing : std_logic := '0';
   signal clr_addr : std_logic_vector(C_CLR_BITS - 1 downto 0);
   signal clr_done : std_logic := '0';

   -- Port A: the first word of the pair, and where the pair was read
   signal ibus_word : std_logic_vector(31 downto 0);
   signal ibus_ack  : std_logic := '0';
   signal ibus_io   : std_logic := '0';
   signal ibus_mem  : t_mem     := MEM_RAM;

   -- Port B: the window and the word address of the request, and the
   -- memory, the window, and bits 1..0 of the address of the last one
   signal b_win   : t_win;
   signal b_word  : std_logic_vector(31 downto 0);
   signal rd_mem  : t_mem                        := MEM_RAM;
   signal rd_win  : t_win                        := WIN_NONE;
   signal rd_lane : std_logic_vector(1 downto 0) := "00";
   signal rd_word : std_logic_vector(31 downto 0);

   -- The RAM's ports
   signal ram_a_addr  : std_logic_vector(G_RAM_ADDR_BITS - 2 downto 0);
   signal ram_a_data  : std_logic_vector(63 downto 0);
   signal ram_b_addr  : std_logic_vector(G_RAM_ADDR_BITS - 1 downto 0);
   signal ram_b_we    : std_logic_vector(3 downto 0);
   signal ram_b_wdata : std_logic_vector(31 downto 0);
   signal ram_b_rdata : std_logic_vector(31 downto 0);

   -- The ROM, read at the addresses of the RAM's ports
   signal rom_a_data : std_logic_vector(63 downto 0);
   signal rom_b_data : std_logic_vector(31 downto 0);

   -- The screen, like the RAM, written with ram_b_wdata
   signal scr_a_data  : std_logic_vector(63 downto 0);
   signal scr_b_addr  : std_logic_vector(C_SCR_BITS - 1 downto 0);
   signal scr_b_we    : std_logic;
   signal scr_b_rdata : std_logic_vector(31 downto 0);

begin

   assert G_ROM_ADDR_BITS < G_RAM_ADDR_BITS
      report "mem: the ROM must leave room for RAM above it"
      severity failure;

   assert C_SCR_BITS <= 16
      report "mem: the screen must lie in 0xFFFF0000-FFFF"
      severity failure;

   ---------------------------------------------------------------------------
   -- Port A: the instruction bus
   ---------------------------------------------------------------------------

   ibus_word  <= ibus_addr_i & '0';
   ram_a_addr <= ibus_addr_i(G_RAM_ADDR_BITS - 2 downto 0);

   p_ibus : process (clk_i)
   begin
      if rising_edge(clk_i) then
         ibus_ack <= ibus_cyc_i and ibus_stb_i;
         ibus_io  <= and(ibus_word(31 downto 8));
         ibus_mem <= mem_of(ibus_word, rom_hidden_i);
         if rst_i = '1' or core_rst_i = '1' then
            ibus_ack <= '0';
         end if;
      end if;
   end process p_ibus;

   ibus_ack_o  <= ibus_ack and ibus_cyc_i;
   ibus_data_o <= (others => '0') when ibus_io = '1' else
                  scr_a_data when ibus_mem = MEM_SCR else
                  rom_a_data when ibus_mem = MEM_ROM else
                  ram_a_data;


   ---------------------------------------------------------------------------
   -- Port B and the clear
   ---------------------------------------------------------------------------

   b_win  <= win_of(addr_i);
   b_word <= word_of(addr_i);

   ram_b_addr  <= clr_addr(G_RAM_ADDR_BITS - 1 downto 0) when clearing = '1' else
                  b_word(G_RAM_ADDR_BITS - 1 downto 0);
   ram_b_wdata <= (others => '0') when clearing = '1' else
                  lane_data(b_win, wdata_i);
   scr_b_addr  <= clr_addr(C_SCR_BITS - 1 downto 0) when clearing = '1' else
                  addr_i(C_SCR_BITS - 1 downto 0);

   -- A write is served in the cycle that its request is taken, and in no
   -- other cycle. While the memory is cleared, both are written. The
   -- screen lies beyond the windows, so its writes are of whole words.
   p_we : process (all)
   begin
      ram_b_we <= "0000";
      scr_b_we <= '0';
      if clearing = '1' then
         ram_b_we <= "1111";
         scr_b_we <= '1';
      elsif stb_i = '1' and we_i = '1' then

         case mem_of(b_word, rom_hidden_i) is
            when MEM_SCR => scr_b_we <= '1';
            when MEM_ROM => null;
            when MEM_RAM => ram_b_we <= lanes_of(b_win, addr_i(1 downto 0));
         end case;

      end if;
   end process p_we;

   p_b : process (clk_i)
   begin
      if rising_edge(clk_i) then
         clr_done <= '0';

         if stb_i = '1' then
            rd_mem  <= mem_of(b_word, rom_hidden_i);
            rd_win  <= b_win;
            rd_lane <= addr_i(1 downto 0);
         end if;

         if clearing = '1' then
            clr_addr <= clr_addr + 1;
            if and(clr_addr) = '1' then
               clearing <= '0';
               clr_done <= '1';
            end if;
         elsif clear_i = '1' then
            clearing <= '1';
            clr_addr <= (others => '0');
         end if;

         if rst_i = '1' then
            clearing <= '0';
            clr_done <= '0';
         end if;
      end if;
   end process p_b;

   rd_word     <= scr_b_rdata when rd_mem = MEM_SCR else
              rom_b_data when rd_mem = MEM_ROM else
              ram_b_rdata;
   rdata_o     <= rd_word;
   rdata_win_o <= win_read(rd_win, rd_lane, rd_word);

   clearing_o   <= clearing;
   clear_done_o <= clr_done;

   p_scr_out : process (clk_i)
   begin
      if rising_edge(clk_i) then
         scr_we_o   <= scr_b_we;
         scr_addr_o <= scr_b_addr;
         scr_data_o <= ram_b_wdata;
      end if;
   end process p_scr_out;


   ---------------------------------------------------------------------------
   -- The memories
   ---------------------------------------------------------------------------

   i_ram : entity work.ram
      generic map (
         G_ADDR_BITS => G_RAM_ADDR_BITS,
         G_FORMAL    => G_FORMAL or G_RAM_ANY
      )
      port map (
         clk_i     => clk_i,
         a_addr_i  => ram_a_addr,
         a_data_o  => ram_a_data,
         b_addr_i  => ram_b_addr,
         b_we_i    => ram_b_we,
         b_wdata_i => ram_b_wdata,
         b_rdata_o => ram_b_rdata
      ); -- i_ram

   gen_rom : if G_ROM_FILE /= "" generate

      -- The ROM, read at the addresses of both memory ports. Its words are
      -- taken instead of the RAM's while it is not hidden.
      i_rom : entity work.rom
         generic map (
            G_ADDR_BITS => G_ROM_ADDR_BITS,
            G_INIT_FILE => G_ROM_FILE
         )
         port map (
            clk_i    => clk_i,
            a_addr_i => ram_a_addr(G_ROM_ADDR_BITS - 2 downto 0),
            a_data_o => rom_a_data,
            b_addr_i => ram_b_addr(G_ROM_ADDR_BITS - 1 downto 0),
            b_data_o => rom_b_data
         ); -- i_rom

   end generate gen_rom;

   gen_no_rom : if G_ROM_FILE = "" generate

      rom_a_data <= (others => '0');
      rom_b_data <= (others => '0');

   end generate gen_no_rom;

   -- The screen, at 0xFFFF0000. It is memory, as in the emulator, so the link
   -- can read what a program wrote there. Without it the address would
   -- land at word 0 of the main memory.
   i_scr : entity work.ram
      generic map (
         G_ADDR_BITS => C_SCR_BITS
      )
      port map (
         clk_i     => clk_i,
         a_addr_i  => ibus_addr_i(C_SCR_BITS - 2 downto 0),
         a_data_o  => scr_a_data,
         b_addr_i  => scr_b_addr,
         b_we_i    => (others => scr_b_we),
         b_wdata_i => ram_b_wdata,
         b_rdata_o => scr_b_rdata
      ); -- i_scr


   ---------------------------------------------------------------------------
   -- The properties of formal/mem.sby. The memories themselves are
   -- src/ram.vhd and src/rom.vhd; these check what reaches their ports and
   -- what is taken from them. formal/formal_mem.vhd checks the words read
   -- against a model of one word of the RAM and one of the screen.
   ---------------------------------------------------------------------------

   gen_formal : if G_FORMAL generate
      -- The memory of port B's address, and of port A's pair
      signal f_mem   : t_mem;
      signal f_imem  : t_mem;
      signal f_ifull : std_logic;
      -- The last cycle of a clear
      signal f_last : std_logic;
   begin

      f_mem   <= mem_of(b_word, rom_hidden_i);
      f_imem  <= mem_of(ibus_word, rom_hidden_i);
      f_ifull <= and(ibus_word(31 downto 8));
      f_last  <= clearing and and(clr_addr);

      -- psl default clock is rising_edge(clk_i);

      -- A write reaches the memory of its address, at the word that its
      -- window reaches, in the bytes of its window, and no other; a write
      -- to the ROM while it is shown reaches none. Nothing but the clear
      -- writes the RAM under the shown ROM. formal_mem.vhd checks the
      -- windows' bytes against a model of its own.
      -- psl f_we_ram : assert always
      --    clearing = '0' ->
      --    (ram_b_we /= 0) = (stb_i = '1' and we_i = '1' and f_mem = MEM_RAM) and
      --    (ram_b_we = 0 or ram_b_we = lanes_of(b_win, addr_i(1 downto 0))) and
      --    ram_b_addr = b_word(G_RAM_ADDR_BITS - 1 downto 0) and
      --    ram_b_wdata = lane_data(b_win, wdata_i);
      -- psl f_we_scr : assert always
      --    clearing = '0' ->
      --    (scr_b_we = '1') = (stb_i = '1' and we_i = '1' and f_mem = MEM_SCR) and
      --    scr_b_addr = addr_i(C_SCR_BITS - 1 downto 0);
      -- psl f_rom_we : assert always
      --    clearing = '0' and ram_b_we /= 0 ->
      --    rom_hidden_i = '1' or or(ram_b_addr(G_RAM_ADDR_BITS - 1 downto G_ROM_ADDR_BITS)) = '1';

      -- The clear writes 0 to both memories at clr_addr, which counts from
      -- 0 through every address, and then ends, with clear_done_o for a
      -- cycle. It starts only with clear_i.
      -- psl f_clr_we : assert always
      --    clearing = '1' ->
      --    ram_b_we = "1111" and scr_b_we = '1' and ram_b_wdata = 0 and
      --    ram_b_addr = clr_addr(G_RAM_ADDR_BITS - 1 downto 0) and
      --    scr_b_addr = clr_addr(C_SCR_BITS - 1 downto 0);
      -- psl f_clr_start : assert always
      --    {clear_i and not clearing and not rst_i} |=> {clearing = '1' and clr_addr = 0};
      -- psl f_clr_step : assert always
      --    {clearing and not f_last and not rst_i} |=>
      --    {clearing = '1' and clr_addr = prev(clr_addr) + 1};
      -- psl f_clr_end : assert always
      --    {f_last and not rst_i} |=> {not clearing and clr_done};
      -- psl f_clr_idle : assert always
      --    {(not clearing and not clear_i) or rst_i} |=> {not clearing};
      -- psl f_clr_once : assert always
      --    {not f_last or rst_i} |=> {not clr_done};

      -- A read returns the word of the memory of its address, which the
      -- memory reads at the address of f_we_ram and f_we_scr, and its byte
      -- or halfword through a window on rdata_win_o.
      -- psl f_read : assert always
      --    {stb_i = '1' and we_i = '0'} |=>
      --    {rd_win = prev(b_win) and rd_lane = prev(addr_i(1 downto 0)) and
      --     rdata_o = rd_word and rdata_win_o = win_read(rd_win, rd_lane, rd_word) and
      --     ((prev(f_mem) = MEM_RAM and rd_word = ram_b_rdata) or
      --      (prev(f_mem) = MEM_ROM and rd_word = rom_b_data) or
      --      (prev(f_mem) = MEM_SCR and rd_word = scr_b_rdata))};

      -- Each fetch is acknowledged once, in the next cycle, unless the core
      -- is reset or drops CYC, and its pair is read from the memory of its
      -- address, or is 0 in the I/O page.
      -- psl f_fetch_ack : assert always
      --    {ibus_cyc_i and ibus_stb_i and not core_rst_i and not rst_i} |=>
      --    {ibus_ack_o = ibus_cyc_i};
      -- psl f_fetch_once : assert always
      --    {not (ibus_cyc_i and ibus_stb_i) or core_rst_i or rst_i} |=> {not ibus_ack_o};
      -- psl f_fetch_cyc : assert always ibus_ack_o = '1' -> ibus_cyc_i = '1';
      -- psl f_fetch : assert always
      --    {true} |=>
      --    {(prev(f_ifull) = '1' and ibus_data_o = 0) or
      --     (prev(f_ifull) = '0' and
      --      ((prev(f_imem) = MEM_RAM and ibus_data_o = ram_a_data) or
      --       (prev(f_imem) = MEM_ROM and ibus_data_o = rom_a_data) or
      --       (prev(f_imem) = MEM_SCR and ibus_data_o = scr_a_data)))};

      -- The display hears of each write to the screen, a cycle late.
      -- psl f_scr_out : assert always
      --    {true} |=>
      --    {scr_we_o = prev(scr_b_we) and scr_addr_o = prev(scr_b_addr) and
      --     scr_data_o = prev(ram_b_wdata)};

      -- psl c_clear : cover {clear_i and not rst_i; clearing[*]; clr_done};
      -- psl c_win_write : cover
      --    {stb_i = '1' and we_i = '1' and rst_i = '0' and b_win = WIN_BYTE and
      --     addr_i(1 downto 0) = "10" and f_mem = MEM_RAM};
      -- psl c_win_read : cover
      --    {stb_i = '1' and we_i = '0' and rst_i = '0' and b_win = WIN_SHALF and f_mem = MEM_RAM; true};
      -- psl c_rom_read : cover
      --    {stb_i = '1' and we_i = '0' and rst_i = '0' and f_mem = MEM_ROM; true};
      -- psl c_rom_write : cover {stb_i = '1' and we_i = '1' and rst_i = '0' and f_mem = MEM_ROM};
      -- psl c_rom_fetch : cover
      --    {ibus_cyc_i = '1' and ibus_stb_i = '1' and rst_i = '0' and f_imem = MEM_ROM; ibus_ack_o = '1'};
      -- psl c_scr_write : cover
      --    {stb_i = '1' and we_i = '1' and rst_i = '0' and f_mem = MEM_SCR; scr_we_o = '1'};
      -- psl c_scr_fetch : cover
      --    {ibus_cyc_i = '1' and ibus_stb_i = '1' and rst_i = '0' and f_imem = MEM_SCR and
      --     f_ifull = '0'; ibus_ack_o = '1'};
      -- psl c_io_fetch : cover {ibus_cyc_i and ibus_stb_i and not rst_i and f_ifull; ibus_ack_o};
   end generate gen_formal;

end architecture synthesis;
