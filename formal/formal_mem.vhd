-- The memory of the NiceMon system (src/mem.vhd), with its properties, for
-- SymbiYosys. The inputs are free but for what nicemon promises: a clear
-- starts only while none runs or ends, and meets no request (f_clr_alone
-- of src/nicemon.vhd), and no request is taken while the memory is
-- cleared. The RAM has 16 words, the ROM 4, formal/rom.bin, and the screen
-- 8, so that a clear takes 16 cycles; the properties do not depend on the
-- sizes. The RAM starts with any words, as in formal/nicemon.sby.
--
-- With G_MODEL, it also checks the words read against a model: one word of
-- the RAM and one of the screen, each at an address that the solver picks,
-- and the words of rom.bin. A read of a model's word returns the word last
-- written there, or 0 after a clear, through port B and port A alike, a
-- read of the ROM while it is shown returns the ROM's word, a fetch in
-- the I/O page returns 0, and a clear ends in 16 cycles. k-induction
-- cannot relate the model's words to the memory's, so "model" proves these
-- with PDR instead.
--
-- RESET
-- The first cycle is a reset.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity formal_mem is
   generic (
      G_MODEL : boolean := false
   );
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;
      rom_hidden_i : in  std_logic;
      core_rst_i   : in  std_logic;
      ibus_cyc_i   : in  std_logic;
      ibus_stb_i   : in  std_logic;
      ibus_addr_i  : in  std_logic_vector(30 downto 0);
      stb_i        : in  std_logic;
      we_i         : in  std_logic;
      addr_i       : in  std_logic_vector(31 downto 0);
      wdata_i      : in  std_logic_vector(31 downto 0);
      clear_i      : in  std_logic
   );
end entity formal_mem;

architecture synthesis of formal_mem is

   constant C_RAM_BITS : natural := 4;
   constant C_SCR_BITS : natural := 3;
   constant C_ROM_BITS : natural := 2;

   signal ibus_data  : std_logic_vector(63 downto 0);
   signal rdata      : std_logic_vector(31 downto 0);
   signal clearing   : std_logic;
   signal clear_done : std_logic;

