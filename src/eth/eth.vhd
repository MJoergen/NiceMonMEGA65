-- The Ethernet station: the RMII pins of the PHY on one side, and on the
-- other, in the system clock domain, its MAC and IP addresses and the
-- counts of its frames. It answers the ARP requests for its IP address.
--
-- THEORY OF OPERATION
-- The receive pins go to the RMII receiver (rmii_rx.vhd) in the PHY's
-- 50 MHz clock domain, and its bytes to the check of the frame check
-- sequence (rx_fcs.vhd). The good frames go through the FIFO of received
-- frames (eth_rx_fifo.vhd) to clk_i, where the MAC address filter and ARP
-- responder (eth_arp.vhd) read them and write their replies to the FIFO of
-- frames to send (eth_tx_fifo.vhd), which takes them back to the PHY's
-- clock, to the RMII transmitter (rmii_tx.vhd) and the transmit pins.
-- Each frame that comes out of the FIFO of received frames counts in rx_o,
-- and each that goes into the FIFO of frames to send in tx_o. Each bad
-- frame, and each good one that found the FIFO full, flips rx_toggle in the
-- PHY's clock domain; two registers synchronize it to clk_i, where each
-- change counts in rx_bad_o. A frame takes more than 100 cycles of the
-- PHY's clock, so no change is lost.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) eth_clk_i is the PHY's 50 MHz reference clock, and eth_rst_i is
--    synchronous to it.
-- b) rst_i and eth_rst_i are both held for longer than three cycles of each
--    clock, at the same time, as the FIFOs need (eth_rx_fifo.vhd).
-- c) mac_i and ip_i change only between frames (eth_arp.vhd).
--
-- RESET
-- Synchronous, by rst_i in the system clock domain and by eth_rst_i in the
-- PHY's. rst_i clears the counts.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity eth is
   port (
      -- The system clock domain
      clk_i     : in  std_logic;
      rst_i     : in  std_logic;
      mac_i     : in  std_logic_vector(47 downto 0);
      ip_i      : in  std_logic_vector(31 downto 0);
      -- The good frames received, the bad or dropped ones, and those sent
      rx_o      : out std_logic_vector(31 downto 0);
      rx_bad_o  : out std_logic_vector(31 downto 0);
      tx_o      : out std_logic_vector(31 downto 0);

      -- The PHY's pins, in its clock domain
      eth_clk_i : in  std_logic;
      eth_rst_i : in  std_logic;
      rxd_i     : in  std_logic_vector(1 downto 0);
      crs_dv_i  : in  std_logic;
      txd_o     : out std_logic_vector(1 downto 0);
      tx_en_o   : out std_logic
   );
end entity eth;

architecture synthesis of eth is

   -- The frames received, in the PHY's clock domain
   signal rx_data  : std_logic_vector(7 downto 0);
   signal rx_valid : std_logic;
   signal rx_eof   : std_logic;
   signal rx_err   : std_logic;
   signal rx_ok    : std_logic;
   signal rx_bad   : std_logic;
   signal rx_drop  : std_logic;
   -- Flips at each bad or dropped frame
   signal rx_toggle : std_logic := '0';

   -- The good frames, in the system clock domain
   signal in_data  : std_logic_vector(7 downto 0);
   signal in_last  : std_logic;
   signal in_valid : std_logic;
   signal in_ready : std_logic;
   -- The frames to send, in the system clock domain
   signal out_data  : std_logic_vector(7 downto 0);
   signal out_last  : std_logic;
   signal out_valid : std_logic;
   signal out_ready : std_logic;

   -- The frames to send, in the PHY's clock domain
   signal tx_data  : std_logic_vector(7 downto 0);
   signal tx_last  : std_logic;
   signal tx_valid : std_logic;
   signal tx_ready : std_logic;

   -- rx_toggle synchronized to clk_i, its value before, and the counts
   signal rx_sync     : std_logic_vector(1 downto 0)  := "00";
   signal rx_toggle_d : std_logic                     := '0';
   signal rx_cnt      : std_logic_vector(31 downto 0) := (others => '0');
   signal rx_bad_cnt  : std_logic_vector(31 downto 0) := (others => '0');
   signal tx_cnt      : std_logic_vector(31 downto 0) := (others => '0');

   attribute async_reg : string;
   attribute async_reg of rx_sync : signal is "TRUE";

