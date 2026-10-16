-- Run control for the debug link: it pauses the core, steps it, stops it at
-- breakpoints and watchpoints, and keeps a trace of its last steps. Its
-- registers are the link's at 0xFFFFFFF2-FF (PROTOCOL.md).
--
-- THEORY OF OPERATION
-- The core reports each step on retire_i. After a step, and after reset, the
-- next request on the instruction bus is the fetch of the next instruction
-- word, so at_boundary is set then, and cleared when a fetch is taken. To
-- pause, freeze_o stalls that fetch, so the core waits in its fetch state
-- with every step before it complete, and R15 is the address of the next
-- instruction. freeze_o goes straight to the stall of the instruction bus,
-- in the cycle that the fetch is requested, for a breakpoint is found only
-- by comparing R15 with its address in that cycle.
--
-- A pause waits in pause_req, with its reason, until the next fetch. Before
-- that, the core could enter an interrupt instead of fetching, so irq_mask_o
-- holds off the interrupt request while a pause waits or the core is
-- paused. The core takes the request only in its boundary state, and the
-- device holds it, so it is taken later. A watchpoint sees the data bus
-- request of the core with its address, and asks for a pause after the
-- step. The step counter asks for one when it counts down to 0.
--
-- Going on from a pause sets skip_bp, so that the breakpoint that may have
-- stopped the core does not stop it at the same fetch again. Reset of the
-- core ends a pause, but not a waiting pause request, so that a pause
-- requested while the core is held stops it before its first instruction.
--
-- A halt is a stop too. stopped_o is '1' while the core is paused or
-- halted, and reason_o is why it last stopped: the codes of the "h" notice
-- of PROTOCOL.md, 0x80 plus the halt reason for a halt.
--
-- The trace is a ring buffer of 2^G_TRACE_BITS steps in block RAM, written
-- on each step. It is emptied when the core leaves reset. tr_idx is the
-- step that a read of 0xFFFFFFF5 returns, 0 the oldest, and tr_word which
-- of its three words. The block RAM is read in every cycle at that step
-- into tr_q, so a read has the word in the cycle after the index changed,
-- and the link reads no faster than that.
--
-- The register port is for the system's data bus: reg_addr_i is bits 3..0
-- of the address, from 0x2 for 0xFFFFFFF2, reg_we_i and reg_re_i are '1' for
-- the cycle of a write or a read, and reg_rdata_o is the word read in that
-- cycle.
--
-- RESET
-- Synchronous. It clears the breakpoints, the pause, and the trace.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;
   use ieee.numeric_std.all;

library work;
   use work.trace_pkg.all;

entity run_ctl is
   generic (
      G_TRACE_BITS    : natural := 10;
      G_RAM_ADDR_BITS : natural := 16
   );
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;
      -- The core: its reset, its halted flag, and its steps
      cpu_rst_i   : in  std_logic;
      halted_i    : in  std_logic;
      retire_i    : in  t_retire;
      -- The core's requests
      ibus_cyc_i  : in  std_logic;
      ibus_stb_i  : in  std_logic;
      dbus_cyc_i  : in  std_logic;
      dbus_stb_i  : in  std_logic;
      dbus_we_i   : in  std_logic;
      dbus_addr_i : in  std_logic_vector(31 downto 0);
      -- Stall the instruction fetch, and hold off the interrupt request
      freeze_o    : out std_logic;
      irq_mask_o  : out std_logic;
      -- The core is paused, or paused or halted, and why it last stopped
      paused_o    : out std_logic;
      stopped_o   : out std_logic;
      reason_o    : out std_logic_vector(7 downto 0);
      -- The registers at 0xFFFFFFF2-FF
      reg_addr_i  : in  std_logic_vector(3 downto 0);
      reg_we_i    : in  std_logic;
      reg_re_i    : in  std_logic;
      reg_wdata_i : in  std_logic_vector(31 downto 0);
      reg_rdata_o : out std_logic_vector(31 downto 0)
   );
end entity run_ctl;

