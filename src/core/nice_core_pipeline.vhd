-- nice_core of the pipelined core, nice_cpu's pipeline.vhd. Built with NICE=pipeline.

architecture pipeline of nice_core is

begin

   i_core : entity work.pipeline
      port map (
         clk_i        => clk_i,
         rst_i        => rst_i,
         ibus_cyc_o   => ibus_cyc_o,
         ibus_stb_o   => ibus_stb_o,
         ibus_stall_i => ibus_stall_i,
         ibus_ack_i   => ibus_ack_i,
         ibus_addr_o  => ibus_addr_o,
         ibus_data_i  => ibus_data_i,
         dbus_cyc_o   => dbus_cyc_o,
         dbus_stb_o   => dbus_stb_o,
         dbus_stall_i => dbus_stall_i,
         dbus_ack_i   => dbus_ack_i,
         dbus_we_o    => dbus_we_o,
         dbus_addr_o  => dbus_addr_o,
         dbus_data_o  => dbus_data_o,
         dbus_data_i  => dbus_data_i,
         nmi_valid_i  => nmi_valid_i,
         nmi_ready_o  => nmi_ready_o,
         nmi_vector_i => nmi_vector_i,
         irq_valid_i  => irq_valid_i,
         irq_ready_o  => irq_ready_o,
         irq_vector_i => irq_vector_i,
         halted_o     => halted_o,
         instret_o    => instret_o,
         regs_o       => regs_o,
         retire_o     => retire_o,
         stats_o      => open
      ); -- i_core

end architecture pipeline;
