-- The sender of the TCP server's segments (src/eth/eth_tcp_tx.vhd), with
-- its properties, for SymbiYosys. Every input is free, but for the
-- sender's contracts: a segment offered stays, with its fields, until it
-- is taken, and the addresses stay while the sender is busy. The send
-- buffer has 4 bytes, and a segment at most 2.
--
-- RESET
-- The first cycle is a reset.

library ieee;
   use ieee.std_logic_1164.all;

   use work.eth_pkg.all;

entity formal_eth_tcp_tx is
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;
      mac_i       : in  std_logic_vector(47 downto 0);
      ip_i        : in  std_logic_vector(31 downto 0);
      seg_valid_i : in  std_logic;
      seg_host_i  : in  t_host;
      seg_seq_i   : in  std_logic_vector(31 downto 0);
      seg_ack_i   : in  std_logic_vector(31 downto 0);
      seg_flags_i : in  std_logic_vector(7 downto 0);
      seg_wnd_i   : in  std_logic_vector(15 downto 0);
      seg_addr_i  : in  std_logic_vector(1 downto 0);
      seg_n_i     : in  natural range 0 to 2;
      rd_data_i   : in  std_logic_vector(7 downto 0);
      tx_ready_i  : in  std_logic
   );
end entity formal_eth_tcp_tx;

architecture synthesis of formal_eth_tcp_tx is

   signal seg_ready : std_logic;
   signal busy      : std_logic;
   signal rd_addr   : std_logic_vector(1 downto 0);
   signal tx_data   : std_logic_vector(7 downto 0);
   signal tx_last   : std_logic;
   signal tx_valid  : std_logic;

begin

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;
   -- psl f_valid : assume always {seg_valid_i and not seg_ready and not rst_i} |=>
   --    {seg_valid_i = '1' and
   --     seg_host_i = prev(seg_host_i) and seg_seq_i = prev(seg_seq_i) and
   --     seg_ack_i = prev(seg_ack_i) and seg_flags_i = prev(seg_flags_i) and
   --     seg_wnd_i = prev(seg_wnd_i) and seg_addr_i = prev(seg_addr_i) and
   --     seg_n_i = prev(seg_n_i)};
   -- psl f_stable : assume always busy = '1' and prev(busy) = '1' ->
   --    mac_i = prev(mac_i) and ip_i = prev(ip_i);


   i_eth_tcp_tx : entity work.eth_tcp_tx
      generic map (
         G_PORT      => 4510,
         G_ADDR_BITS => 2,
         G_MSS       => 2,
         G_FORMAL    => true
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         mac_i       => mac_i,
         ip_i        => ip_i,
         seg_valid_i => seg_valid_i,
         seg_ready_o => seg_ready,
         busy_o      => busy,
         seg_host_i  => seg_host_i,
         seg_seq_i   => seg_seq_i,
         seg_ack_i   => seg_ack_i,
         seg_flags_i => seg_flags_i,
         seg_wnd_i   => seg_wnd_i,
         seg_addr_i  => seg_addr_i,
         seg_n_i     => seg_n_i,
         rd_addr_o   => rd_addr,
         rd_data_i   => rd_data_i,
         tx_data_o   => tx_data,
         tx_last_o   => tx_last,
         tx_valid_o  => tx_valid,
         tx_ready_i  => tx_ready_i
      ); -- i_eth_tcp_tx

end architecture synthesis;
