-- A smoke test of the NICE core from the nice_cpu submodule. It runs a
-- program on nice_core, the pipelined core by default, and writes the console
-- output to a file, which the Makefile compares with the expected output.
--
-- THEORY OF OPERATION
-- The core runs on the simulation memory of nice_cpu (hdl/sim/wb_mem.vhd),
-- which loads G_BIN_FILE. Each byte written to the console is collected, and
-- a line is written to G_OUT_FILE at every newline. The run ends when the
-- core halts, or fails after G_TIMEOUT clock cycles.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.textio.all;
   use std.env.all;

entity tb_hello is
   generic (
      G_BIN_FILE : string;
      G_OUT_FILE : string;
      G_TIMEOUT  : positive := 100_000
   );
end entity tb_hello;

architecture simulation of tb_hello is

   signal clk : std_logic;
   signal rst : std_logic;

   signal ibus_cyc   : std_logic;
   signal ibus_stb   : std_logic;
   signal ibus_stall : std_logic;
   signal ibus_ack   : std_logic;
   signal ibus_addr  : std_logic_vector(30 downto 0);
   signal ibus_data  : std_logic_vector(63 downto 0);

   signal dbus_cyc      : std_logic;
   signal dbus_stb      : std_logic;
   signal dbus_stall    : std_logic;
   signal dbus_ack      : std_logic;
   signal dbus_we       : std_logic;
   signal dbus_addr     : std_logic_vector(31 downto 0);
   signal dbus_data_out : std_logic_vector(31 downto 0);
   signal dbus_data_in  : std_logic_vector(31 downto 0);

   signal console_valid : std_logic;
   signal console_data  : std_logic_vector(7 downto 0);

   signal halted : std_logic;

begin

   p_clk : process
   begin
      clk <= '1', '0' after 5 ns;
      wait for 10 ns;
   end process p_clk;


   p_rst : process
   begin
      rst <= '1';
      wait for 100 ns;
      wait until rising_edge(clk);
      rst <= '0';
      wait;
   end process p_rst;


   i_core : entity work.nice_core
      port map (
         clk_i        => clk,
         rst_i        => rst,
         ibus_cyc_o   => ibus_cyc,
         ibus_stb_o   => ibus_stb,
         ibus_stall_i => ibus_stall,
         ibus_ack_i   => ibus_ack,
         ibus_addr_o  => ibus_addr,
         ibus_data_i  => ibus_data,
         dbus_cyc_o   => dbus_cyc,
         dbus_stb_o   => dbus_stb,
         dbus_stall_i => dbus_stall,
         dbus_ack_i   => dbus_ack,
         dbus_we_o    => dbus_we,
         dbus_addr_o  => dbus_addr,
         dbus_data_o  => dbus_data_out,
         dbus_data_i  => dbus_data_in,
         nmi_valid_i  => '0',
         nmi_ready_o  => open,
         nmi_vector_i => X"00",
         irq_valid_i  => '0',
         irq_ready_o  => open,
         irq_vector_i => X"00",
         halted_o     => halted,
         regs_o       => open,
         retire_o     => open
      ); -- i_core


   i_wb_mem : entity work.wb_mem
      generic map (
         G_INIT_FILE => G_BIN_FILE
      )
      port map (
         clk_i           => clk,
         rst_i           => rst,
         ibus_cyc_i      => ibus_cyc,
         ibus_stb_i      => ibus_stb,
         ibus_stall_o    => ibus_stall,
         ibus_ack_o      => ibus_ack,
         ibus_addr_i     => ibus_addr,
         ibus_data_o     => ibus_data,
         dbus_cyc_i      => dbus_cyc,
         dbus_stb_i      => dbus_stb,
         dbus_stall_o    => dbus_stall,
         dbus_ack_o      => dbus_ack,
         dbus_we_i       => dbus_we,
         dbus_addr_i     => dbus_addr,
         dbus_data_i     => dbus_data_out,
         dbus_data_o     => dbus_data_in,
         console_valid_o => console_valid,
         console_data_o  => console_data
      ); -- i_wb_mem


   p_console : process
      file     out_file : text open write_mode is G_OUT_FILE;
      variable line_v   : line;
      variable cycles_v : natural := 0;
   begin
      wait until rising_edge(clk);
      if rst = '0' then
         if console_valid = '1' then
            if console_data = X"0A" then
               writeline(out_file, line_v);
            else
               write(line_v, character'val(to_integer(console_data)));
            end if;
         end if;

         if halted = '1' then
            if line_v /= null and line_v'length > 0 then
               writeline(out_file, line_v);
            end if;
            report "tb_hello: core halted after " & integer'image(cycles_v) & " cycles";
            stop(0);
         end if;

         cycles_v := cycles_v + 1;
         if cycles_v = G_TIMEOUT then
            report "tb_hello: timeout, the core did not halt"
               severity failure;
         end if;
      end if;
   end process p_console;

end architecture simulation;