begin

   i_rmii_rx : entity work.rmii_rx
      port map (
         clk_i    => eth_clk_i,
         rst_i    => eth_rst_i,
         rxd_i    => rxd_i,
         crs_dv_i => crs_dv_i,
         data_o   => rx_data,
         valid_o  => rx_valid,
         eof_o    => rx_eof,
         err_o    => rx_err
      ); -- i_rmii_rx

   i_rx_fcs : entity work.rx_fcs
      port map (
         clk_i   => eth_clk_i,
         rst_i   => eth_rst_i,
         data_i  => rx_data,
         valid_i => rx_valid,
         eof_i   => rx_eof,
         err_i   => rx_err,
         ok_o    => rx_ok,
         bad_o   => rx_bad
      ); -- i_rx_fcs

   i_eth_rx_fifo : entity work.eth_rx_fifo
      port map (
         wr_clk_i   => eth_clk_i,
         wr_rst_i   => eth_rst_i,
         wr_data_i  => rx_data,
         wr_valid_i => rx_valid,
         wr_ok_i    => rx_ok,
         wr_bad_i   => rx_bad,
         wr_drop_o  => rx_drop,
         rd_clk_i   => clk_i,
         rd_rst_i   => rst_i,
         rd_data_o  => in_data,
         rd_last_o  => in_last,
         rd_valid_o => in_valid,
         rd_ready_i => in_ready
      ); -- i_eth_rx_fifo

   i_eth_arp : entity work.eth_arp
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         mac_i      => mac_i,
         ip_i       => ip_i,
         rx_data_i  => in_data,
         rx_last_i  => in_last,
         rx_valid_i => in_valid,
         rx_ready_o => in_ready,
         tx_data_o  => out_data,
         tx_last_o  => out_last,
         tx_valid_o => out_valid,
         tx_ready_i => out_ready
      ); -- i_eth_arp

   i_eth_tx_fifo : entity work.eth_tx_fifo
      port map (
         wr_clk_i   => clk_i,
         wr_rst_i   => rst_i,
         wr_data_i  => out_data,
         wr_last_i  => out_last,
         wr_valid_i => out_valid,
         wr_ready_o => out_ready,
         rd_clk_i   => eth_clk_i,
         rd_rst_i   => eth_rst_i,
         rd_data_o  => tx_data,
         rd_last_o  => tx_last,
         rd_valid_o => tx_valid,
         rd_ready_i => tx_ready
      ); -- i_eth_tx_fifo

   i_rmii_tx : entity work.rmii_tx
      port map (
         clk_i   => eth_clk_i,
         rst_i   => eth_rst_i,
         data_i  => tx_data,
         last_i  => tx_last,
         valid_i => tx_valid,
         ready_o => tx_ready,
         txd_o   => txd_o,
         tx_en_o => tx_en_o
      ); -- i_rmii_tx


   p_rx_toggle : process (eth_clk_i)
   begin
      if rising_edge(eth_clk_i) then
         if rx_bad = '1' or rx_drop = '1' then
            rx_toggle <= not rx_toggle;
         end if;
      end if;
   end process p_rx_toggle;

   p_count : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if in_valid = '1' and in_ready = '1' and in_last = '1' then
            rx_cnt <= rx_cnt + 1;
         end if;

         if out_valid = '1' and out_ready = '1' and out_last = '1' then
            tx_cnt <= tx_cnt + 1;
         end if;

         rx_sync     <= rx_sync(0) & rx_toggle;
         rx_toggle_d <= rx_sync(1);
         if rx_sync(1) /= rx_toggle_d then
            rx_bad_cnt <= rx_bad_cnt + 1;
         end if;

         if rst_i = '1' then
            rx_cnt     <= (others => '0');
            rx_bad_cnt <= (others => '0');
            tx_cnt     <= (others => '0');
         end if;
      end if;
   end process p_count;

   rx_o     <= rx_cnt;
   rx_bad_o <= rx_bad_cnt;
   tx_o     <= tx_cnt;

end architecture synthesis;
