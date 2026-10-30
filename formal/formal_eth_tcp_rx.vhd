-- The parser of the TCP server's received frames (src/eth/eth_tcp_rx.vhd),
-- with its properties, for SymbiYosys. Every input is free; the
-- properties do not depend on the frame's bytes, and none needs the
-- contracts. The longest frame read is 60 bytes, not 2047, so that
-- "cover" reaches a longer one.
--
-- RESET
-- The first cycle is a reset.

library ieee;
   use ieee.std_logic_1164.all;

   use work.eth_pkg.all;

entity formal_eth_tcp_rx is
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;
      mac_i      : in  std_logic_vector(47 downto 0);
      ip_i       : in  std_logic_vector(31 downto 0);
      rx_data_i  : in  std_logic_vector(7 downto 0);
      rx_last_i  : in  std_logic;
      rx_valid_i : in  std_logic;
      take_i     : in  std_logic;
      exp_ip_i   : in  std_logic_vector(31 downto 0);
      exp_port_i : in  std_logic_vector(15 downto 0);
      exp_seq_i  : in  std_logic_vector(31 downto 0);
      free_i     : in  natural range 0 to 2048
   );
end entity formal_eth_tcp_rx;

architecture synthesis of formal_eth_tcp_rx is

   signal rx_ready : std_logic;
   signal we       : std_logic;
   signal done     : std_logic;
   signal good     : std_logic;
   signal seg      : t_seg;
   signal wr_ok    : std_logic;
   signal len      : natural range 0 to 2 ** 16;

begin

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;


   i_eth_tcp_rx : entity work.eth_tcp_rx
      generic map (
         G_PORT      => 4510,
         G_ADDR_BITS => 11,
         G_MAXF      => 60,
         G_FORMAL    => true
      )
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         mac_i      => mac_i,
         ip_i       => ip_i,
         rx_data_i  => rx_data_i,
         rx_last_i  => rx_last_i,
         rx_valid_i => rx_valid_i,
         rx_ready_o => rx_ready,
         take_i     => take_i,
         exp_ip_i   => exp_ip_i,
         exp_port_i => exp_port_i,
         exp_seq_i  => exp_seq_i,
         free_i     => free_i,
         we_o       => we,
         done_o     => done,
         good_o     => good,
         seg_o      => seg,
         wr_ok_o    => wr_ok,
         len_o      => len
      ); -- i_eth_tcp_rx

end architecture synthesis;
