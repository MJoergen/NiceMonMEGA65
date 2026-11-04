-- The SD card controller of nice_cpu's SYSTEM.md §5 at 0xFFFFFFA0-AF
-- (#55): the registers and the buffer of nice_cpu/hdl/src/sd_regs.vhd, the
-- protocol engine in SPI mode (sd_spi.vhd), and the slots' pins (#56).
--
-- THEORY OF OPERATION
-- One engine serves the G_SLOTS slots. Each command goes to the slot that
-- was selected when it started, which sd_regs holds on slot_o, and the
-- pins of that slot follow the engine. The other slot rests, with its
-- clock low and chip select and CMD high, so that its card sees nothing.
-- In SPI mode CLK is the card's clock, CMD the data to it, DAT3 its chip
-- select, and DAT0 the data from it. DAT1 and DAT2 are not driven, as the
-- R3's back slot needs (#56).
--
-- With G_POWER, slot 0's power is switched (the Nexys4DDR's SD_RESET):
-- it is off after reset, and an Init turns it off and on again. While it
-- is off, every line of the slot is low, so that no line powers the card.
--
-- Card detect is low with a card in. It is debounced: a change counts
-- once it has held for 10 ms, but after reset the slot shows at once what
-- the pin says, so that a card that is in is there for the first command.
-- Write protect is high when the card's switch is set. A slot whose bit
-- of G_DETECT is '0' has neither, as slot 1 of the MEGA65 R3 (#56): it
-- shows a card at all times, and never write-protected.
--
-- The outputs are registered, and the inputs pass through two registers,
-- the first of each in the I/O tile (IOB TRUE in the board's XDC), as
-- sd_spi_byte.vhd counts on.
--
-- sd_regs is reset with dev_rst_i, which a start of the core gives the
-- devices as well (src/devices.vhd); it lets a Write that runs finish,
-- and abandons any other command. The engine, the pins, and card detect
-- are reset only with the system, by rst_i.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) The Wishbone requests are those of sd_regs.
-- b) dev_rst_i is high whenever rst_i is.
--
-- RESET
-- Synchronous, by rst_i and by dev_rst_i as described above.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity sd is
   generic (
      G_CLOCK_HZ : positive;
      -- The slots, 1 or 2; bit i of G_DETECT is '1' when slot i has card
      -- detect and write protect; G_POWER when slot 0's power is switched
      G_SLOTS    : positive range 1 to 2         := 2;
      G_DETECT   : std_logic_vector(1 downto 0) := "11";
      G_POWER    : boolean                      := false;
      -- Hold the ACK of a write that starts a command until it ends, as
      -- in the simulation of nice_cpu (sd_regs.vhd)
      G_HOLD_ACK : boolean                      := false;
      -- The clock of the card during the start-up, and after it
      G_SLOW_HZ  : positive                     := 400_000;
      G_FAST_HZ  : positive                     := 25_000_000
   );
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;
      dev_rst_i  : in  std_logic;

      wb_cyc_i   : in  std_logic;
      wb_stb_i   : in  std_logic;
      wb_stall_o : out std_logic;
      wb_ack_o   : out std_logic;
      wb_we_i    : in  std_logic;
      wb_addr_i  : in  std_logic_vector(3 downto 0);
      wb_data_i  : in  std_logic_vector(31 downto 0);
      wb_data_o  : out std_logic_vector(31 downto 0);

      -- High while a command runs
      busy_o     : out std_logic;

      -- The slots' pins, bit i for slot i, and slot 0's power, on while low
      sd_clk_o   : out std_logic_vector(1 downto 0);
      sd_cmd_o   : out std_logic_vector(1 downto 0);
      sd_dat3_o  : out std_logic_vector(1 downto 0);
      sd_dat0_i  : in  std_logic_vector(1 downto 0);
      sd_cd_n_i  : in  std_logic_vector(1 downto 0);
      sd_wp_i    : in  std_logic_vector(1 downto 0);
      sd_pwr_n_o : out std_logic
   );
end entity sd;

architecture synthesis of sd is

   constant C_DEBOUNCE : positive := G_CLOCK_HZ / 100;

   -- The inputs: the registers in the I/O tiles, and the second ones
   signal dat0_r1 : std_logic_vector(1 downto 0) := (others => '1');
   signal dat0_r2 : std_logic_vector(1 downto 0) := (others => '1');
   signal cd_n_r1 : std_logic_vector(1 downto 0) := (others => '1');
   signal cd_n_r2 : std_logic_vector(1 downto 0) := (others => '1');
   signal wp_r1   : std_logic_vector(1 downto 0) := (others => '0');
   signal wp_r2   : std_logic_vector(1 downto 0) := (others => '0');
   attribute async_reg : string;
   attribute async_reg of dat0_r1 : signal is "TRUE";
   attribute async_reg of dat0_r2 : signal is "TRUE";
   attribute async_reg of cd_n_r1 : signal is "TRUE";
   attribute async_reg of cd_n_r2 : signal is "TRUE";
   attribute async_reg of wp_r1   : signal is "TRUE";
   attribute async_reg of wp_r2   : signal is "TRUE";

   -- Card detect, debounced
   type   t_count is array (0 to 1) of natural range 0 to C_DEBOUNCE;
   signal cd_cnt_r : t_count                      := (others => 0);
   signal card_r   : std_logic_vector(1 downto 0) := (others => '0');

   signal present : std_logic_vector(G_SLOTS - 1 downto 0);
   signal wp      : std_logic_vector(G_SLOTS - 1 downto 0);

   -- The outputs, in the I/O tiles
   signal clk_r  : std_logic_vector(1 downto 0) := (others => '0');
   signal cmd_r  : std_logic_vector(1 downto 0) := (others => '1');
   signal dat3_r : std_logic_vector(1 downto 0) := (others => '1');
   signal pwr_r  : std_logic                    := '1';

   -- The engine's port of sd_regs
   signal start    : std_logic;
   signal abort    : std_logic;
   signal cmd      : std_logic_vector(1 downto 0);
   signal slot     : std_logic_vector(3 downto 0);
   signal lba      : std_logic_vector(31 downto 0);
   signal done     : std_logic;
   signal err      : std_logic_vector(3 downto 0);
   signal last     : std_logic_vector(31 downto 0);
   signal typ      : std_logic_vector(1 downto 0);
   signal buf_addr : std_logic_vector(8 downto 0);
   signal buf_we   : std_logic;
   signal buf_wr   : std_logic_vector(7 downto 0);
   signal buf_rd   : std_logic_vector(7 downto 0);

   -- The engine's lines, and the slot they go to
   signal eng_cs_n  : std_logic;
   signal eng_pwr_n : std_logic;
   signal eng_sclk  : std_logic;
   signal eng_mosi  : std_logic;
   signal eng_miso  : std_logic;
   signal eng_slot  : natural range 0 to 1;

