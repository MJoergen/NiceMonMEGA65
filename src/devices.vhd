-- The devices of nice_cpu/hdl/src at 0xFFFFFF10-7F and A0-CF
-- (src/nicemon.vhd): the timer of SYSTEM.md §4 at 10-1F, the math unit
-- (MPU) of §2 at 20-3F, the performance counters of §3 at 40-4F, the fetch
-- statistics at 50-7F, with G_SD_SLOTS > 0 the SD card controller of §5
-- at A0-AF (src/sd/sd.vhd), the registers of the network station of §6
-- at B0-BF (nice_cpu/hdl/src/net_regs.vhd), and the port for Ethernet
-- frames of §7 at C0-CF (nice_cpu/hdl/src/eth_regs.vhd).
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
-- acknowledges it, the SD card controller with G_SD_HOLD_ACK, which
-- does so with a write that starts a command, and the port for Ethernet
-- frames with G_ETH_HOLD_ACK, which does so with a write that enables it
-- or sends a frame, until the simulation's station has served it
-- (nice_cpu/hdl/sim/eth_sim.vhd). stall_o is their stall,
-- which holds the core and the link meanwhile, so the core's requests are
-- acknowledged in their order, and at most one is owed (owed_o).
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
-- The SD card controller's registers are reset when the core starts, but
-- its engine and its pins only with the system (src/sd/sd.vhd), and it
-- runs while the core is held, paused, or halted (SYSTEM.md §5). The
-- network station's registers are reset only with the system, not when
-- the core starts, so that a program finds the addresses that an earlier
-- one set, and a host keeps its connection (SYSTEM.md §6). The port for
-- Ethernet frames is reset when the core starts, but a frame that is
-- being sent goes on (SYSTEM.md §7). Its station is eth/eth.vhd, through
-- the eth_q_* and eth_tx_* ports, which the station drives whether or not
-- the port is enabled; the port decides what it takes.
--
-- With G_FORMAL, it states the properties that formal/devices.sby proves:
-- each acknowledge answers a request, the core's and the link's go to the
-- master that made it, with the word of the device that takes it, and
-- each request reaches its device, and no other. Without G_SD_HOLD_ACK,
-- the SD card controller never stalls, and without G_ETH_HOLD_ACK, the
-- port for Ethernet frames never stalls. A start of the core keeps the
-- station's addresses.
--
-- RESET
-- Synchronous. Reset drops the link's request and what the core is owed,
-- and resets the devices. It sets the station's IP address to 0 and its
-- MAC address to G_ETH_MAC.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

library work;
   use work.pipe_pkg.all;

