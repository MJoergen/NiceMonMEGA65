-- The devices of nice_cpu/hdl/src at 0xFFFFFF10-7F (src/nicemon.vhd): the
-- timer of SYSTEM.md §4 at 10-1F, the math unit (MPU) of §2 at 20-3F, the
-- performance counters of §3 at 40-4F, and the fetch statistics at 50-7F.
--
-- THEORY OF OPERATION
-- nicemon gives a request here in the cycle that it takes it, the core's
-- with core_stb_i and the link's with link_stb_i, when it is to one of the
-- devices; the address is its low byte, which picks the device.
--
-- The core's request goes to its device in that cycle, and the device
-- acknowledges it on core_ack_o, with its word on rdata_o. Each device
-- acknowledges in the cycle after it takes a request, except the MPU, which
-- takes a read of a result that it computes and then stalls until it
-- acknowledges it. stall_o is the MPU's stall, which holds the core and the
-- link meanwhile, so the core's requests are acknowledged in their order,
-- and at most one is owed (owed_o).
--
-- The link's request is latched, and the device's port is driven from the
-- latch while busy_o is high, until the device acknowledges it on
-- link_ack_o, with its word on rdata_o. nicemon registers that for the
-- link's acknowledge in the next cycle. A request of the link comes only
-- while no device is busy, owes the core an acknowledge, or stalls, and a
-- request of the core only while none is busy or stalls, so the two never
-- meet at a device. Neither comes in the cycle that the devices are reset
-- when the core starts, which would drop it.
--
-- The devices are reset with the system, and when the core starts, at the
-- end of a hold (hold_i), as the emulator's are when it starts. They are
-- not reset while the core is held, so that the link can read them after
-- a halt. A hold resets the core, and drops what is owed to it; a device
-- that has taken its request may still acknowledge it, while the core is
-- held or in the cycle after. The counters, the timer, and the fetch
-- statistics count only while run_i is high. The timer is the only device
-- that raises an interrupt, so its request goes straight to the core's IRQ.
--
-- With G_FORMAL, it states the properties that formal/devices.sby proves:
-- each acknowledge answers a request, the core's and the link's go to the
-- master that made it, with the word of the device that takes it, and
-- each request reaches its device, and no other.
--
-- RESET
-- Synchronous. Reset drops the link's request and what the core is owed,
-- and resets the devices.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

library work;
   use work.pipe_pkg.all;

entity devices is
   generic (
      G_CLOCK_HZ : natural;
      -- The properties for formal/devices.sby
      G_FORMAL   : boolean := false
   );
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;
      -- The core: held, running, retiring an instruction, and what FETCH
      -- and DECODE did
      hold_i       : in  std_logic;
      run_i        : in  std_logic;
      instret_i    : in  std_logic;
      events_i     : in  t_fetch_events;
      -- The core's data bus, and its request for a device, taken in this
      -- cycle
      core_cyc_i   : in  std_logic;
      core_stb_i   : in  std_logic;
      core_we_i    : in  std_logic;
      core_addr_i  : in  std_logic_vector(7 downto 0);
      core_wdata_i : in  std_logic_vector(31 downto 0);
      core_ack_o   : out std_logic;
      -- The link's request for a device, taken in this cycle
      link_stb_i   : in  std_logic;
      link_we_i    : in  std_logic;
      link_addr_i  : in  std_logic_vector(7 downto 0);
      link_wdata_i : in  std_logic_vector(31 downto 0);
      link_ack_o   : out std_logic;
      -- The word of the device that acknowledges
      rdata_o      : out std_logic_vector(31 downto 0);
      -- The link's request waits, the core is owed an acknowledge, and
      -- the MPU stalls
      busy_o       : out std_logic;
      owed_o       : out std_logic;
      stall_o      : out std_logic;
      -- The timer's interrupt request, for the core's IRQ port
      irq_valid_o  : out std_logic;
      irq_ready_i  : in  std_logic;
      irq_vector_o : out std_logic_vector(7 downto 0)
   );
end entity devices;

