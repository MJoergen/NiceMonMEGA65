-- The command line interpreter (CLI) of nicemon.vhd, the line buffer and
-- cmd.vhd, with checks of its ports and of the handshake between the two,
-- for SymbiYosys. Every input is free, so the solver types every line, at
-- any speed, plays every UART transmitter and every bus slave, and sends a
-- halt at any time.
--
-- THEORY OF OPERATION
-- The two are connected as in nicemon.vhd, with C_BUFFER_LEN bytes in a
-- line. The checks are of three kinds:
-- - The serial output, and the line and the message that the line buffer
--   and cmd.vhd hand each other, are valid/ready ports: once VALID is high,
--   it stays high, with the data unchanged, until READY takes it. A line
--   and a message are never empty.
-- - The bus port is a Wishbone master without STALL: nicemon.vhd latches
--   the CLI's request, so cmd.vhd does not wait for STALL, and
--   wb_master_check of nice_cpu, which checks a stalled request, does not
--   apply. STB is high for one cycle, the cycle after a line is taken, and
--   only with CYC. CYC stays high until the ACK, and drops with it, so one
--   request waits at a time; bus_pending is high while it waits. The checks
--   assume that the slave sends ACK only while a request waits.
-- - Each line gets one answer: in the cycle after cmd.vhd takes a line, a
--   bus cycle is open or a message is offered. The bus cycle stays open
--   until its ACK, which is followed by a message, and the message is held
--   until the line buffer takes it. While either is so, no line is taken.
-- The covers show a line that reads a word, one that writes a word, one that
-- is not a command, and the halt message.
--
-- RESET
-- The first cycle is a reset. The checks hold outside reset: cmd.vhd and the
-- line buffer give their outputs no value before the first reset.

library ieee;
   use ieee.std_logic_1164.all;

entity formal_cli is
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;
      rx_valid_i : in  std_logic;
      rx_data_i  : in  std_logic_vector(7 downto 0);
      tx_ready_i : in  std_logic;
      halt_i     : in  std_logic;
      wb_ack_i   : in  std_logic;
      wb_data_i  : in  std_logic_vector(31 downto 0)
   );
end entity formal_cli;

architecture synthesis of formal_cli is

   -- As in nicemon.vhd
   constant C_BUFFER_LEN : natural := 20;

   -- The sizes of the answers of cmd.vhd
   constant C_WHAT_SIZE : natural := 7;
   constant C_HALT_SIZE : natural := 8;

   signal rx_ready : std_logic;
   signal tx_valid : std_logic;
   signal tx_data  : std_logic_vector(7 downto 0);

   signal line_ready : std_logic;
   signal line_valid : std_logic;
   signal line_size  : natural range 0 to C_BUFFER_LEN;
   signal line_data  : std_logic_vector(8 * C_BUFFER_LEN - 1 downto 0);
   signal msg_ready  : std_logic;
   signal msg_valid  : std_logic;
   signal msg_size   : natural range 0 to C_BUFFER_LEN;
   signal msg_data   : std_logic_vector(8 * C_BUFFER_LEN - 1 downto 0);

   signal wb_cyc   : std_logic;
   signal wb_stb   : std_logic;
   signal wb_we    : std_logic;
   signal wb_addr  : std_logic_vector(31 downto 0);
   signal wb_wrdat : std_logic_vector(31 downto 0);

   -- A request has been made, and its ACK has not come
   signal bus_pending : std_logic := '0';

   signal line_take : std_logic;
   signal msg_take  : std_logic;

