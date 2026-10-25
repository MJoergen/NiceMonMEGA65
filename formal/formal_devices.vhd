-- The devices of nice_cpu/hdl/src (src/devices.vhd), with their
-- properties, for SymbiYosys. The inputs are free but for what nicemon
-- promises: the core's request comes only while no device is busy or
-- stalls, and the link's only while no device is busy, is owed, or
-- stalls, and not with the core's. The core's does not come while the
-- core is held, nor in the cycle after a hold, which resets the devices:
-- the core has just left reset then. The hold changes only while the
-- link's request neither comes nor waits, as contract f_hold of
-- formal/debug_link_formal.vhd says. Each request is to a device's
-- address, 0xFFFFFF10-7F.
--
-- RESET
-- The first cycle is a reset.

library ieee;
   use ieee.std_logic_1164.all;

library work;
   use work.pipe_pkg.all;

entity formal_devices is
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;
      hold_i       : in  std_logic;
      run_i        : in  std_logic;
      instret_i    : in  std_logic;
      core_cyc_i   : in  std_logic;
      core_stb_i   : in  std_logic;
      core_we_i    : in  std_logic;
      core_addr_i  : in  std_logic_vector(7 downto 0);
      core_wdata_i : in  std_logic_vector(31 downto 0);
      link_stb_i   : in  std_logic;
      link_we_i    : in  std_logic;
      link_addr_i  : in  std_logic_vector(7 downto 0);
      link_wdata_i : in  std_logic_vector(31 downto 0);
      irq_ready_i  : in  std_logic
   );
end entity formal_devices;

architecture synthesis of formal_devices is

   signal busy  : std_logic;
   signal owed  : std_logic;
   signal stall : std_logic;

begin

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;

   -- psl f_core_req : assume always
   --    core_stb_i = '1' -> core_cyc_i = '1' and busy = '0' and stall = '0' and hold_i = '0' and
   --                        prev(hold_i) = '0' and rst_i = '0' and core_addr_i(7) = '0' and
   --                        core_addr_i(6 downto 4) /= "000";
   -- psl f_link_req : assume always
   --    link_stb_i = '1' -> busy = '0' and owed = '0' and stall = '0' and core_stb_i = '0' and
   --                        rst_i = '0' and
   --                        link_addr_i(7) = '0' and link_addr_i(6 downto 4) /= "000";
   -- psl f_hold : assume always
   --    hold_i /= prev(hold_i) -> busy = '0' and link_stb_i = '0';


   i_devices : entity work.devices
      generic map (
         G_CLOCK_HZ => 100_000_000,
         G_FORMAL   => true
      )
      port map (
         clk_i        => clk_i,
         rst_i        => rst_i,
         hold_i       => hold_i,
         run_i        => run_i,
         instret_i    => instret_i,
         events_i     => C_FETCH_EVENTS_NONE,
         core_cyc_i   => core_cyc_i,
         core_stb_i   => core_stb_i,
         core_we_i    => core_we_i,
         core_addr_i  => core_addr_i,
         core_wdata_i => core_wdata_i,
         core_ack_o   => open,
         link_stb_i   => link_stb_i,
         link_we_i    => link_we_i,
         link_addr_i  => link_addr_i,
         link_wdata_i => link_wdata_i,
         link_ack_o   => open,
         rdata_o      => open,
         busy_o       => busy,
         owed_o       => owed,
         stall_o      => stall,
         irq_valid_o  => open,
         irq_ready_i  => irq_ready_i,
         irq_vector_o => open
      ); -- i_devices

end architecture synthesis;