architecture synthesis of devices is

   type t_dev is (DEV_PERF, DEV_MPU, DEV_TIMER, DEV_FS);

   -- The device of the low byte of a device's address
   function dev_of(addr : std_logic_vector(7 downto 0)) return t_dev is
   begin
      if addr(7 downto 5) = "001" then
         return DEV_MPU;
      elsif addr(7 downto 4) = X"4" then
         return DEV_PERF;
      elsif addr(7 downto 6) = "01" then
         return DEV_FS;
      end if;
      return DEV_TIMER;
   end function dev_of;

   -- The hold in the cycle before, for a pulse when the core starts, and
   -- the devices' reset
   signal hold_d  : std_logic := '1';
   signal dev_rst : std_logic;

   -- The device of the last request taken, whose word rdata_o is
   signal sel : t_dev := DEV_TIMER;

   -- The link's latched request
   signal busy      : std_logic := '0';
   signal lnk_stb   : std_logic := '0';
   signal lnk_sel   : t_dev;
   signal lnk_addr  : std_logic_vector(5 downto 0);
   signal lnk_we    : std_logic;
   signal lnk_wdata : std_logic_vector(31 downto 0);

   -- The core is owed an acknowledge
   signal owed : std_logic := '0';

   -- The device of the core's request
   signal core_sel : t_dev;

   -- The devices' ports: the link's latch while it is busy, else the core
   signal io_cyc   : std_logic;
   signal io_we    : std_logic;
   signal io_addr  : std_logic_vector(5 downto 0);
   signal io_wdata : std_logic_vector(31 downto 0);
   signal io_stall : std_logic;   -- the latched device's
   signal io_ack   : std_logic;   -- any device's

   signal mpu_stb     : std_logic;
   signal mpu_stall   : std_logic;
   signal mpu_ack     : std_logic;
   signal mpu_data    : std_logic_vector(31 downto 0);
   signal perf_stb    : std_logic;
   signal perf_stall  : std_logic;
   signal perf_ack    : std_logic;
   signal perf_data   : std_logic_vector(31 downto 0);
   signal fs_stb      : std_logic;
   signal fs_stall    : std_logic;
   signal fs_ack      : std_logic;
   signal fs_data     : std_logic_vector(31 downto 0);
   signal timer_stb   : std_logic;
   signal timer_stall : std_logic;
   signal timer_ack   : std_logic;
   signal timer_data  : std_logic_vector(31 downto 0);