entity devices is
   generic (
      G_CLOCK_HZ     : natural;
      -- The SD card slots, 0 for no controller, and those of src/sd/sd.vhd
      G_SD_SLOTS     : natural range 0 to 2         := 0;
      G_SD_DETECT    : std_logic_vector(1 downto 0) := "11";
      G_SD_POWER     : boolean                      := false;
      G_SD_HOLD_ACK  : boolean                      := false;
      G_SD_SLOW_HZ   : positive                     := 400_000;
      -- Hold the ACK of the port for Ethernet frames, for eth_sim.vhd
      G_ETH_HOLD_ACK : boolean                     := false;
      -- The network station's MAC address after reset
      G_ETH_MAC      : std_logic_vector(47 downto 0) := X"024E49434500";
      -- The properties for formal/devices.sby
      G_FORMAL       : boolean                      := false
   );
   port (
      clk_i             : in  std_logic;
      rst_i             : in  std_logic;
      -- The core: held, running, retiring an instruction, and what FETCH
      -- and DECODE did
      hold_i            : in  std_logic;
      run_i             : in  std_logic;
      instret_i         : in  std_logic;
      events_i          : in  t_fetch_events;
      -- The core's data bus, and its request for a device, taken in this
      -- cycle
      core_cyc_i        : in  std_logic;
      core_stb_i        : in  std_logic;
      core_we_i         : in  std_logic;
      core_addr_i       : in  std_logic_vector(7 downto 0);
      core_wdata_i      : in  std_logic_vector(31 downto 0);
      core_ack_o        : out std_logic;
      -- The link's request for a device, taken in this cycle
      link_stb_i        : in  std_logic;
      link_we_i         : in  std_logic;
      link_addr_i       : in  std_logic_vector(7 downto 0);
      link_wdata_i      : in  std_logic_vector(31 downto 0);
      link_ack_o        : out std_logic;
      -- The word of the device that acknowledges
      rdata_o           : out std_logic_vector(31 downto 0);
      -- The link's request waits, the core is owed an acknowledge, and
      -- the MPU stalls
      busy_o            : out std_logic;
      owed_o            : out std_logic;
      stall_o           : out std_logic;
      -- The timer's interrupt request, for the core's IRQ port
      irq_valid_o       : out std_logic;
      irq_ready_i       : in  std_logic;
      irq_vector_o      : out std_logic_vector(7 downto 0);
      -- The SD card slots' pins (src/sd/sd.vhd)
      sd_clk_o          : out std_logic_vector(1 downto 0);
      sd_cmd_o          : out std_logic_vector(1 downto 0);
      sd_dat3_o         : out std_logic_vector(1 downto 0);
      sd_dat0_i         : in  std_logic_vector(1 downto 0) := "11";
      sd_cd_n_i         : in  std_logic_vector(1 downto 0) := "11";
      sd_wp_i           : in  std_logic_vector(1 downto 0) := "00";
      sd_pwr_n_o        : out std_logic;
      -- The network station (net_regs.vhd): its counts of Ethernet frames
      -- received, good and bad, and sent, a host connected to the link
      -- over TCP, and the port of the link, in the clock domain of clk_i,
      -- and its IP and MAC addresses
      eth_rx_i          : in  std_logic_vector(31 downto 0) := (others => '0');
      eth_rx_bad_i      : in  std_logic_vector(31 downto 0) := (others => '0');
      eth_tx_i          : in  std_logic_vector(31 downto 0) := (others => '0');
      net_on_i          : in  std_logic                     := '0';
      net_port_i        : in  std_logic_vector(15 downto 0) := (others => '0');
      eth_ip_o          : out std_logic_vector(31 downto 0);
      eth_mac_o         : out std_logic_vector(47 downto 0);
      -- The port for Ethernet frames (eth_regs.vhd): the station puts the
      -- frames for its queue, and sends the frame of its send buffer
      -- (eth/eth_frames.vhd). eth_enable_o and eth_enable_done_i are for
      -- G_ETH_HOLD_ACK, the simulation's station.
      eth_enable_o      : out std_logic;
      eth_enable_done_i : in  std_logic                     := '0';
      eth_q_start_i     : in  std_logic                     := '0';
      eth_q_we_i        : in  std_logic                     := '0';
      eth_q_addr_i      : in  std_logic_vector(8 downto 0)  := (others => '0');
      eth_q_data_i      : in  std_logic_vector(31 downto 0) := (others => '0');
      eth_q_done_i      : in  std_logic                     := '0';
      eth_q_len_i       : in  std_logic_vector(10 downto 0) := (others => '0');
      eth_tx_start_o    : out std_logic;
      eth_tx_len_o      : out std_logic_vector(10 downto 0);
      eth_tx_addr_i     : in  std_logic_vector(8 downto 0)  := (others => '0');
      eth_tx_data_o     : out std_logic_vector(31 downto 0);
      eth_tx_done_i     : in  std_logic                     := '0'
   );
end entity devices;

