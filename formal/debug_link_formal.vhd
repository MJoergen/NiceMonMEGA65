-- debug_link for formal/nicemon.sby: a free debug link that may do anything
-- that nice_cpu's hdl/src/debug_link.vhd may do on its ports. The checks of
-- nicemon.vhd are about the system around the link, which nice_cpu proves
-- on its own (nice_cpu/hdl/formal/debug_link.sby proves the contracts in
-- the header of debug_link.vhd that this file assumes), and a real link needs
-- hundreds of cycles of UART bytes for one request, far beyond the depth of
-- the checks. A free one makes a request in any cycle.
--
-- THEORY OF OPERATION
-- Every output is free in every cycle (anyseq), and the assumptions keep it
-- to what the header of debug_link.vhd promises:
-- - The Wishbone master: STB only while CYC, a stalled request is held,
--   CYC stays high until the ACK, one request at a time, and reset drops
--   CYC and STB. It works only while hold_o or halted_i is high, or while
--   pause_o is high and paused_i was high in the cycle before, the link's
--   own flag of a pause, and not while clear_o is high (contracts a and f).
-- - hold_o, rom_hide_o, and pause_o change only while CYC is low, as the
--   link writes them with an access of its own, which uses no bus. Without
--   G_HAS_ROM, rom_hide_o is 1.
-- - A clear: clear_o holds the processor, stays high until clear_done_i,
--   and falls after it (contract f).
-- - con_in_valid_o comes only when free_i was not 0 in the cycle before
--   (contract d).
-- - tx_valid_o stays high with its byte until tx_ready_i takes it.
-- The other outputs are free.
--
-- RESET
-- rst_i is the system's reset. After it, CYC, STB, clear_o, and pause_o are low,
-- hold_o is G_BOOT_HELD, and rom_hide_o shows the ROM, or is 1 without
-- G_HAS_ROM.

library ieee;
   use ieee.std_logic_1164.all;

architecture formal of debug_link is

   signal rx_ready     : std_logic;
   signal tx_valid     : std_logic;
   signal tx_data      : std_logic_vector(7 downto 0);
   signal con_ready    : std_logic;
   signal con_in_valid : std_logic;
   signal con_in_data  : std_logic_vector(7 downto 0);
   signal eoi          : std_logic;
   signal hold         : std_logic;
   signal rom_hide     : std_logic;
   signal clear        : std_logic;
   signal pause        : std_logic;
   signal wb_cyc       : std_logic;
   signal wb_stb       : std_logic;
   signal wb_we        : std_logic;
   signal wb_addr      : std_logic_vector(31 downto 0);
   signal wb_data      : std_logic_vector(31 downto 0);

   attribute anyseq : boolean;
   attribute anyseq of rx_ready     : signal is true;
   attribute anyseq of tx_valid     : signal is true;
   attribute anyseq of tx_data      : signal is true;
   attribute anyseq of con_ready    : signal is true;
   attribute anyseq of con_in_valid : signal is true;
   attribute anyseq of con_in_data  : signal is true;
   attribute anyseq of eoi          : signal is true;
   attribute anyseq of hold         : signal is true;
   attribute anyseq of rom_hide     : signal is true;
   attribute anyseq of clear        : signal is true;
   attribute anyseq of pause        : signal is true;
   attribute anyseq of wb_cyc       : signal is true;
   attribute anyseq of wb_stb       : signal is true;
   attribute anyseq of wb_we        : signal is true;
   attribute anyseq of wb_addr      : signal is true;
   attribute anyseq of wb_data      : signal is true;

   -- The request that waits for its ACK
   signal wb_accept : std_logic;
   signal wb_wait   : std_logic := '0';
   signal boot_held : std_logic;
   signal has_rom   : std_logic;
   -- paused_i in the cycle before, while not held, as the link keeps it
   signal paused_r : std_logic := '0';

begin

   rx_ready_o     <= rx_ready;
   tx_valid_o     <= tx_valid;
   tx_data_o      <= tx_data;
   con_ready_o    <= con_ready;
   con_in_valid_o <= con_in_valid;
   con_in_data_o  <= con_in_data;
   eoi_o          <= eoi;
   hold_o         <= hold;
   rom_hide_o     <= rom_hide;
   clear_o        <= clear;
   pause_o        <= pause;
   wb_cyc_o       <= wb_cyc;
   wb_stb_o       <= wb_stb;
   wb_we_o        <= wb_we;
   wb_addr_o      <= wb_addr;
   wb_data_o      <= wb_data;

   boot_held <= '1' when G_BOOT_HELD else
                '0';
   has_rom   <= '1' when G_HAS_ROM else
                '0';

   wb_accept <= wb_cyc and wb_stb and not wb_stall_i;

   p_wait : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if wb_accept = '1' then
            wb_wait <= '1';
         elsif wb_ack_i = '1' then
            wb_wait <= '0';
         end if;
         paused_r <= paused_i and not hold;
         if rst_i = '1' then
            wb_wait  <= '0';
            paused_r <= '0';
         end if;
      end if;
   end process p_wait;

   -- psl default clock is rising_edge(clk_i);

   -- The Wishbone master
   -- psl f_stb_cyc : assume always wb_stb -> wb_cyc;
   -- psl f_stall_hold : assume always
   --    {wb_cyc and wb_stb and wb_stall_i and not rst_i} |=>
   --    {rst_i = '1' or
   --     (wb_stb = '1' and stable(wb_we) and stable(wb_addr) and stable(wb_data))};
   -- psl f_cyc_hold : assume always
   --    {(wb_accept or wb_wait) and not wb_ack_i and not rst_i} |=> {wb_cyc or rst_i};
   -- psl f_one : assume always wb_wait -> not wb_stb;
   -- psl f_cyc_end : assume always {wb_ack_i and not rst_i} |=> {not wb_stb};
   -- psl f_owns : assume always
   --    wb_cyc -> (hold or halted_i or (pause and paused_r)) and not clear;
   -- psl f_reset : assume always
   --    {rst_i} |=>
   --    {wb_cyc = '0' and wb_stb = '0' and clear = '0' and pause = '0' and
   --     hold = boot_held and rom_hide = not has_rom};

   -- The control register
   -- psl f_hold : assume always
   --    {not rst_i} |=>
   --    {rst_i = '1' or (stable(hold) and stable(rom_hide) and stable(pause)) or
   --     (wb_cyc = '0' and prev(wb_cyc) = '0')};
   -- psl f_rom : assume always has_rom = '0' -> rom_hide = '1';

   -- The clear
   -- psl f_clear_hold : assume always clear -> hold;
   -- psl f_clear_wait : assume always
   --    {clear and not clear_done_i and not rst_i} |=> {clear or rst_i};
   -- psl f_clear_end : assume always {clear_done_i and not rst_i} |=> {not clear or rst_i};

   -- The console
   -- psl f_free : assume always {free_i = X"0000"} |=> {not con_in_valid};
   -- psl f_tx_hold : assume always
   --    {tx_valid and not tx_ready_i and not rst_i} |=>
   --    {rst_i = '1' or (tx_valid = '1' and stable(tx_data))};

end architecture formal;