begin

   dev_rst <= rst_i or (hold_d and not hold_i);

   p_latch : process (clk_i)
   begin
      if rising_edge(clk_i) then
         hold_d <= hold_i;

         if core_stb_i = '1' then
            sel <= core_sel;
         end if;

         if busy = '1' then
            if lnk_stb = '1' and io_stall = '0' then
               lnk_stb <= '0';
            end if;
            if io_ack = '1' then
               busy <= '0';
            end if;
         elsif link_stb_i = '1' then
            busy      <= '1';
            lnk_stb   <= '1';
            lnk_sel   <= dev_of(link_addr_i);
            lnk_addr  <= link_addr_i(5 downto 0);
            lnk_we    <= link_we_i;
            lnk_wdata <= link_wdata_i;
            sel       <= dev_of(link_addr_i);
         end if;

         -- Each device acknowledges in the cycle after it takes a request,
         -- or stalls the core until it does, so at most one is owed.
         if core_stb_i = '1' then
            owed <= '1';
         elsif io_ack = '1' then
            owed <= '0';
         end if;

         -- A request of the core in reset is dropped.
         if rst_i = '1' or hold_i = '1' then
            owed <= '0';
         end if;

         if rst_i = '1' then
            busy    <= '0';
            lnk_stb <= '0';
         end if;
      end if;
   end process p_latch;

   core_sel <= dev_of(core_addr_i);

   -- The link's latched request while it is busy, else the core's request,
   -- which goes to a device only in the cycle that takes it
   io_cyc   <= '1' when busy = '1' else core_cyc_i;
   io_we    <= lnk_we when busy = '1' else core_we_i;
   io_addr  <= lnk_addr when busy = '1' else core_addr_i(5 downto 0);
   io_wdata <= lnk_wdata when busy = '1' else core_wdata_i;

   mpu_stb   <= lnk_stb when busy = '1' and lnk_sel = DEV_MPU else
                core_stb_i when core_sel = DEV_MPU else
                '0';
   perf_stb  <= lnk_stb when busy = '1' and lnk_sel = DEV_PERF else
                core_stb_i when core_sel = DEV_PERF else
                '0';
   fs_stb    <= lnk_stb when busy = '1' and lnk_sel = DEV_FS else
                core_stb_i when core_sel = DEV_FS else
                '0';
   timer_stb <= lnk_stb when busy = '1' and lnk_sel = DEV_TIMER else
                core_stb_i when core_sel = DEV_TIMER else
                '0';
   io_stall  <= mpu_stall when lnk_sel = DEV_MPU else
                perf_stall when lnk_sel = DEV_PERF else
                fs_stall when lnk_sel = DEV_FS else
                timer_stall;
   io_ack    <= mpu_ack or perf_ack or fs_ack or timer_ack;

   core_ack_o <= owed and io_ack;
   link_ack_o <= busy and io_ack;
   rdata_o    <= mpu_data when sel = DEV_MPU else
                 perf_data when sel = DEV_PERF else
                 fs_data when sel = DEV_FS else
                 timer_data;
   busy_o     <= busy;
   owed_o     <= owed;
   stall_o    <= mpu_stall;

   i_mpu : entity work.mpu
      port map (
         clk_i      => clk_i,
         rst_i      => dev_rst,
         wb_cyc_i   => io_cyc,
         wb_stb_i   => mpu_stb,
         wb_stall_o => mpu_stall,
         wb_ack_o   => mpu_ack,
         wb_we_i    => io_we,
         wb_addr_i  => io_addr(4 downto 0),
         wb_data_i  => io_wdata,
         wb_data_o  => mpu_data
      ); -- i_mpu

   i_perf : entity work.perf
      generic map (
         G_CLK_HZ => G_CLOCK_HZ
      )
      port map (
         clk_i      => clk_i,
         rst_i      => dev_rst,
         run_i      => run_i,
         instret_i  => instret_i,
         wb_cyc_i   => io_cyc,
         wb_stb_i   => perf_stb,
         wb_stall_o => perf_stall,
         wb_ack_o   => perf_ack,
         wb_we_i    => io_we,
         wb_addr_i  => io_addr(3 downto 0),
         wb_data_i  => io_wdata,
         wb_data_o  => perf_data
      ); -- i_perf

   i_fetch_stats : entity work.fetch_stats
      port map (
         clk_i      => clk_i,
         rst_i      => dev_rst,
         run_i      => run_i,
         events_i   => events_i,
         wb_cyc_i   => io_cyc,
         wb_stb_i   => fs_stb,
         wb_stall_o => fs_stall,
         wb_ack_o   => fs_ack,
         wb_we_i    => io_we,
         wb_addr_i  => io_addr,
         wb_data_i  => io_wdata,
         wb_data_o  => fs_data
      ); -- i_fetch_stats

   i_timer : entity work.timer
      port map (
         clk_i        => clk_i,
         rst_i        => dev_rst,
         tick_i       => run_i,
         wb_cyc_i     => io_cyc,
         wb_stb_i     => timer_stb,
         wb_stall_o   => timer_stall,
         wb_ack_o     => timer_ack,
         wb_we_i      => io_we,
         wb_addr_i    => io_addr(3 downto 0),
         wb_data_i    => io_wdata,
         wb_data_o    => timer_data,
         irq_valid_o  => irq_valid_o,
         irq_ready_i  => irq_ready_i,
         irq_vector_o => irq_vector_o
      ); -- i_timer


   gen_formal : if G_FORMAL generate
      -- The stb of each device, by t_dev'pos, and the acknowledge of each
      signal f_stb : std_logic_vector(3 downto 0);
      signal f_ack : std_logic_vector(3 downto 0);
      -- The core's requests taken and not yet acknowledged, which a hold
      -- drops
      signal f_core_wait : natural range 0 to 3 := 0;
   begin

      p_core_wait : process (clk_i)
      begin
         if rising_edge(clk_i) then
            if core_stb_i = '1' and core_ack_o = '0' then
               f_core_wait <= f_core_wait + 1;
            elsif core_stb_i = '0' and core_ack_o = '1' then
               f_core_wait <= f_core_wait - 1;
            end if;
            if rst_i = '1' or hold_i = '1' then
               f_core_wait <= 0;
            end if;
         end if;
      end process p_core_wait;

      f_stb <= fs_stb & timer_stb & mpu_stb & perf_stb;
      f_ack <= fs_ack & timer_ack & mpu_ack & perf_ack;

      -- psl default clock is rising_edge(clk_i);

      -- Each acknowledge answers a request: the link's that waits, or one
      -- that the core is owed, or one that a hold dropped. The MPU stalls
      -- only so too. The link and the core never wait at once.
      -- psl f_dev_ack : assert always
      --    rst_i = '0' and io_ack = '1' -> busy = '1' or owed = '1' or hold_d = '1';
      -- psl f_dev_stall : assert always
      --    rst_i = '0' and mpu_stall = '1' -> busy = '1' or owed = '1' or hold_d = '1';
      -- psl f_one_wait : assert always not (busy = '1' and owed = '1');
      -- psl f_one_ack : assert always f_ack = "0000" or f_ack = "0001" or f_ack = "0010" or
      --                               f_ack = "0100" or f_ack = "1000";

      -- A request reaches its device, and no other: the core's in the
      -- cycle it is taken, the link's from the latch until the device
      -- takes it, with the request that the link made.
      -- psl f_core_stb : assert always
      --    core_stb_i = '1' -> f_stb(t_dev'pos(dev_of(core_addr_i))) = '1';
      -- psl f_stb_one : assert always f_stb = "0000" or f_stb = "0001" or f_stb = "0010" or
      --                               f_stb = "0100" or f_stb = "1000";
      -- psl f_stb_who : assert always f_stb /= "0000" -> core_stb_i = '1' or lnk_stb = '1';
      -- psl f_link_latch : assert always
      --    {link_stb_i and not busy and not rst_i} |=>
      --    {busy = '1' and lnk_stb = '1' and lnk_sel = prev(dev_of(link_addr_i)) and
      --     lnk_addr = prev(link_addr_i(5 downto 0)) and lnk_we = prev(link_we_i) and
      --     lnk_wdata = prev(link_wdata_i)};
      -- psl f_link_stb : assert always
      --    lnk_stb = '1' -> busy = '1' and f_stb(t_dev'pos(lnk_sel)) = '1' and
      --                     io_cyc = '1' and io_we = lnk_we and io_addr = lnk_addr and
      --                     io_wdata = lnk_wdata;
      -- psl f_link_fresh : assert always lnk_stb = '1' -> mpu_stall = '0' and io_ack = '0';
      -- psl f_link_once : assert always
      --    {lnk_stb and not io_stall and not rst_i} |=> {not lnk_stb};

      -- An acknowledge goes to the master that made the request, with the
      -- word of the device that takes it.
      -- psl f_owed_due : assert always owed = '1' -> io_ack = '1' or mpu_stall = '1';
      -- psl f_busy_due : assert always
      --    busy = '1' and lnk_stb = '0' -> io_ack = '1' or mpu_stall = '1';
      -- psl f_core_ack : assert always core_ack_o = '1' -> f_core_wait = 1;
      -- psl f_core_owed : assert always f_core_wait <= 1 and (f_core_wait = 1) = (owed = '1');
      -- psl f_ack_who : assert always not (core_ack_o = '1' and link_ack_o = '1');
      -- psl f_sel_link : assert always busy = '1' -> sel = lnk_sel;
      -- psl f_sel_mpu : assert always
      --    mpu_stall = '1' and (busy = '1' or owed = '1') -> sel = DEV_MPU;
      -- psl f_rdata : assert always
      --    (core_ack_o = '1' or link_ack_o = '1') ->
      --    (mpu_ack = '1' and rdata_o = mpu_data) or (perf_ack = '1' and rdata_o = perf_data) or
      --    (fs_ack = '1' and rdata_o = fs_data) or (timer_ack = '1' and rdata_o = timer_data);

      -- The devices are reset when the core starts.
      -- psl f_start : assert always {hold_i; not hold_i} |-> {dev_rst};

      -- psl c_core : cover {core_stb_i and not rst_i; core_ack_o};
      -- psl c_link : cover {link_stb_i and not rst_i; true; link_ack_o};
      -- psl c_mpu_wait : cover {core_stb_i and not rst_i; mpu_stall[*2]; core_ack_o};
      -- psl c_link_wait : cover {link_stb_i and not rst_i; true; mpu_stall[*2]; link_ack_o};
      -- psl c_back : cover {core_stb_i and not rst_i; core_stb_i and core_ack_o; core_ack_o};
   end generate gen_formal;

end architecture synthesis;