architecture synthesis of devices is

   type t_dev is (DEV_PERF, DEV_MPU, DEV_TIMER, DEV_FS, DEV_SD, DEV_NET, DEV_ETH);

   -- The device of the low byte of a device's address
   function dev_of(addr : std_logic_vector(7 downto 0)) return t_dev is
   begin
      if addr(7 downto 5) = "001" then
         return DEV_MPU;
      elsif addr(7 downto 4) = X"4" then
         return DEV_PERF;
      elsif addr(7 downto 6) = "01" then
         return DEV_FS;
      elsif addr(7 downto 4) = X"A" then
         return DEV_SD;
      elsif addr(7 downto 4) = X"B" then
         return DEV_NET;
      elsif addr(7 downto 4) = X"C" then
         return DEV_ETH;
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
   signal sd_stb      : std_logic;
   signal sd_stall    : std_logic;
   signal sd_ack      : std_logic;
   signal sd_data     : std_logic_vector(31 downto 0);
   signal net_stb     : std_logic;
   signal net_stall   : std_logic;
   signal net_ack     : std_logic;
   signal net_data    : std_logic_vector(31 downto 0);
   signal eth_stb     : std_logic;
   signal eth_stall   : std_logic;
   signal eth_ack     : std_logic;
   signal eth_data    : std_logic_vector(31 downto 0);

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
   sd_stb    <= lnk_stb when busy = '1' and lnk_sel = DEV_SD else
                core_stb_i when core_sel = DEV_SD else
                '0';
   net_stb   <= lnk_stb when busy = '1' and lnk_sel = DEV_NET else
                core_stb_i when core_sel = DEV_NET else
                '0';
   eth_stb   <= lnk_stb when busy = '1' and lnk_sel = DEV_ETH else
                core_stb_i when core_sel = DEV_ETH else
                '0';
   io_stall  <= mpu_stall when lnk_sel = DEV_MPU else
                perf_stall when lnk_sel = DEV_PERF else
                fs_stall when lnk_sel = DEV_FS else
                sd_stall when lnk_sel = DEV_SD else
                net_stall when lnk_sel = DEV_NET else
                eth_stall when lnk_sel = DEV_ETH else
                timer_stall;
   io_ack    <= mpu_ack or perf_ack or fs_ack or timer_ack or sd_ack or net_ack or eth_ack;

   core_ack_o <= owed and io_ack;
   link_ack_o <= busy and io_ack;
   rdata_o    <= mpu_data when sel = DEV_MPU else
                 perf_data when sel = DEV_PERF else
                 fs_data when sel = DEV_FS else
                 sd_data when sel = DEV_SD else
                 net_data when sel = DEV_NET else
                 eth_data when sel = DEV_ETH else
                 timer_data;
   busy_o     <= busy;
   owed_o     <= owed;
   stall_o    <= mpu_stall or sd_stall or eth_stall;

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


   gen_sd : if G_SD_SLOTS > 0 generate

      i_sd : entity work.sd
         generic map (
            G_CLOCK_HZ => G_CLOCK_HZ,
            G_SLOTS    => G_SD_SLOTS,
            G_DETECT   => G_SD_DETECT,
            G_POWER    => G_SD_POWER,
            G_HOLD_ACK => G_SD_HOLD_ACK,
            G_SLOW_HZ  => G_SD_SLOW_HZ
         )
         port map (
            clk_i      => clk_i,
            rst_i      => rst_i,
            dev_rst_i  => dev_rst,
            wb_cyc_i   => io_cyc,
            wb_stb_i   => sd_stb,
            wb_stall_o => sd_stall,
            wb_ack_o   => sd_ack,
            wb_we_i    => io_we,
            wb_addr_i  => io_addr(3 downto 0),
            wb_data_i  => io_wdata,
            wb_data_o  => sd_data,
            busy_o     => open,
            sd_clk_o   => sd_clk_o,
            sd_cmd_o   => sd_cmd_o,
            sd_dat3_o  => sd_dat3_o,
            sd_dat0_i  => sd_dat0_i,
            sd_cd_n_i  => sd_cd_n_i,
            sd_wp_i    => sd_wp_i,
            sd_pwr_n_o => sd_pwr_n_o
         ); -- i_sd

   else generate
      -- No controller: nicemon sends no request here, and the pins rest.
      sd_stall   <= '0';
      sd_ack     <= '0';
      sd_data    <= (others => '0');
      sd_clk_o   <= "00";
      sd_cmd_o   <= "11";
      sd_dat3_o  <= "11";
      sd_pwr_n_o <= '1';
   end generate gen_sd;

   -- The network station's registers, which only the system's reset
   -- resets. A write of an address while a host is connected, or while a
   -- reply goes out, breaks it (eth/eth.vhd, contract c), as SYSTEM.md §6
   -- allows, so wr_o is not needed.
   i_net_regs : entity work.net_regs
      generic map (
         G_MAC => G_ETH_MAC
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         wb_cyc_i    => io_cyc,
         wb_stb_i    => net_stb,
         wb_stall_o  => net_stall,
         wb_ack_o    => net_ack,
         wb_we_i     => io_we,
         wb_addr_i   => io_addr(3 downto 0),
         wb_data_i   => io_wdata,
         wb_data_o   => net_data,
         rx_good_i   => eth_rx_i,
         rx_bad_i    => eth_rx_bad_i,
         tx_i        => eth_tx_i,
         connected_i => net_on_i,
         port_i      => net_port_i,
         ip_o        => eth_ip_o,
         mac_o       => eth_mac_o,
         wr_o        => open
      ); -- i_net_regs

   -- The port for Ethernet frames, which the core's start resets. Its
   -- busy_o, for an activity light, is not used.
   i_eth_regs : entity work.eth_regs
      generic map (
         G_HOLD_ACK => G_ETH_HOLD_ACK
      )
      port map (
         clk_i         => clk_i,
         rst_i         => dev_rst,
         wb_cyc_i      => io_cyc,
         wb_stb_i      => eth_stb,
         wb_stall_o    => eth_stall,
         wb_ack_o      => eth_ack,
         wb_we_i       => io_we,
         wb_addr_i     => io_addr(3 downto 0),
         wb_data_i     => io_wdata,
         wb_data_o     => eth_data,
         enabled_o     => open,
         enable_o      => eth_enable_o,
         enable_done_i => eth_enable_done_i,
         rx_start_i    => eth_q_start_i,
         rx_we_i       => eth_q_we_i,
         rx_addr_i     => eth_q_addr_i,
         rx_data_i     => eth_q_data_i,
         rx_done_i     => eth_q_done_i,
         rx_len_i      => eth_q_len_i,
         tx_start_o    => eth_tx_start_o,
         busy_o        => open,
         tx_len_o      => eth_tx_len_o,
         tx_addr_i     => eth_tx_addr_i,
         tx_data_o     => eth_tx_data_o,
         tx_done_i     => eth_tx_done_i
      ); -- i_eth_regs


   gen_formal : if G_FORMAL generate
      -- The stb of each device, by t_dev'pos, and the acknowledge of each
      signal f_stb : std_logic_vector(6 downto 0);
      signal f_ack : std_logic_vector(6 downto 0);
      -- A device that stalls
      signal f_stall : std_logic;
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

      f_stb   <= eth_stb & net_stb & sd_stb & fs_stb & timer_stb & mpu_stb & perf_stb;
      f_ack   <= eth_ack & net_ack & sd_ack & fs_ack & timer_ack & mpu_ack & perf_ack;
      f_stall <= mpu_stall or sd_stall or eth_stall;

      -- psl default clock is rising_edge(clk_i);

      -- Each acknowledge answers a request: the link's that waits, or one
      -- that the core is owed, or one that a hold dropped. A device stalls
      -- only so too. The link and the core never wait at once.
      -- psl f_dev_ack : assert always
      --    rst_i = '0' and io_ack = '1' -> busy = '1' or owed = '1' or hold_d = '1';
      -- psl f_dev_stall : assert always
      --    rst_i = '0' and f_stall = '1' -> busy = '1' or owed = '1' or hold_d = '1';
      -- psl f_one_wait : assert always not (busy = '1' and owed = '1');
      -- psl f_one_ack : assert always (f_ack and (f_ack - 1)) = "0000000";

      -- A request reaches its device, and no other: the core's in the
      -- cycle it is taken, the link's from the latch until the device
      -- takes it, with the request that the link made.
      -- psl f_core_stb : assert always
      --    core_stb_i = '1' -> f_stb(t_dev'pos(dev_of(core_addr_i))) = '1';
      -- psl f_stb_one : assert always (f_stb and (f_stb - 1)) = "0000000";
      -- psl f_stb_who : assert always f_stb /= "0000000" -> core_stb_i = '1' or lnk_stb = '1';
      -- psl f_link_latch : assert always
      --    {link_stb_i and not busy and not rst_i} |=>
      --    {busy = '1' and lnk_stb = '1' and lnk_sel = prev(dev_of(link_addr_i)) and
      --     lnk_addr = prev(link_addr_i(5 downto 0)) and lnk_we = prev(link_we_i) and
      --     lnk_wdata = prev(link_wdata_i)};
      -- psl f_link_stb : assert always
      --    lnk_stb = '1' -> busy = '1' and f_stb(t_dev'pos(lnk_sel)) = '1' and
      --                     io_cyc = '1' and io_we = lnk_we and io_addr = lnk_addr and
      --                     io_wdata = lnk_wdata;
      -- psl f_link_fresh : assert always lnk_stb = '1' -> f_stall = '0' and io_ack = '0';
      -- psl f_link_once : assert always
      --    {lnk_stb and not io_stall and not rst_i} |=> {not lnk_stb};

      -- An acknowledge goes to the master that made the request, with the
      -- word of the device that takes it.
      -- psl f_owed_due : assert always owed = '1' -> io_ack = '1' or f_stall = '1';
      -- psl f_busy_due : assert always
      --    busy = '1' and lnk_stb = '0' -> io_ack = '1' or f_stall = '1';
      -- psl f_core_ack : assert always core_ack_o = '1' -> f_core_wait = 1;
      -- psl f_core_owed : assert always f_core_wait <= 1 and (f_core_wait = 1) = (owed = '1');
      -- psl f_ack_who : assert always not (core_ack_o = '1' and link_ack_o = '1');
      -- psl f_sel_link : assert always busy = '1' -> sel = lnk_sel;
      -- psl f_sel_mpu : assert always
      --    mpu_stall = '1' and (busy = '1' or owed = '1') -> sel = DEV_MPU;
      -- psl f_sel_sd : assert always
      --    sd_stall = '1' and (busy = '1' or owed = '1') -> sel = DEV_SD;
      -- psl f_sel_eth : assert always
      --    eth_stall = '1' and (busy = '1' or owed = '1') -> sel = DEV_ETH;
      -- psl f_rdata : assert always
      --    (core_ack_o = '1' or link_ack_o = '1') ->
      --    (mpu_ack = '1' and rdata_o = mpu_data) or (perf_ack = '1' and rdata_o = perf_data) or
      --    (fs_ack = '1' and rdata_o = fs_data) or (timer_ack = '1' and rdata_o = timer_data) or
      --    (sd_ack = '1' and rdata_o = sd_data) or (net_ack = '1' and rdata_o = net_data) or
      --    (eth_ack = '1' and rdata_o = eth_data);

      -- The devices are reset when the core starts.
      -- psl f_start : assert always {hold_i; not hold_i} |-> {dev_rst};

      -- The station never stalls, and only the system's reset sets its
      -- addresses: a start of the core keeps them.
      -- psl f_net_no_stall : assert always net_stall = '0';
      -- psl f_net_keep : assert always
      --    {not rst_i and not net_stb} |=> {stable(eth_ip_o) and stable(eth_mac_o)};
      -- psl c_net_core : cover {core_stb_i and net_stb and not rst_i; core_ack_o};
      -- psl c_net_link : cover {link_stb_i and not rst_i; net_stb; link_ack_o};

      -- psl c_core : cover {core_stb_i and not rst_i; core_ack_o};
      -- psl c_link : cover {link_stb_i and not rst_i; true; link_ack_o};
      -- psl c_mpu_wait : cover {core_stb_i and not rst_i; mpu_stall[*2]; core_ack_o};
      -- psl c_link_wait : cover {link_stb_i and not rst_i; true; mpu_stall[*2]; link_ack_o};
      -- psl c_back : cover {core_stb_i and not rst_i; core_stb_i and core_ack_o; core_ack_o};

      -- psl c_eth_core : cover {core_stb_i and eth_stb and not rst_i; core_ack_o};
      -- psl c_eth_link : cover {link_stb_i and not rst_i; eth_stb; link_ack_o};

      gen_formal_eth_ack : if not G_ETH_HOLD_ACK generate
      begin
         -- Without G_ETH_HOLD_ACK, the port for Ethernet frames never
         -- stalls, as it acknowledges each request in the cycle after it
         -- takes it.
         -- psl f_eth_no_stall : assert always eth_stall = '0';
      end generate gen_formal_eth_ack;

      gen_formal_sd_ack : if not G_SD_HOLD_ACK generate
      begin
         -- Without G_SD_HOLD_ACK, the SD card controller never stalls, as
         -- it acknowledges each request in the cycle after it takes it.
         -- psl f_sd_no_stall : assert always sd_stall = '0';
      end generate gen_formal_sd_ack;

      gen_formal_sd : if G_SD_SLOTS > 0 generate
      begin
         -- With the SD card controller, the core and the link reach it.
         -- psl c_sd_core : cover {core_stb_i and sd_stb and not rst_i; core_ack_o};
         -- psl c_sd_link : cover {link_stb_i and not rst_i; sd_stb; link_ack_o};
      end generate gen_formal_sd;

   end generate gen_formal;

end architecture synthesis;
