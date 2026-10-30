-- A free choice of the TCP server's segments, with a free sender, for
-- formal/eth_tcp.sby: an architecture of src/eth/eth_tcp_pick.vhd's entity
-- that does, on its ports to the connection, anything that the real
-- chooser may do, as formal/eth_tcp_pick.sby proves it, so that the
-- connection's job spends no time on building and sending frames. GHDL
-- binds the architecture analyzed last, so eth_tcp.sby analyzes this file
-- after eth_tcp_pick.vhd.
--
-- THEORY OF OPERATION
-- A segment is chosen (pick_o, with pick_n_o) in any cycle in which none
-- is sent (busy_o), none was for the two cycles before, and drop_i has
-- been '0' for those three cycles, as the real chooser works out what may
-- be sent in two cycles and chooses in the third. What is chosen is free
-- but for what eth_tcp_pick.sby proves of it, from the connection as it
-- is in that cycle: the SYN-ACK while it is owed and the connection waits
-- for its ACK; data once the connection is open, at most G_MSS bytes, no
-- more than there is, and within the host's window, but for a probe of
-- one byte; the FIN once the connection is open, this side closing, and
-- all of the data before it sent, unless it has been; an ACK alone while
-- one is owed and the connection is open; and the RST asked for, with ACK
-- or without as asked. The segment is sent (busy_o) from the cycle after
-- it is chosen, for any number of cycles, and adv_wnd_o is free_i at the
-- choice of each segment but a RST. The frames to send are free, and the
-- send buffer is read at a free address.
--
-- RESET
-- Synchronous, to clk_i. Reset drops the segment.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use work.eth_pkg.all;

architecture formal of eth_tcp_pick is

   constant C_FIN : std_logic_vector(7 downto 0) := X"01";
   constant C_SYN : std_logic_vector(7 downto 0) := X"02";
   constant C_RST : std_logic_vector(7 downto 0) := X"04";
   constant C_PSH : std_logic_vector(7 downto 0) := X"08";
   constant C_ACK : std_logic_vector(7 downto 0) := X"10";

   -- Cycles with no segment sent and no drop, as far as 2
   signal quiet : natural range 0 to 2 := 0;
   signal busy  : std_logic            := '0';
   signal pick  : std_logic_vector(7 downto 0);
   signal ok    : boolean;

   -- What the solver picks: the segment and its length, the end of the
   -- one being sent, and the frames and reads
   signal any_pick : std_logic_vector(7 downto 0);
   signal any_n    : std_logic_vector(15 downto 0);
   signal any_done : std_logic;
   signal any_tx   : std_logic_vector(9 downto 0);
   signal any_addr : std_logic_vector(G_ADDR_BITS - 1 downto 0);

   attribute anyseq : boolean;
   attribute anyseq of any_pick : signal is true;
   attribute anyseq of any_n    : signal is true;
   attribute anyseq of any_done : signal is true;
   attribute anyseq of any_tx   : signal is true;
   attribute anyseq of any_addr : signal is true;

begin

   -- What the real chooser may choose, from the connection as it is
   ok <= any_pick = X"00" or
         (any_pick = (C_SYN or C_ACK) and syn_req_i = '1' and syn_rcvd_i = '1') or
         (any_pick = (C_ACK or C_PSH) and estab_i = '1' and
           any_n /= 0 and to_integer(any_n) <= G_MSS and
           to_integer(any_n) <= to_integer(lim_ptr_i - nxt_ptr_i) and
           (to_integer(any_n) + to_integer(nxt_ptr_i - una_ptr_i) <= to_integer(snd_wnd_i) or
              (probe_i = '1' and any_n = 1))) or
         (any_pick = (C_FIN or C_ACK) and estab_i = '1' and closing_i = '1' and
           nxt_ptr_i = lim_ptr_i and fin_sent_i = '0') or
         (any_pick = C_ACK and estab_i = '1' and ack_req_i = '1') or
         (any_pick = (C_RST or C_ACK) and rst_req_i = '1' and rst_ack_i = '1') or
         (any_pick = C_RST and rst_req_i = '1' and rst_ack_i = '0');

   pick <= any_pick when quiet = 2 and drop_i = '0' and ok else
           X"00";

   pick_o     <= pick;
   pick_n_o   <= to_integer(any_n) when pick(3) = '1' else
                 0;
   busy_o     <= busy;
   rd_addr_o  <= any_addr;
   tx_data_o  <= any_tx(7 downto 0);
   tx_last_o  <= any_tx(8);
   tx_valid_o <= any_tx(9);

   p_free : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if busy = '0' and drop_i = '0' then
            if quiet < 2 then
               quiet <= quiet + 1;
            end if;
         else
            quiet <= 0;
         end if;

         if busy = '1' and any_done = '1' then
            busy <= '0';
         end if;

         if pick /= X"00" then
            busy  <= '1';
            quiet <= 0;
            if pick(2) = '0' then
               adv_wnd_o <= free_i;
            end if;
         end if;

         if rst_i = '1' then
            busy  <= '0';
            quiet <= 0;
         end if;
      end if;
   end process p_free;

end architecture formal;