architecture synthesis of run_ctl is

   constant C_BREAKPOINTS : natural := 4;
   constant C_VERSION     : natural := 1;
   constant C_TRACE_LEN   : natural := 2 ** G_TRACE_BITS;

   -- The reasons of a stop (PROTOCOL.md)
   constant C_WHY_PAUSE : std_logic_vector(7 downto 0) := X"01";
   constant C_WHY_STEPS : std_logic_vector(7 downto 0) := X"02";
   constant C_WHY_BREAK : std_logic_vector(3 downto 0) := X"1";
   constant C_WHY_READ  : std_logic_vector(3 downto 0) := X"2";
   constant C_WHY_WRITE : std_logic_vector(3 downto 0) := X"3";

   type t_addrs is array (0 to C_BREAKPOINTS - 1) of std_logic_vector(31 downto 0);
   type t_kinds is array (0 to C_BREAKPOINTS - 1) of std_logic_vector(2 downto 0);

   signal bp_addr : t_addrs := (others => (others => '0'));
   signal bp_kind : t_kinds := (others => (others => '0'));

   signal at_boundary : std_logic := '1';
   signal paused      : std_logic := '0';
   signal pause_req   : std_logic := '0';
   signal req_why     : std_logic_vector(7 downto 0);
   signal skip_bp     : std_logic := '0';
   signal steps_left  : std_logic_vector(31 downto 0) := (others => '0');
   signal reason      : std_logic_vector(7 downto 0) := (others => '0');
   signal halted_d    : std_logic := '0';
   signal cpu_rst_d   : std_logic := '1';

   -- The fetch of the next instruction is requested.
   signal fetch : std_logic;
   -- A breakpoint is at that instruction, the first one that is
   signal bp_hit   : std_logic;
   signal bp_which : natural range 0 to C_BREAKPOINTS - 1;
   signal freeze   : std_logic;

   -- The trace: per step the instruction word in bits 31..0, its address in
   -- 63..32, and the flags of PROTOCOL.md: bits 3..0 of the flags word in
   -- 67..64, the vector in 75..68, and the halt reason in 78..76.
   type t_trace is array (0 to C_TRACE_LEN - 1) of std_logic_vector(78 downto 0);

   signal trace    : t_trace;
   signal tr_we    : std_logic;
   signal tr_entry : std_logic_vector(78 downto 0);
   signal tr_wr    : std_logic_vector(G_TRACE_BITS - 1 downto 0) := (others => '0');
   signal tr_count : natural range 0 to C_TRACE_LEN := 0;
   signal tr_idx   : std_logic_vector(G_TRACE_BITS - 1 downto 0) := (others => '0');
   signal tr_word  : natural range 0 to 2 := 0;
   signal tr_rd    : std_logic_vector(G_TRACE_BITS - 1 downto 0);
   signal tr_q     : std_logic_vector(78 downto 0);

