-- nice_core for formal/nicemon.sby: a free core that may do anything that
-- either of nice_cpu's cores may do on its ports. The checks of nicemon.vhd
-- are about the system around the core, and nice_cpu's own formal checks
-- prove the cores, so the system is checked against every core at once, and
-- the solver needs no state of a real core to reach a bus pattern.
--
-- THEORY OF OPERATION
-- Every output is free in every cycle (anyseq), and the assumptions keep it
-- to what nice_cpu's formal/wb_master_check.vhd and handshake_check.vhd
-- assert of a core:
-- - On each bus, STB only while CYC, a stalled request is held, CYC stays
--   high while a request waits for its ACK, at most 8 requests wait on the
--   instruction bus and 4 on the data bus (formal_pipeline.vhd), and reset
--   drops CYC and STB.
-- - READY of an interrupt port only for a request, and not in reset.
-- - halted_o is low after reset, and once high, stays high until reset,
--   which both cores do by their state machines. It is high only while no
--   bus cycle is open, and halt_reason_o is HALT_NONE while it is low and
--   holds its value while it is high.
-- - paused_o is high only while no bus cycle is open, and low after reset.
--   It is high only in the cycle after one with pause_i high, but for a
--   pause of the core's own at a breakpoint (DEBUG.md §6), which may rise
--   while a breakpoint was enabled the cycle before, and lasts until
--   pause_i has been high (the cores' contract f). Once high, it stays
--   high while pause_i is high, until reset.
-- The step report, retire_o, regs_o, instret_o, and stats_o are free.
--
-- Two of the assumptions matter most here, and nice_cpu proves both for
-- every cycle: in multicycle.sby, and for the pipelined core in
-- pipe_dbus.sby and pipe_fetch.sby, whose stop_i is the halt of
-- pipeline.vhd.
-- - CYC stays high in the cycle after a request is accepted
--   (f_cyc_accept of wb_master_check.vhd). Otherwise the system's
--   registered ACK would come with CYC low.
-- - While halted_o is high, no bus cycle is open, and none opens until
--   reset (the quiet state of formal_pipeline.vhd and
--   formal_multicycle.vhd). So the link's accesses, which start once the
--   core has halted, meet no request of the core and no ACK owed to it. A
--   hold of a running core resets it with a fetch in flight, whose ACK
--   nicemon.vhd drops, as it comes with CYC low.
--
-- RESET
-- rst_i is the core's reset. A request waits no longer after it.

library ieee;
   use ieee.std_logic_1164.all;

architecture formal of nice_core is

   constant C_IBUS_MAX : natural := 8;
   constant C_DBUS_MAX : natural := 4;

   signal ibus_cyc  : std_logic;
   signal ibus_stb  : std_logic;
   signal ibus_addr : std_logic_vector(30 downto 0);
   signal dbus_cyc  : std_logic;
   signal dbus_stb  : std_logic;
   signal dbus_we   : std_logic;
   signal dbus_addr : std_logic_vector(31 downto 0);
   signal dbus_data : std_logic_vector(31 downto 0);
   signal nmi_ready : std_logic;
   signal irq_ready : std_logic;
   signal paused    : std_logic;
   signal halted    : std_logic;
   signal reason    : std_logic_vector(2 downto 0);
   signal instret   : std_logic;
   signal retire    : t_retire;
   signal stats     : t_fetch_events;
   signal regs      : t_regs;

   -- The pause of the core's own, as formal_debug_link.vhd has it: whether
   -- a breakpoint is enabled, paused_o and pause_i the cycle before, and
   -- whether a pause of the core's own still waits for pause_i. The
   -- assumptions are plain Booleans on the *_d signals, as there.
   signal brk_any  : std_logic;
   signal paused_d : std_logic := '0';
   signal pause_d  : std_logic := '0';
   signal own_wait : std_logic;
   signal wait_r   : std_logic := '0';
   signal keep_d   : std_logic := '0';
   signal allow_d  : std_logic := '0';

   attribute anyseq : boolean;
   attribute anyseq of ibus_cyc  : signal is true;
   attribute anyseq of ibus_stb  : signal is true;
   attribute anyseq of ibus_addr : signal is true;
   attribute anyseq of dbus_cyc  : signal is true;
   attribute anyseq of dbus_stb  : signal is true;
   attribute anyseq of dbus_we   : signal is true;
   attribute anyseq of dbus_addr : signal is true;
   attribute anyseq of dbus_data : signal is true;
   attribute anyseq of nmi_ready : signal is true;
   attribute anyseq of irq_ready : signal is true;
   attribute anyseq of paused    : signal is true;
   attribute anyseq of halted    : signal is true;
   attribute anyseq of reason    : signal is true;
   attribute anyseq of instret   : signal is true;
   attribute anyseq of retire    : signal is true;
   attribute anyseq of stats     : signal is true;
   attribute anyseq of regs      : signal is true;

   -- The requests that wait for their ACK on each bus
   signal ibus_wait   : natural range 0 to C_IBUS_MAX + 1 := 0;
   signal dbus_wait   : natural range 0 to C_DBUS_MAX + 1 := 0;
   signal ibus_accept : std_logic;
   signal dbus_accept : std_logic;
   signal ibus_waits  : std_logic;
   signal dbus_waits  : std_logic;

begin

   ibus_cyc_o  <= ibus_cyc;
   ibus_stb_o  <= ibus_stb;
   ibus_addr_o <= ibus_addr;
   dbus_cyc_o  <= dbus_cyc;
   dbus_stb_o  <= dbus_stb;
   dbus_we_o   <= dbus_we;
   dbus_addr_o <= dbus_addr;
   dbus_data_o <= dbus_data;
   nmi_ready_o <= nmi_ready;
   irq_ready_o <= irq_ready;
   paused_o    <= paused;
   halted_o    <= halted;
   retire_o    <= retire;
   instret_o   <= instret;
   regs_o      <= regs;
   stats_o     <= stats;

   p_reason : process (all)
   begin
      case reason is
         when "000"  => halt_reason_o <= HALT_NONE;
         when "001"  => halt_reason_o <= HALT_HALT;
         when "010"  => halt_reason_o <= HALT_RESERVED;
         when "011"  => halt_reason_o <= HALT_NESTED_INT;
         when others => halt_reason_o <= HALT_RTI_OUTSIDE_ISR;
      end case;
   end process p_reason;

   ibus_accept <= ibus_cyc and ibus_stb and not ibus_stall_i;
   dbus_accept <= dbus_cyc and dbus_stb and not dbus_stall_i;
   ibus_waits  <= '1' when ibus_wait /= 0 else '0';
   dbus_waits  <= '1' when dbus_wait /= 0 else '0';

   p_wait : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if ibus_cyc = '0' then
            ibus_wait <= 0;
         elsif ibus_accept = '1' and ibus_ack_i = '0' then
            if ibus_wait <= C_IBUS_MAX then
               ibus_wait <= ibus_wait + 1;
            end if;
         elsif ibus_accept = '0' and ibus_ack_i = '1' and ibus_wait /= 0 then
            ibus_wait <= ibus_wait - 1;
         end if;

         if dbus_cyc = '0' then
            dbus_wait <= 0;
         elsif dbus_accept = '1' and dbus_ack_i = '0' then
            if dbus_wait <= C_DBUS_MAX then
               dbus_wait <= dbus_wait + 1;
            end if;
         elsif dbus_accept = '0' and dbus_ack_i = '1' and dbus_wait /= 0 then
            dbus_wait <= dbus_wait - 1;
         end if;

         if rst_i = '1' then
            ibus_wait <= 0;
            dbus_wait <= 0;
         end if;
      end if;
   end process p_wait;

   brk_any  <= '1' when G_BREAKS > 0 and
                        brk_en_i(G_BREAKS - 1 downto 0) /= (G_BREAKS - 1 downto 0 => '0') else
               '0';
   own_wait <= not pause_i and (wait_r or (paused and not paused_d and not pause_d));

   p_pause : process (clk_i)
   begin
      if rising_edge(clk_i) then
         paused_d <= paused and not rst_i;
         pause_d  <= pause_i and not rst_i;
         wait_r   <= own_wait and not rst_i;
         keep_d   <= paused and (pause_i or own_wait) and not rst_i;
         allow_d  <= (pause_i or own_wait or (brk_any and not paused)) and not rst_i;
      end if;
   end process p_pause;

   -- psl default clock is rising_edge(clk_i);

   -- The instruction bus
   -- psl f_ibus_stb_cyc : assume always ibus_stb -> ibus_cyc;
   -- psl f_ibus_stall_hold : assume always
   --    {ibus_cyc and ibus_stb and ibus_stall_i and not rst_i} |=>
   --    {rst_i = '1' or (ibus_stb = '1' and stable(ibus_addr))};
   -- psl f_ibus_cyc_hold : assume always
   --    {ibus_waits and not ibus_ack_i and not rst_i} |=> {ibus_cyc};
   -- psl f_ibus_cyc_accept : assume always
   --    {ibus_accept and not rst_i} |=> {ibus_cyc or rst_i};
   -- psl f_ibus_max : assume always ibus_wait <= C_IBUS_MAX;
   -- psl f_ibus_reset : assume always {rst_i} |=> {not ibus_cyc and not ibus_stb};

   -- The data bus
   -- psl f_dbus_stb_cyc : assume always dbus_stb -> dbus_cyc;
   -- psl f_dbus_stall_hold : assume always
   --    {dbus_cyc and dbus_stb and dbus_stall_i and not rst_i} |=>
   --    {rst_i = '1' or
   --     (dbus_stb = '1' and stable(dbus_we) and stable(dbus_addr) and stable(dbus_data))};
   -- psl f_dbus_cyc_hold : assume always
   --    {dbus_waits and not dbus_ack_i and not rst_i} |=> {dbus_cyc};
   -- psl f_dbus_cyc_accept : assume always
   --    {dbus_accept and not rst_i} |=> {dbus_cyc or rst_i};
   -- psl f_dbus_max : assume always dbus_wait <= C_DBUS_MAX;
   -- psl f_dbus_reset : assume always {rst_i} |=> {not dbus_cyc and not dbus_stb};

   -- The interrupt ports
   -- psl f_nmi_ready : assume always nmi_ready -> nmi_valid_i and not rst_i;
   -- psl f_irq_ready : assume always irq_ready -> irq_valid_i and not rst_i;

   -- The halt
   -- psl f_halt_reset : assume always {rst_i} |=> {not halted};
   -- psl f_halt_hold : assume always {halted and not rst_i} |=> {halted or rst_i};
   -- psl f_halt_idle : assume always halted -> not ibus_cyc and not dbus_cyc;
   -- psl f_halt_none : assume always not halted -> reason = "000";
   -- psl f_halt_stable : assume always
   --    {halted and not rst_i} |=> {rst_i = '1' or stable(reason)};

   -- The pause
   -- psl f_pause_idle : assume always paused -> not ibus_cyc and not dbus_cyc;
   -- psl f_pause_req : assume always paused -> allow_d;
   -- psl f_pause_reset : assume always {rst_i} |=> {not paused};
   -- psl f_pause_hold : assume always keep_d = '1' and rst_i = '0' -> paused = '1';

end architecture formal;
