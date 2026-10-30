-- The debugger's host in hardware (src/dbg/dbg_host.vhd), with its
-- properties, for SymbiYosys. Every input is free: the requests, and the
-- link's bytes and its ready, so the link may answer anything at any time.
-- The timeout is 3 cycles, so that the solver soon reaches it; the
-- properties do not depend on it.
--
-- RESET
-- The first cycle is a reset.

library ieee;
   use ieee.std_logic_1164.all;

entity formal_dbg_host is
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;
      req_valid_i : in  std_logic;
      req_we_i    : in  std_logic;
      req_addr_i  : in  std_logic_vector(31 downto 0);
      req_n_i     : in  std_logic_vector(15 downto 0);
      req_data_i  : in  std_logic_vector(31 downto 0);
      lrx_ready_i : in  std_logic;
      ltx_valid_i : in  std_logic;
      ltx_data_i  : in  std_logic_vector(7 downto 0)
   );
end entity formal_dbg_host;

architecture synthesis of formal_dbg_host is

   signal req_ready : std_logic;
   signal rd_valid  : std_logic;
   signal rd_data   : std_logic_vector(31 downto 0);
   signal done      : std_logic;
   signal err       : std_logic;
   signal err_code  : std_logic_vector(7 downto 0);
   signal ntc_valid : std_logic;
   signal ntc_tag   : std_logic_vector(7 downto 0);
   signal ntc_arg   : std_logic_vector(7 downto 0);
   signal con_valid : std_logic;
   signal con_data  : std_logic_vector(7 downto 0);
   signal lrx_valid : std_logic;
   signal lrx_data  : std_logic_vector(7 downto 0);
   signal ltx_ready : std_logic;

begin

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;


   i_dbg_host : entity work.dbg_host
      generic map (
         G_TIMEOUT => 3,
         G_FORMAL  => true
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         req_valid_i => req_valid_i,
         req_ready_o => req_ready,
         req_we_i    => req_we_i,
         req_addr_i  => req_addr_i,
         req_n_i     => req_n_i,
         req_data_i  => req_data_i,
         rd_valid_o  => rd_valid,
         rd_data_o   => rd_data,
         done_o      => done,
         err_o       => err,
         err_code_o  => err_code,
         ntc_valid_o => ntc_valid,
         ntc_tag_o   => ntc_tag,
         ntc_arg_o   => ntc_arg,
         con_valid_o => con_valid,
         con_data_o  => con_data,
         lrx_valid_o => lrx_valid,
         lrx_ready_i => lrx_ready_i,
         lrx_data_o  => lrx_data,
         ltx_valid_i => ltx_valid_i,
         ltx_ready_o => ltx_ready,
         ltx_data_i  => ltx_data_i
      ); -- i_dbg_host

end architecture synthesis;
