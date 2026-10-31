-- The debugger's adapter to the debug link's side port
-- (src/dbg/dbg_host.vhd), with its properties, for SymbiYosys. Every
-- input is free: the requests, and the side port's done, its refusal, and
-- its word, so the link may answer anything at any time, also while no
-- word is out, which the adapter must ignore.
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
      side_done_i : in  std_logic;
      side_err_i  : in  std_logic;
      side_data_i : in  std_logic_vector(31 downto 0)
   );
end entity formal_dbg_host;

architecture synthesis of formal_dbg_host is

   signal req_ready  : std_logic;
   signal rd_valid   : std_logic;
   signal rd_data    : std_logic_vector(31 downto 0);
   signal done       : std_logic;
   signal err        : std_logic;
   signal err_code   : std_logic_vector(7 downto 0);
   signal side_valid : std_logic;
   signal side_we    : std_logic;
   signal side_addr  : std_logic_vector(31 downto 0);
   signal side_data  : std_logic_vector(31 downto 0);

begin

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;


   i_dbg_host : entity work.dbg_host
      generic map (
         G_FORMAL => true
      )
      port map (
         clk_i        => clk_i,
         rst_i        => rst_i,
         req_valid_i  => req_valid_i,
         req_ready_o  => req_ready,
         req_we_i     => req_we_i,
         req_addr_i   => req_addr_i,
         req_n_i      => req_n_i,
         req_data_i   => req_data_i,
         rd_valid_o   => rd_valid,
         rd_data_o    => rd_data,
         done_o       => done,
         err_o        => err,
         err_code_o   => err_code,
         side_valid_o => side_valid,
         side_we_o    => side_we,
         side_addr_o  => side_addr,
         side_data_o  => side_data,
         side_done_i  => side_done_i,
         side_err_i   => side_err_i,
         side_data_i  => side_data_i
      ); -- i_dbg_host

end architecture synthesis;
