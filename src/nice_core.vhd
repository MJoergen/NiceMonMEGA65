-- The NICE core of the system, as one entity whichever core is built. Its
-- ports are those of nice_cpu's pipeline and multicycle, and the
-- architecture comes from one of the files in src/core/, which the build
-- picks with NICE=pipeline or NICE=multi (core.mk). So only that core is
-- analysed, and no generic has to reach it from the top level.

library ieee;
   use ieee.std_logic_1164.all;

   use work.trace_pkg.all;

entity nice_core is
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;

      -- Instruction bus: read only
      ibus_cyc_o   : out std_logic;
      ibus_stb_o   : out std_logic;
      ibus_stall_i : in  std_logic;
      ibus_ack_i   : in  std_logic;
      ibus_addr_o  : out std_logic_vector(30 downto 0);
      ibus_data_i  : in  std_logic_vector(63 downto 0);

      -- Data bus: read and write
      dbus_cyc_o   : out std_logic;
      dbus_stb_o   : out std_logic;
      dbus_stall_i : in  std_logic;
      dbus_ack_i   : in  std_logic;
      dbus_we_o    : out std_logic;
      dbus_addr_o  : out std_logic_vector(31 downto 0);
      dbus_data_o  : out std_logic_vector(31 downto 0);
      dbus_data_i  : in  std_logic_vector(31 downto 0);

      -- Interrupt requests
      nmi_valid_i  : in  std_logic;
      nmi_ready_o  : out std_logic;
      nmi_vector_i : in  std_logic_vector(7 downto 0);
      irq_valid_i  : in  std_logic;
      irq_ready_o  : out std_logic;
      irq_vector_i : in  std_logic_vector(7 downto 0);

      pause_i      : in  std_logic;
      paused_o     : out std_logic;
      halted_o     : out std_logic;
      instret_o    : out std_logic;
      retire_o     : out t_retire
   );
end entity nice_core;