begin

   line_take <= line_valid and line_ready;
   msg_take  <= msg_valid and msg_ready;

   p_bus_pending : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if wb_stb = '1' then
            bus_pending <= '1';
         elsif wb_ack_i = '1' then
            bus_pending <= '0';
         end if;

         if rst_i = '1' then
            bus_pending <= '0';
         end if;
      end if;
   end process p_bus_pending;

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;

   -- The serial output
   -- psl f_tx_hold : assert always
   --    {tx_valid and not tx_ready_i and not rst_i} |=>
   --    {rst_i = '1' or (tx_valid = '1' and stable(tx_data))};

   -- The line, from the line buffer to cmd.vhd
   -- psl f_line_hold : assert always
   --    {line_valid and not line_ready and not rst_i} |=>
   --    {rst_i = '1' or (line_valid = '1' and stable(line_size) and stable(line_data))};
   -- psl f_line_size : assert always rst_i = '0' and line_valid = '1' -> line_size /= 0;

   -- The message, from cmd.vhd to the line buffer
   -- psl f_msg_hold : assert always
   --    {msg_valid and not msg_ready and not rst_i} |=>
   --    {rst_i = '1' or (msg_valid = '1' and stable(msg_size) and stable(msg_data))};
   -- psl f_msg_size : assert always
   --    rst_i = '0' and msg_valid = '1' -> msg_size /= 0 and msg_size <= C_BUFFER_LEN;

   -- The bus port
   -- psl f_ack_pending : assume always wb_ack_i -> bus_pending;
   -- psl f_stb_cyc : assert always rst_i = '0' -> (wb_stb = '0' or wb_cyc = '1');
   -- psl f_stb_pulse : assert always {wb_stb and not rst_i} |=> {not wb_stb};
   -- psl f_stb_line : assert always {not line_take or rst_i} |=> {not wb_stb};
   -- psl f_stb_one : assert always rst_i = '0' -> (wb_stb = '0' or bus_pending = '0');
   -- psl f_cyc_pending : assert always rst_i = '0' -> (wb_cyc = (wb_stb or bus_pending));
   -- psl f_bus_reset : assert always {rst_i} |=> {not wb_cyc and not wb_stb};

   -- One answer for each line
   -- psl f_line_answer : assert always
   --    {line_take and not rst_i} |=> {rst_i = '1' or wb_cyc = '1' or msg_valid = '1'};
   -- psl f_ack_answer : assert always
   --    {wb_cyc and wb_ack_i and not rst_i} |=> {rst_i = '1' or msg_valid = '1'};
   -- psl f_line_wait : assert always
   --    rst_i = '0' and line_ready = '1' -> wb_cyc = '0' and msg_valid = '0';

   -- psl c_read : cover {line_take and not rst_i; (not rst_i)[*];
   --    wb_cyc and wb_ack_i and not wb_we and not rst_i; (not rst_i)[*];
   --    msg_take and not rst_i};
   -- psl c_write : cover {line_take and not rst_i; (not rst_i)[*];
   --    wb_cyc and wb_ack_i and wb_we and not rst_i; (not rst_i)[*];
   --    msg_take and not rst_i};
   -- psl c_what : cover {line_take and not rst_i; (not rst_i)[*];
   --    msg_take = '1' and msg_size = C_WHAT_SIZE and rst_i = '0'};
   -- psl c_halt : cover {halt_i and not rst_i; (not rst_i)[*];
   --    msg_take = '1' and msg_size = C_HALT_SIZE and rst_i = '0'};


   i_line_buffer : entity work.line_buffer
      generic map (
         G_BUFFER_LEN => C_BUFFER_LEN,
         G_FORMAL     => true
      )
      port map (
         clk_i             => clk_i,
         rst_i             => rst_i,
         rx_ready_o        => rx_ready,
         rx_valid_i        => rx_valid_i,
         rx_data_i         => rx_data_i,
         tx_ready_i        => tx_ready_i,
         tx_valid_o        => tx_valid,
         tx_data_o         => tx_data,
         rx_buffer_ready_i => line_ready,
         rx_buffer_valid_o => line_valid,
         rx_buffer_size_o  => line_size,
         rx_buffer_data_o  => line_data,
         tx_buffer_ready_o => msg_ready,
         tx_buffer_valid_i => msg_valid,
         tx_buffer_size_i  => msg_size,
         tx_buffer_data_i  => msg_data
      ); -- i_line_buffer

   i_cmd : entity work.cmd
      generic map (
         G_ADDR_SIZE  => 32,
         G_BUFFER_LEN => C_BUFFER_LEN,
         G_FORMAL     => true
      )
      port map (
         clk_i             => clk_i,
         rst_i             => rst_i,
         rx_buffer_ready_o => line_ready,
         rx_buffer_valid_i => line_valid,
         rx_buffer_size_i  => line_size,
         rx_buffer_data_i  => line_data,
         tx_buffer_ready_i => msg_ready,
         tx_buffer_valid_o => msg_valid,
         tx_buffer_size_o  => msg_size,
         tx_buffer_data_o  => msg_data,
         halt_i            => halt_i,
         wbus_addr_o       => wb_addr,
         wbus_wrdat_o      => wb_wrdat,
         wbus_we_o         => wb_we,
         wbus_cyc_o        => wb_cyc,
         wbus_stb_o        => wb_stb,
         wbus_rddat_i      => wb_data_i,
         wbus_ack_i        => wb_ack_i
      ); -- i_cmd

end architecture synthesis;
