-- The choice of the TCP server's segments (src/eth/eth_tcp_pick.vhd),
-- with its properties, for SymbiYosys, with the sender under it. The
-- inputs are free but for the chooser's contract: the connection's
-- numbers and flags change only in the cycle after a segment is acted on
-- or the timer runs out (drop_i) or a segment is chosen (pick_o), but for
-- the ACK it owes, the end of the data, which grows by a byte a cycle,
-- the room, and the pause; and the pointers are in order, at most a
-- buffer apart. The buffer has 4 bytes and a segment takes 2, so that
-- the solver soon has a whole segment; the properties do not depend on
-- the numbers.
--
-- RESET
-- The first cycle is a reset.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity formal_eth_tcp_pick is
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;
      mac_i       : in  std_logic_vector(47 downto 0);
      ip_i        : in  std_logic_vector(31 downto 0);
      syn_rcvd_i  : in  std_logic;
      estab_i     : in  std_logic;
      syn_req_i   : in  std_logic;
      ack_req_i   : in  std_logic;
      closing_i   : in  std_logic;
      fin_sent_i  : in  std_logic;
      probe_i     : in  std_logic;
      drop_i      : in  std_logic;
      peer_mac_i  : in  std_logic_vector(47 downto 0);
      peer_ip_i   : in  std_logic_vector(31 downto 0);
      peer_port_i : in  std_logic_vector(15 downto 0);
      iss_i       : in  std_logic_vector(31 downto 0);
      una_seq_i   : in  std_logic_vector(31 downto 0);
      rcv_nxt_i   : in  std_logic_vector(31 downto 0);
      snd_wnd_i   : in  std_logic_vector(15 downto 0);
      free_i      : in  natural range 0 to 4;
      una_ptr_i   : in  std_logic_vector(2 downto 0);
      nxt_ptr_i   : in  std_logic_vector(2 downto 0);
      lim_ptr_i   : in  std_logic_vector(2 downto 0);
      paused_i    : in  std_logic;
      rd_data_i   : in  std_logic_vector(7 downto 0);
      tx_ready_i  : in  std_logic
   );
end entity formal_eth_tcp_pick;

architecture synthesis of formal_eth_tcp_pick is

   constant C_SIZE : natural := 4;

   signal pick     : std_logic_vector(7 downto 0);
   signal pick_n   : natural range 0 to 2;
   signal adv_wnd  : natural range 0 to C_SIZE;
   signal busy     : std_logic;
   signal rd_addr  : std_logic_vector(1 downto 0);
   signal tx_data  : std_logic_vector(7 downto 0);
   signal tx_last  : std_logic;
   signal tx_valid : std_logic;

begin

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;
   -- psl f_numbers : assume always {drop_i = '0' and pick = X"00"} |=>
   --    {nxt_ptr_i = prev(nxt_ptr_i) and una_ptr_i = prev(una_ptr_i) and
   --     una_seq_i = prev(una_seq_i) and snd_wnd_i = prev(snd_wnd_i) and
   --     rcv_nxt_i = prev(rcv_nxt_i) and iss_i = prev(iss_i) and
   --     peer_mac_i = prev(peer_mac_i) and peer_ip_i = prev(peer_ip_i) and
   --     peer_port_i = prev(peer_port_i) and fin_sent_i = prev(fin_sent_i) and
   --     closing_i = prev(closing_i) and probe_i = prev(probe_i) and
   --     syn_req_i = prev(syn_req_i) and syn_rcvd_i = prev(syn_rcvd_i) and
   --     estab_i = prev(estab_i) and to_integer(lim_ptr_i - prev(lim_ptr_i)) <= 1};
   -- psl f_ptrs : assume always
   --    to_integer(nxt_ptr_i - una_ptr_i) <= to_integer(lim_ptr_i - una_ptr_i) and
   --    to_integer(lim_ptr_i - una_ptr_i) <= C_SIZE;
   -- psl f_stable : assume always busy = '1' -> mac_i = prev(mac_i) and ip_i = prev(ip_i);


   i_eth_tcp_pick : entity work.eth_tcp_pick
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
         syn_rcvd_i  => syn_rcvd_i,
         estab_i     => estab_i,
         syn_req_i   => syn_req_i,
         ack_req_i   => ack_req_i,
         closing_i   => closing_i,
         fin_sent_i  => fin_sent_i,
         probe_i     => probe_i,
         drop_i      => drop_i,
         peer_mac_i  => peer_mac_i,
         peer_ip_i   => peer_ip_i,
         peer_port_i => peer_port_i,
         iss_i       => iss_i,
         una_seq_i   => una_seq_i,
         rcv_nxt_i   => rcv_nxt_i,
         snd_wnd_i   => snd_wnd_i,
         free_i      => free_i,
         una_ptr_i   => una_ptr_i,
         nxt_ptr_i   => nxt_ptr_i,
         lim_ptr_i   => lim_ptr_i,
         paused_i    => paused_i,
         pick_o      => pick,
         pick_n_o    => pick_n,
         adv_wnd_o   => adv_wnd,
         busy_o      => busy,
         rd_addr_o   => rd_addr,
         rd_data_i   => rd_data_i,
         tx_data_o   => tx_data,
         tx_last_o   => tx_last,
         tx_valid_o  => tx_valid,
         tx_ready_i  => tx_ready_i
      ); -- i_eth_tcp_pick

end architecture synthesis;