begin

   fetch <= at_boundary and ibus_cyc_i and ibus_stb_i;

   p_bp_hit : process (all)
   begin
      bp_hit   <= '0';
      bp_which <= 0;
      for k in C_BREAKPOINTS - 1 downto 0 loop
         if bp_kind(k)(0) = '1' and retire_i.regs(15) = bp_addr(k) then
            bp_hit   <= fetch and not skip_bp;
            bp_which <= k;
         end if;
      end loop;
   end process p_bp_hit;

   freeze     <= at_boundary and (paused or pause_req or bp_hit);
   freeze_o   <= freeze;
   irq_mask_o <= paused or pause_req;
   paused_o   <= paused;
   stopped_o  <= paused or halted_i;
   reason_o   <= reason;

   p_ctl : process (clk_i)
   begin
      if rising_edge(clk_i) then
         halted_d  <= halted_i;
         cpu_rst_d <= cpu_rst_i;

         if retire_i.valid = '1' then
            at_boundary <= '1';
            if steps_left /= 0 then
               steps_left <= steps_left - 1;
               if steps_left = 1 then
                  pause_req <= '1';
                  req_why   <= C_WHY_STEPS;
               end if;
            end if;
         elsif fetch = '1' and freeze = '0' then
            at_boundary <= '0';
            skip_bp     <= '0';
         end if;

         -- A watchpoint: a pause after this step
         for k in 0 to C_BREAKPOINTS - 1 loop
            if dbus_cyc_i = '1' and dbus_stb_i = '1' and dbus_addr_i = bp_addr(k) then
               if dbus_we_i = '0' and bp_kind(k)(1) = '1' then
                  pause_req <= '1';
                  req_why   <= C_WHY_READ & std_logic_vector(to_unsigned(k, 4));
               elsif dbus_we_i = '1' and bp_kind(k)(2) = '1' then
                  pause_req <= '1';
                  req_why   <= C_WHY_WRITE & std_logic_vector(to_unsigned(k, 4));
               end if;
            end if;
         end loop;

         -- The pause happens at the fetch.
         if fetch = '1' and paused = '0' and (pause_req = '1' or bp_hit = '1') then
            paused     <= '1';
            pause_req  <= '0';
            steps_left <= (others => '0');
            if pause_req = '1' then
               reason <= req_why;
            else
               reason <= C_WHY_BREAK & std_logic_vector(to_unsigned(bp_which, 4));
            end if;
         end if;

         if halted_i = '1' and halted_d = '0' then
            reason <= "10000" & std_logic_vector(to_unsigned(t_halt'pos(retire_i.halt), 3));
         end if;

         if reg_we_i = '1' then

            case reg_addr_i is

               when X"2" =>
                  if reg_wdata_i(0) = '1' then
                     pause_req  <= '1';
                     req_why    <= C_WHY_PAUSE;
                     steps_left <= (others => '0');
                  elsif reg_wdata_i(1) = '1' then
                     pause_req  <= '0';
                     steps_left <= (others => '0');
                     paused     <= '0';
                     skip_bp    <= paused;
                  end if;

               when X"3" =>
                  pause_req <= '0';
                  paused    <= '0';
                  skip_bp   <= paused;
                  if reg_wdata_i = 0 then
                     -- No steps: the pause comes at once.
                     pause_req <= '1';
                     req_why   <= C_WHY_STEPS;
                  end if;
                  steps_left <= reg_wdata_i;

               when X"8" | X"9" | X"A" | X"B" =>
                  bp_addr(to_integer(reg_addr_i(1 downto 0))) <= reg_wdata_i;

               when X"C" | X"D" | X"E" | X"F" =>
                  bp_kind(to_integer(reg_addr_i(1 downto 0))) <= reg_wdata_i(2 downto 0);

               when others =>
                  null;

            end case;

         end if;

         if cpu_rst_i = '1' then
            at_boundary <= '1';
            paused      <= '0';
            skip_bp     <= '0';
         end if;

         if rst_i = '1' then
            bp_kind    <= (others => (others => '0'));
            pause_req  <= '0';
            steps_left <= (others => '0');
            reason     <= (others => '0');
         end if;
      end if;
   end process p_ctl;


   ---------------------------------------------------------------------------
   -- The trace
   ---------------------------------------------------------------------------

   tr_we    <= retire_i.valid;
   tr_entry <= std_logic_vector(to_unsigned(t_halt'pos(retire_i.halt), 3)) &
               (retire_i.vector and (7 downto 0  => retire_i.intr)) &
               retire_i.mem_we & retire_i.skipped & retire_i.nmi & retire_i.intr &
               retire_i.addr &
               (retire_i.iw and not (31 downto 0 => retire_i.intr));

   -- Step tr_idx, counted from the oldest of the tr_count steps
   tr_rd <= tr_wr - std_logic_vector(to_unsigned(tr_count mod C_TRACE_LEN, G_TRACE_BITS)) + tr_idx;

   p_trace_ram : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if tr_we = '1' then
            trace(to_integer(tr_wr)) <= tr_entry;
         end if;
         tr_q <= trace(to_integer(tr_rd));
      end if;
   end process p_trace_ram;

   p_trace : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if tr_we = '1' then
            tr_wr <= tr_wr + 1;
            if tr_count < C_TRACE_LEN then
               tr_count <= tr_count + 1;
            end if;
         end if;

         if reg_we_i = '1' and reg_addr_i = X"4" then
            tr_idx  <= reg_wdata_i(G_TRACE_BITS - 1 downto 0);
            tr_word <= 0;
         elsif reg_re_i = '1' and reg_addr_i = X"5" then
            if tr_word = 2 then
               tr_word <= 0;
               tr_idx  <= tr_idx + 1;
            else
               tr_word <= tr_word + 1;
            end if;
         end if;

         -- Emptied when the core starts
         if rst_i = '1' or (cpu_rst_d = '1' and cpu_rst_i = '0') then
            tr_wr    <= (others => '0');
            tr_count <= 0;
         end if;
      end if;
   end process p_trace;


   ---------------------------------------------------------------------------
   -- The registers read
   ---------------------------------------------------------------------------

   p_rdata : process (all)
   begin
      reg_rdata_o <= (others => '0');

      case reg_addr_i is

         when X"2" =>
            reg_rdata_o(0)           <= paused;
            reg_rdata_o(1)           <= pause_req;
            reg_rdata_o(15 downto 8) <= reason;

         when X"3" =>
            reg_rdata_o <= steps_left;

         when X"4" =>
            reg_rdata_o <= std_logic_vector(to_unsigned(tr_count, 32));

         when X"5" =>

            case tr_word is

               when 0 =>
                  reg_rdata_o <= tr_q(63 downto 32);

               when 1 =>
                  reg_rdata_o <= tr_q(31 downto 0);

               when others =>
                  reg_rdata_o(3 downto 0)   <= tr_q(67 downto 64);
                  reg_rdata_o(15 downto 8)  <= tr_q(75 downto 68);
                  reg_rdata_o(18 downto 16) <= tr_q(78 downto 76);

            end case;

         when X"6" =>
            reg_rdata_o(7 downto 0)   <= std_logic_vector(to_unsigned(C_VERSION, 8));
            reg_rdata_o(11 downto 8)  <= std_logic_vector(to_unsigned(C_BREAKPOINTS, 4));
            reg_rdata_o(15 downto 12) <= std_logic_vector(to_unsigned(G_TRACE_BITS, 4));
            reg_rdata_o(20 downto 16) <= std_logic_vector(to_unsigned(G_RAM_ADDR_BITS, 5));

         when X"8" | X"9" | X"A" | X"B" =>
            reg_rdata_o <= bp_addr(to_integer(reg_addr_i(1 downto 0)));

         when X"C" | X"D" | X"E" | X"F" =>
            reg_rdata_o(2 downto 0) <= bp_kind(to_integer(reg_addr_i(1 downto 0)));

         when others =>
            null;

      end case;
   end process p_rdata;

end architecture synthesis;
