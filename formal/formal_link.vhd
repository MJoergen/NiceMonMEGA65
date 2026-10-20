-- The debug link (src/link.vhd), with its properties, for SymbiYosys. Every
-- input is free, so the solver sends any byte from the UART in any cycle,
-- takes bytes for the UART at any time, raises stop_i, and answers the
-- Wishbone requests. The UART bytes come without their serial frames, so a
-- request completes in a few cycles. The clock rate gives a timeout of 5
-- cycles, so that the solver soon reaches it.
--
-- THEORY OF OPERATION
-- The assumptions are what nicemon.vhd gives the link: an ACK only for a
-- request that waits, and a console byte of the core that is held until
-- the link takes it.
--
-- RESET
-- The first cycle is a reset.

library ieee;
   use ieee.std_logic_1164.all;

entity formal_link is
   port (
      clk_i          : in  std_logic;
      rst_i          : in  std_logic;
      ser_rx_valid_i : in  std_logic;
      ser_rx_data_i  : in  std_logic_vector(7 downto 0);
      ser_tx_ready_i : in  std_logic;
      con_tx_valid_i : in  std_logic;
      con_tx_data_i  : in  std_logic_vector(7 downto 0);
      stop_i         : in  std_logic;
      stop_reason_i  : in  std_logic_vector(7 downto 0);
      wb_data_i      : in  std_logic_vector(31 downto 0);
      wb_ack_i       : in  std_logic
   );
end entity formal_link;

architecture synthesis of formal_link is

   signal ser_rx_ready : std_logic;
   signal ser_tx_valid : std_logic;
   signal ser_tx_data  : std_logic_vector(7 downto 0);
   signal con_rx_valid : std_logic;
   signal con_rx_data  : std_logic_vector(7 downto 0);
   signal con_tx_ready : std_logic;
   signal wb_cyc       : std_logic;
   signal wb_stb       : std_logic;
   signal wb_we        : std_logic;
   signal wb_addr      : std_logic_vector(31 downto 0);
   signal wb_data      : std_logic_vector(31 downto 0);

   -- A request waits for its ACK.
   signal waits : std_logic := '0';

   -- The console byte that waited in the cycle before
   signal held      : std_logic := '0';
   signal held_data : std_logic_vector(7 downto 0);

begin

   p_waits : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if wb_stb = '1' then
            waits <= '1';
         elsif wb_ack_i = '1' then
            waits <= '0';
         end if;
         if rst_i = '1' then
            waits <= '0';
         end if;
      end if;
   end process p_waits;

   p_held : process (clk_i)
   begin
      if rising_edge(clk_i) then
         held      <= con_tx_valid_i and not con_tx_ready and not rst_i;
         held_data <= con_tx_data_i;
      end if;
   end process p_held;

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;
   -- psl f_ack : assume always wb_ack_i -> waits;
   -- waits is what link.vhd's f_wait is, for the induction
   -- psl f_waits : assert always rst_i = '0' -> waits = (wb_cyc and not wb_stb);
   -- A console byte that waits stays until it is taken. This is a plain
   -- implication on the registers of p_held, for an assumption with |=>
   -- does not constrain the last step of the induction in Yosys 0.33.
   -- psl f_con_hold : assume always
   --    held = '1' -> rst_i = '1' or (con_tx_valid_i = '1' and con_tx_data_i = held_data);


   i_link : entity work.link
      generic map (
         G_CLOCK_HZ => 500,
         G_FORMAL   => true
      )
      port map (
         clk_i          => clk_i,
         rst_i          => rst_i,
         ser_rx_valid_i => ser_rx_valid_i,
         ser_rx_ready_o => ser_rx_ready,
         ser_rx_data_i  => ser_rx_data_i,
         ser_tx_valid_o => ser_tx_valid,
         ser_tx_ready_i => ser_tx_ready_i,
         ser_tx_data_o  => ser_tx_data,
         con_rx_valid_o => con_rx_valid,
         con_rx_data_o  => con_rx_data,
         con_tx_valid_i => con_tx_valid_i,
         con_tx_ready_o => con_tx_ready,
         con_tx_data_i  => con_tx_data_i,
         stop_i         => stop_i,
         stop_reason_i  => stop_reason_i,
         wb_cyc_o       => wb_cyc,
         wb_stb_o       => wb_stb,
         wb_we_o        => wb_we,
         wb_addr_o      => wb_addr,
         wb_data_o      => wb_data,
         wb_data_i      => wb_data_i,
         wb_ack_i       => wb_ack_i
      ); -- i_link

end architecture synthesis;