begin

   p_inputs : process (clk_i)
   begin
      if rising_edge(clk_i) then
         dat0_r1 <= sd_dat0_i;
         dat0_r2 <= dat0_r1;
         cd_n_r1 <= sd_cd_n_i;
         cd_n_r2 <= cd_n_r1;
         wp_r1   <= sd_wp_i;
         wp_r2   <= wp_r1;

         for i in 0 to 1 loop
            if card_r(i) = cd_n_r2(i) then
               -- The pin differs from the card's state.
               if cd_cnt_r(i) = C_DEBOUNCE then
                  card_r(i)   <= not cd_n_r2(i);
                  cd_cnt_r(i) <= 0;
               else
                  cd_cnt_r(i) <= cd_cnt_r(i) + 1;
               end if;
            else
               cd_cnt_r(i) <= 0;
            end if;
         end loop;

         if rst_i = '1' then
            card_r   <= not cd_n_r2;
            cd_cnt_r <= (others => 0);
         end if;
      end if;
   end process p_inputs;

   gen_slots : for i in 0 to G_SLOTS - 1 generate
      present(i) <= card_r(i) when G_DETECT(i) = '1' else
                    '1';
      wp(i)      <= wp_r2(i) when G_DETECT(i) = '1' else
                    '0';
   end generate gen_slots;


   i_sd_regs : entity work.sd_regs
      generic map (
         G_SLOTS    => G_SLOTS,
         G_HOLD_ACK => G_HOLD_ACK
      )
      port map (
         clk_i      => clk_i,
         rst_i      => dev_rst_i,
         wb_cyc_i   => wb_cyc_i,
         wb_stb_i   => wb_stb_i,
         wb_stall_o => wb_stall_o,
         wb_ack_o   => wb_ack_o,
         wb_we_i    => wb_we_i,
         wb_addr_i  => wb_addr_i,
         wb_data_i  => wb_data_i,
         wb_data_o  => wb_data_o,
         present_i  => present,
         wp_i       => wp,
         busy_o     => busy_o,
         start_o    => start,
         abort_o    => abort,
         cmd_o      => cmd,
         slot_o     => slot,
         lba_o      => lba,
         done_i     => done,
         error_i    => err,
         last_i     => last,
         type_i     => typ,
         buf_addr_i => buf_addr,
         buf_we_i   => buf_we,
         buf_data_i => buf_wr,
         buf_data_o => buf_rd
      ); -- i_sd_regs


   i_sd_spi : entity work.sd_spi
      generic map (
         G_CLOCK_HZ => G_CLOCK_HZ,
         G_SLOW_HZ  => G_SLOW_HZ,
         G_FAST_HZ  => G_FAST_HZ,
         G_POWER    => G_POWER
      )
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         start_i    => start,
         abort_i    => abort,
         cmd_i      => cmd,
         lba_i      => lba,
         done_o     => done,
         error_o    => err,
         last_o     => last,
         type_o     => typ,
         buf_addr_o => buf_addr,
         buf_we_o   => buf_we,
         buf_data_o => buf_wr,
         buf_data_i => buf_rd,
         cs_n_o     => eng_cs_n,
         pwr_n_o    => eng_pwr_n,
         sclk_o     => eng_sclk,
         mosi_o     => eng_mosi,
         miso_i     => eng_miso
      ); -- i_sd_spi


   -- The slot of the command, which sd_regs holds after it, too. A slot at
   -- or above G_SLOTS never reaches the engine.
   eng_slot <= 1 when G_SLOTS = 2 and slot(0) = '1' else
               0;
   eng_miso <= dat0_r2(eng_slot);

   p_outputs : process (clk_i)
   begin
      if rising_edge(clk_i) then
         for i in 0 to 1 loop
            if i = eng_slot then
               clk_r(i)  <= eng_sclk;
               cmd_r(i)  <= eng_mosi;
               dat3_r(i) <= eng_cs_n;
            else
               clk_r(i)  <= '0';
               cmd_r(i)  <= '1';
               dat3_r(i) <= '1';
            end if;
         end loop;

         -- Slot 0's lines are low while its power is off.
         if G_POWER then
            pwr_r <= eng_pwr_n;
            if eng_pwr_n = '1' then
               clk_r(0)  <= '0';
               cmd_r(0)  <= '0';
               dat3_r(0) <= '0';
            end if;
         else
            pwr_r <= '0';
         end if;
      end if;
   end process p_outputs;

   sd_clk_o   <= clk_r;
   sd_cmd_o   <= cmd_r;
   sd_dat3_o  <= dat3_r;
   sd_pwr_n_o <= pwr_r;

end architecture synthesis;
