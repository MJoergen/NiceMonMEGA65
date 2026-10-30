-- The arbiter of the Ethernet station's frames to send
-- (src/eth/eth_arb.vhd), with its properties, for SymbiYosys. The inputs
-- are free but for the arbiter's contract: the two responders are never
-- valid together. A source need not hold its byte until it is taken; the
-- properties do not depend on it.
--
-- RESET
-- The first cycle is a reset.

library ieee;
   use ieee.std_logic_1164.all;

entity formal_eth_arb is
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;
      arp_data_i   : in  std_logic_vector(7 downto 0);
      arp_last_i   : in  std_logic;
      arp_valid_i  : in  std_logic;
      icmp_data_i  : in  std_logic_vector(7 downto 0);
      icmp_last_i  : in  std_logic;
      icmp_valid_i : in  std_logic;
      tcp_data_i   : in  std_logic_vector(7 downto 0);
      tcp_last_i   : in  std_logic;
      tcp_valid_i  : in  std_logic;
      out_ready_i  : in  std_logic
   );
end entity formal_eth_arb;

architecture synthesis of formal_eth_arb is

   signal resp_ready : std_logic;
   signal tcp_ready  : std_logic;
   signal out_data   : std_logic_vector(7 downto 0);
   signal out_last   : std_logic;
   signal out_valid  : std_logic;

begin

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;
   -- psl f_apart : assume always not (arp_valid_i = '1' and icmp_valid_i = '1');


   i_eth_arb : entity work.eth_arb
      generic map (
         G_FORMAL => true
      )
      port map (
         clk_i        => clk_i,
         rst_i        => rst_i,
         arp_data_i   => arp_data_i,
         arp_last_i   => arp_last_i,
         arp_valid_i  => arp_valid_i,
         icmp_data_i  => icmp_data_i,
         icmp_last_i  => icmp_last_i,
         icmp_valid_i => icmp_valid_i,
         resp_ready_o => resp_ready,
         tcp_data_i   => tcp_data_i,
         tcp_last_i   => tcp_last_i,
         tcp_valid_i  => tcp_valid_i,
         tcp_ready_o  => tcp_ready,
         out_data_o   => out_data,
         out_last_o   => out_last,
         out_valid_o  => out_valid,
         out_ready_i  => out_ready_i
      ); -- i_eth_arb

end architecture synthesis;