begin

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;

   -- psl f_clear_req : assume always
   --    clear_i = '1' -> clearing = '0' and clear_done = '0' and stb_i = '0';
   -- psl f_req : assume always stb_i = '1' -> clearing = '0';


   i_mem : entity work.mem
      generic map (
         G_RAM_ADDR_BITS => C_RAM_BITS,
         G_SCR_ADDR_BITS => C_SCR_BITS,
         G_ROM_FILE      => "rom.bin",
         G_ROM_ADDR_BITS => C_ROM_BITS,
         G_FORMAL        => true
      )
      port map (
         clk_i        => clk_i,
         rst_i        => rst_i,
         rom_hidden_i => rom_hidden_i,
         core_rst_i   => core_rst_i,
         ibus_cyc_i   => ibus_cyc_i,
         ibus_stb_i   => ibus_stb_i,
         ibus_addr_i  => ibus_addr_i,
         ibus_ack_o   => open,
         ibus_data_o  => ibus_data,
         stb_i        => stb_i,
         we_i         => we_i,
         addr_i       => addr_i,
         wdata_i      => wdata_i,
         rdata_o      => rdata,
         clear_i      => clear_i,
         clearing_o   => clearing,
         clear_done_o => clear_done,
         scr_we_o     => open,
         scr_addr_o   => open,
         scr_data_o   => open
      ); -- i_mem

   gen_model : if G_MODEL generate

      -- The words of rom.bin
      type     t_rom is array (0 to 2 ** C_ROM_BITS - 1) of std_logic_vector(31 downto 0);
      constant C_ROM : t_rom := (X"A0000001", X"B0000002", X"C0000003", X"D0000004");

      -- Where an address lands, decided here apart from mem.vhd
      type t_where is (W_RAM, W_ROM, W_SCR);

      function where(addr : std_logic_vector(31 downto 0); hidden : std_logic) return t_where is
      begin
         if addr(31 downto 16) = X"FFFF" and addr(15 downto C_SCR_BITS) = 0 then
            return W_SCR;
         elsif hidden = '0' and addr(C_RAM_BITS - 1 downto C_ROM_BITS) = 0 then
            return W_ROM;
         end if;
         return W_RAM;
      end function where;

      -- The model's addresses, which the solver picks, their words, and
      -- whether those are known: after a write, or a clear
      signal f_ram_addr : std_logic_vector(C_RAM_BITS - 1 downto 0);
      signal f_scr_addr : std_logic_vector(C_SCR_BITS - 1 downto 0);
      signal f_ram_word : std_logic_vector(31 downto 0);
      signal f_scr_word : std_logic_vector(31 downto 0);
      signal f_ram_ok   : std_logic := '0';
      signal f_scr_ok   : std_logic := '0';

      attribute anyconst : boolean;
      attribute anyconst of f_ram_addr : signal is true;
      attribute anyconst of f_scr_addr : signal is true;

      -- The word that port B must return in this cycle, and that port A
      -- must return in the low or the high half of its pair, when known
      signal f_b_chk  : std_logic := '0';
      signal f_b_word : std_logic_vector(31 downto 0);
      signal f_a_chk  : std_logic := '0';
      signal f_a_high : std_logic;
      signal f_a_word : std_logic_vector(31 downto 0);
      -- A fetch of the ROM, or of the I/O page
      signal f_a_rom  : std_logic := '0';
      signal f_a_pair : std_logic_vector(63 downto 0);
      signal f_a_io   : std_logic := '0';

      signal f_ibus_word : std_logic_vector(31 downto 0);

      -- The cycles of the clear so far, which ends after 2^C_RAM_BITS
      signal f_clr_len : natural range 0 to 2 ** C_RAM_BITS := 0;
   begin

      f_ibus_word <= ibus_addr_i & '0';

      p_clr_len : process (clk_i)
      begin
         if rising_edge(clk_i) then
            if clearing = '1' and f_clr_len < 2 ** C_RAM_BITS then
               f_clr_len <= f_clr_len + 1;
            elsif clearing = '0' then
               f_clr_len <= 0;
            end if;
         end if;
      end process p_clr_len;

      p_model : process (clk_i)
      begin
         if rising_edge(clk_i) then
            f_b_chk <= '0';
            f_a_chk <= '0';
            f_a_rom <= '0';
            f_a_io  <= '0';

            -- A clear makes the words unknown until it ends, and then 0. A
            -- write in the cycle that it ends comes after it.
            if clear_i = '1' then
               f_ram_ok <= '0';
               f_scr_ok <= '0';
            end if;
            if clear_done = '1' then
               f_ram_word <= (others => '0');
               f_scr_word <= (others => '0');
               f_ram_ok   <= '1';
               f_scr_ok   <= '1';
            end if;

            -- Port B
            if stb_i = '1' then

               case where(addr_i, rom_hidden_i) is
                  when W_RAM =>
                     if addr_i(C_RAM_BITS - 1 downto 0) = f_ram_addr then
                        if we_i = '1' then
                           f_ram_word <= wdata_i;
                           f_ram_ok   <= '1';
                        else
                           f_b_chk  <= f_ram_ok;
                           f_b_word <= f_ram_word;
                        end if;
                     end if;

                  when W_SCR =>
                     if addr_i(C_SCR_BITS - 1 downto 0) = f_scr_addr then
                        if we_i = '1' then
                           f_scr_word <= wdata_i;
                           f_scr_ok   <= '1';
                        else
                           f_b_chk  <= f_scr_ok;
                           f_b_word <= f_scr_word;
                        end if;
                     end if;

                  when W_ROM =>
                     if we_i = '0' then
                        f_b_chk  <= '1';
                        f_b_word <= C_ROM(to_integer(addr_i(C_ROM_BITS - 1 downto 0)));
                     end if;
               end case;

            end if;

            -- Port A, the pair of the word f_ibus_word
            if and(f_ibus_word(31 downto 8)) = '1' then
               f_a_io <= '1';
            else

               case where(f_ibus_word, rom_hidden_i) is
                  when W_RAM =>
                     if f_ibus_word(C_RAM_BITS - 1 downto 1) = f_ram_addr(C_RAM_BITS - 1 downto 1) then
                        f_a_chk  <= f_ram_ok;
                        f_a_high <= f_ram_addr(0);
                        f_a_word <= f_ram_word;
                     end if;

                  when W_SCR =>
                     if f_ibus_word(C_SCR_BITS - 1 downto 1) = f_scr_addr(C_SCR_BITS - 1 downto 1) then
                        f_a_chk  <= f_scr_ok;
                        f_a_high <= f_scr_addr(0);
                        f_a_word <= f_scr_word;
                     end if;

                  when W_ROM =>
                     f_a_rom  <= '1';
                     f_a_pair <= C_ROM(to_integer(f_ibus_word(C_ROM_BITS - 1 downto 1) & '1')) &
                                 C_ROM(to_integer(f_ibus_word(C_ROM_BITS - 1 downto 0)));
               end case;

            end if;
         end if;
      end process p_model;

      -- psl f_model_b : assert always f_b_chk = '1' -> rdata = f_b_word;
      -- psl f_model_a : assert always
      --    f_a_chk = '1' -> (f_a_high = '0' and ibus_data(31 downto 0) = f_a_word) or
      --                     (f_a_high = '1' and ibus_data(63 downto 32) = f_a_word);
      -- psl f_model_rom : assert always f_a_rom = '1' -> ibus_data = f_a_pair;
      -- psl f_model_io : assert always f_a_io = '1' -> ibus_data = 0;
      -- psl f_model_clr : assert always clearing = '1' -> f_clr_len < 2 ** C_RAM_BITS;

      -- psl c_model_clear : cover {clear_done; f_b_chk[->1]};
   end generate gen_model;

end architecture synthesis;
