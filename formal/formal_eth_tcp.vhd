-- The TCP server's connection (src/eth/eth_tcp.vhd), with its properties,
-- for SymbiYosys. The parser and the chooser, with the sender under it,
-- are free (eth_tcp_rx_free.vhd and eth_tcp_pick_free.vhd): they do
-- anything that the real ones may do, as their own jobs prove. The
-- buffers and the timer are the real ones. Every input is free, but for
-- the server's contract: the station's addresses stay as they are from
-- reset, the IP address 0 among them. The buffers have 4 bytes, a segment
-- 2, a millisecond is 3 cycles, the timeout 2 milliseconds, and the tries
-- 3, so that the solver soon reaches the edges; the properties do not
-- depend on the numbers.
--
-- RESET
-- The first cycle is a reset.

library ieee;
   use ieee.std_logic_1164.all;

entity formal_eth_tcp is
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;
      mac_i       : in  std_logic_vector(47 downto 0);
      ip_i        : in  std_logic_vector(31 downto 0);
      rx_data_i   : in  std_logic_vector(7 downto 0);
      rx_last_i   : in  std_logic;
      rx_valid_i  : in  std_logic;
      tx_ready_i  : in  std_logic;
      lrx_ready_i : in  std_logic;
      ltx_data_i  : in  std_logic_vector(7 downto 0);
      ltx_valid_i : in  std_logic
   );
end entity formal_eth_tcp;

architecture synthesis of formal_eth_tcp is

   signal rx_ready  : std_logic;
   signal tx_data   : std_logic_vector(7 downto 0);
   signal tx_last   : std_logic;
   signal tx_valid  : std_logic;
   signal link_on   : std_logic;
   signal lrx_data  : std_logic_vector(7 downto 0);
   signal lrx_valid : std_logic;
   signal lrx_break : std_logic;
   signal ltx_ready : std_logic;

begin

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;
   -- psl f_addresses : assume always {true} |=> {mac_i = prev(mac_i) and ip_i = prev(ip_i)};


   i_eth_tcp : entity work.eth_tcp
      generic map (
         G_CLOCK_HZ  => 3000,
         G_ADDR_BITS => 2,
         G_MSS       => 2,
         G_IDLE      => 2,
         G_RTO_MS    => 2,
         G_TRIES     => 3,
         G_FORMAL    => true
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         mac_i       => mac_i,
         ip_i        => ip_i,
         rx_data_i   => rx_data_i,
         rx_last_i   => rx_last_i,
         rx_valid_i  => rx_valid_i,
         rx_ready_o  => rx_ready,
         tx_data_o   => tx_data,
         tx_last_o   => tx_last,
         tx_valid_o  => tx_valid,
         tx_ready_i  => tx_ready_i,
         on_o        => link_on,
         lrx_data_o  => lrx_data,
         lrx_valid_o => lrx_valid,
         lrx_ready_i => lrx_ready_i,
         lrx_break_o => lrx_break,
         ltx_data_i  => ltx_data_i,
         ltx_valid_i => ltx_valid_i,
         ltx_ready_o => ltx_ready
      ); -- i_eth_tcp

end architecture synthesis;
