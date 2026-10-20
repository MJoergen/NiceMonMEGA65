-- The debug link of PROTOCOL.md: it splits the bytes from the UART into the
-- console input of the core and the requests of the host, which it serves
-- as a Wishbone master, and it merges the console output of the core, its
-- answers, and its notices into the bytes to the UART.
--
-- THEORY OF OPERATION
-- p_rx takes the bytes from the UART. Outside a packet, a byte other than
-- ESC (0xFF) is a console byte, which goes out on con_rx_*_o for a cycle,
-- and ESC ESC is the console byte 0xFF. ESC R, P, or W starts a request: the
-- six bytes of its header, the address and the count, follow. A R or P
-- request reads a word at a time through the Wishbone port and sends it,
-- and a W request takes four bytes at a time and writes them as a word.
-- While it reads or sends, p_rx takes no byte from the UART, which keeps
-- the next one, for the host sends nothing then (PROTOCOL.md). A request
-- that waits for a byte for longer than C_TIMEOUT cycles is dropped.
--
-- The Wishbone port is used as cmd.vhd of cmod-s7 did: STB is '1' for one
-- cycle, CYC until the ACK, and the request is latched by the system, so
-- STALL is not needed.
--
-- The bytes to the UART are chosen in this order: the second byte of an
-- escaped console byte 0xFF, so that the pair stays together; the answer
-- that p_rx is sending, a byte at a time on ans_*, while ans_open is '1';
-- a notice; and a console byte of the core. So no byte comes between the
-- bytes of a packet. A notice is a reset notice, "b", after reset, or a
-- stop notice, "h", when stop_i is '1' for a cycle. The system raises
-- stop_i only once the core's last console byte has been taken here, so
-- that it comes before the notice.
--
-- With G_FORMAL, it states the properties that formal/link.sby proves: the
-- Wishbone request is one STB pulse with CYC held until its ACK, and no
-- new request while one waits; a byte from the UART outside a packet is
-- the console byte of the next cycle; and the bytes to the UART keep each
-- packet together: the ESC of a console byte 0xFF is followed by the
-- second ESC, the ESC of a notice by its tag, and the ESC of an answer by
-- its tag. A stop is not lost while a notice is sent.
--
-- RESET
-- Synchronous. It drops a request, and sends the reset notice.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity link is
   generic (
      G_CLOCK_HZ : natural;
      -- The properties for formal/link.sby
      G_FORMAL   : boolean := false
   );
   port (
      clk_i          : in  std_logic;
      rst_i          : in  std_logic;
      -- The UART
      ser_rx_valid_i : in  std_logic;
      ser_rx_ready_o : out std_logic;
      ser_rx_data_i  : in  std_logic_vector(7 downto 0);
      ser_tx_valid_o : out std_logic;
      ser_tx_ready_i : in  std_logic;
      ser_tx_data_o  : out std_logic_vector(7 downto 0);
      -- The console: the bytes for the core, and the core's bytes
      con_rx_valid_o : out std_logic;
      con_rx_data_o  : out std_logic_vector(7 downto 0);
      con_tx_valid_i : in  std_logic;
      con_tx_ready_o : out std_logic;
      con_tx_data_i  : in  std_logic_vector(7 downto 0);
      -- The core has stopped, for the reason given (PROTOCOL.md).
      stop_i         : in  std_logic;
      stop_reason_i  : in  std_logic_vector(7 downto 0);
      -- Wishbone master
      wb_cyc_o       : out std_logic;
      wb_stb_o       : out std_logic;
      wb_we_o        : out std_logic;
      wb_addr_o      : out std_logic_vector(31 downto 0);
      wb_data_o      : out std_logic_vector(31 downto 0);
      wb_data_i      : in  std_logic_vector(31 downto 0);
      wb_ack_i       : in  std_logic
   );
end entity link;

architecture synthesis of link is

   constant C_ESC     : std_logic_vector(7 downto 0) := X"FF";
   constant C_VERSION : std_logic_vector(7 downto 0) := X"01";
   -- 10 ms
   constant C_TIMEOUT : natural := G_CLOCK_HZ / 100;

   -- The tags, as ASCII
   constant C_TAG_R  : std_logic_vector(7 downto 0) := X"52";
   constant C_TAG_P  : std_logic_vector(7 downto 0) := X"50";
   constant C_TAG_W  : std_logic_vector(7 downto 0) := X"57";
   constant C_TAG_RD : std_logic_vector(7 downto 0) := X"72";   -- r
   constant C_TAG_OK : std_logic_vector(7 downto 0) := X"6B";   -- k
   constant C_TAG_B  : std_logic_vector(7 downto 0) := X"62";   -- b
   constant C_TAG_H  : std_logic_vector(7 downto 0) := X"68";   -- h

   type t_state is (
      IDLE_ST,
      ESC_ST,
      HDR_ST,
      ANS_ESC_ST,
      ANS_TAG_ST,
      RD_REQ_ST,
      RD_WAIT_ST,
      RD_SEND_ST,
      WR_DATA_ST,
      WR_WAIT_ST
   );

   signal state   : t_state := IDLE_ST;
   signal op      : std_logic_vector(7 downto 0);
   signal hdr     : std_logic_vector(47 downto 0);
   signal cnt     : natural range 0 to 5;
   signal addr    : std_logic_vector(31 downto 0);
   signal words   : std_logic_vector(15 downto 0);
   signal data    : std_logic_vector(31 downto 0);
   signal idle    : natural range 0 to C_TIMEOUT;
   signal rx_take : std_logic;

   -- The answer, a byte at a time
   signal ans_open  : std_logic := '0';
   signal ans_valid : std_logic;
   signal ans_data  : std_logic_vector(7 downto 0);
   signal ans_ready : std_logic;

   -- The notices waiting, and the one being sent, a byte at a time
   signal boot_wait : std_logic := '1';
   signal stop_wait : std_logic := '0';
   signal stop_why  : std_logic_vector(7 downto 0);
   signal ntc_busy  : std_logic := '0';
   signal ntc_pos   : natural range 0 to 2;
   signal ntc_tag   : std_logic_vector(7 downto 0);
   signal ntc_arg   : std_logic_vector(7 downto 0);
   -- The second ESC of a console byte 0xFF
   signal con_esc : std_logic := '0';

   type t_sel is (SEL_NONE, SEL_ESC, SEL_ANS, SEL_NTC, SEL_CON);

   signal sel : t_sel;

begin

   ---------------------------------------------------------------------------
   -- From the UART
   ---------------------------------------------------------------------------

   rx_take        <= ser_rx_valid_i when state = IDLE_ST or state = ESC_ST or
                                  state = HDR_ST or state = WR_DATA_ST else
              '0';
   ser_rx_ready_o <= rx_take;

   ans_valid <= '1' when state = ANS_ESC_ST or state = ANS_TAG_ST or state = RD_SEND_ST else
                '0';
   ans_data  <= C_ESC when state = ANS_ESC_ST else
                C_TAG_OK when state = ANS_TAG_ST and op = C_TAG_W else
                C_TAG_RD when state = ANS_TAG_ST else
                data(7 downto 0);

   p_rx : process (clk_i)
   begin
      if rising_edge(clk_i) then
         con_rx_valid_o <= '0';
         wb_stb_o       <= '0';

         if rx_take = '1' or (state /= ESC_ST and state /= HDR_ST and state /= WR_DATA_ST) then
            idle <= 0;
         elsif idle < C_TIMEOUT then
            idle <= idle + 1;
         end if;

         case state is

            when IDLE_ST =>
               if rx_take = '1' then
                  if ser_rx_data_i = C_ESC then
                     state <= ESC_ST;
                  else
                     con_rx_valid_o <= '1';
                     con_rx_data_o  <= ser_rx_data_i;
                  end if;
               end if;

            when ESC_ST =>
               if rx_take = '1' then
                  op  <= ser_rx_data_i;
                  cnt <= 0;
                  if ser_rx_data_i = C_ESC then
                     con_rx_valid_o <= '1';
                     con_rx_data_o  <= C_ESC;
                     state          <= IDLE_ST;
                  elsif ser_rx_data_i = C_TAG_R or ser_rx_data_i = C_TAG_P or
                        ser_rx_data_i = C_TAG_W then
                     state <= HDR_ST;
                  else
                     state <= IDLE_ST;
                  end if;
               end if;

            when HDR_ST =>
               if rx_take = '1' then
                  hdr <= ser_rx_data_i & hdr(47 downto 8);
                  if cnt = 5 then
                     addr  <= hdr(39 downto 8);
                     words <= ser_rx_data_i & hdr(47 downto 40);
                     cnt   <= 0;
                     if op = C_TAG_W and (ser_rx_data_i & hdr(47 downto 40)) /= 0 then
                        state <= WR_DATA_ST;
                     else
                        state <= ANS_ESC_ST;
                     end if;
                  else
                     cnt <= cnt + 1;
                  end if;
               end if;

            when ANS_ESC_ST =>
               ans_open <= '1';
               if ans_ready = '1' then
                  state <= ANS_TAG_ST;
               end if;

            when ANS_TAG_ST =>
               if ans_ready = '1' then
                  if op = C_TAG_W or words = 0 then
                     ans_open <= '0';
                     state    <= IDLE_ST;
                  else
                     state <= RD_REQ_ST;
                  end if;
               end if;

            when RD_REQ_ST =>
               wb_cyc_o  <= '1';
               wb_stb_o  <= '1';
               wb_we_o   <= '0';
               wb_addr_o <= addr;
               state     <= RD_WAIT_ST;

            when RD_WAIT_ST =>
               if wb_ack_i = '1' then
                  wb_cyc_o <= '0';
                  data     <= wb_data_i;
                  cnt      <= 0;
                  words    <= words - 1;
                  if op = C_TAG_R then
                     addr <= addr + 1;
                  end if;
                  state <= RD_SEND_ST;
               end if;

            when RD_SEND_ST =>
               if ans_ready = '1' then
                  data <= X"00" & data(31 downto 8);
                  if cnt = 3 then
                     cnt <= 0;
                     if words = 0 then
                        ans_open <= '0';
                        state    <= IDLE_ST;
                     else
                        state <= RD_REQ_ST;
                     end if;
                  else
                     cnt <= cnt + 1;
                  end if;
               end if;

            when WR_DATA_ST =>
               if rx_take = '1' then
                  data <= ser_rx_data_i & data(31 downto 8);
                  if cnt = 3 then
                     cnt       <= 0;
                     wb_cyc_o  <= '1';
                     wb_stb_o  <= '1';
                     wb_we_o   <= '1';
                     wb_addr_o <= addr;
                     wb_data_o <= ser_rx_data_i & data(31 downto 8);
                     state     <= WR_WAIT_ST;
                  else
                     cnt <= cnt + 1;
                  end if;
               end if;

            when WR_WAIT_ST =>
               if wb_ack_i = '1' then
                  wb_cyc_o <= '0';
                  addr     <= addr + 1;
                  words    <= words - 1;
                  if words = 1 then
                     state <= ANS_ESC_ST;
                  else
                     state <= WR_DATA_ST;
                  end if;
               end if;

         end case;

         -- A request that waits too long for its next byte is dropped, but
         -- not in the cycle that the byte comes, which may start a write.
         if idle = C_TIMEOUT and rx_take = '0' and
            (state = ESC_ST or state = HDR_ST or state = WR_DATA_ST) then
            state <= IDLE_ST;
         end if;

         if rst_i = '1' then
            state    <= IDLE_ST;
            ans_open <= '0';
            wb_cyc_o <= '0';
            wb_stb_o <= '0';
         end if;
      end if;
   end process p_rx;


   ---------------------------------------------------------------------------
   -- To the UART
   ---------------------------------------------------------------------------

   sel <= SEL_ESC when con_esc = '1' else
          SEL_NTC when ntc_busy = '1' else
          SEL_ANS when ans_open = '1' else
          SEL_NTC when boot_wait = '1' or stop_wait = '1' else
          SEL_CON when con_tx_valid_i = '1' else
          SEL_NONE;

   with sel select ser_tx_valid_o <=
      '1' when SEL_ESC | SEL_NTC,
      ans_valid when SEL_ANS,
      '1' when SEL_CON,
      '0' when SEL_NONE;

   ser_tx_data_o <= C_ESC when sel = SEL_ESC else
                    ans_data when sel = SEL_ANS else
                    C_ESC when sel = SEL_NTC and (ntc_busy = '0' or ntc_pos = 0) else
                    ntc_tag when sel = SEL_NTC and ntc_pos = 1 else
                    ntc_arg when sel = SEL_NTC else
                    con_tx_data_i;

   ans_ready <= ser_tx_ready_i when sel = SEL_ANS else
                '0';

   -- A console byte 0xFF is taken after its second ESC.
   con_tx_ready_o <= ser_tx_ready_i when sel = SEL_ESC or
                                         (sel = SEL_CON and con_tx_data_i /= C_ESC) else
                     '0';

   p_tx : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if stop_i = '1' then
            stop_wait <= '1';
            stop_why  <= stop_reason_i;
         end if;

         if ser_tx_ready_i = '1' then

            case sel is

               when SEL_ESC =>
                  con_esc <= '0';

               when SEL_CON =>
                  if con_tx_data_i = C_ESC then
                     con_esc <= '1';
                  end if;

               when SEL_NTC =>
                  if ntc_busy = '0' then
                     -- The ESC of the notice is going now.
                     ntc_busy <= '1';
                     ntc_pos  <= 1;
                     if boot_wait = '1' then
                        boot_wait <= '0';
                        ntc_tag   <= C_TAG_B;
                        ntc_arg   <= C_VERSION;
                     else
                        stop_wait <= stop_i;
                        ntc_tag   <= C_TAG_H;
                        ntc_arg   <= stop_why;
                     end if;
                  elsif ntc_pos = 2 then
                     ntc_busy <= '0';
                  else
                     ntc_pos <= 2;
                  end if;

               when others =>
                  null;

            end case;

         end if;

         if rst_i = '1' then
            boot_wait <= '1';
            stop_wait <= '0';
            ntc_busy  <= '0';
            con_esc   <= '0';
         end if;
      end if;
   end process p_tx;

   ---------------------------------------------------------------------------
   -- The properties of formal/link.sby. f_wait is '1' while a Wishbone
   -- request waits for its ACK. f_tx_* follow the bytes accepted by the
   -- UART: f_con_ff after the first ESC of a console byte 0xFF, f_ntc after
   -- the ESC of a notice, and f_ans after the ESC of an answer. f_state,
   -- f_ranges, f_tx_state, and f_cyc_state hold anyway, and keep k-induction from starting in a state that
   -- cannot be reached. cnt, idle, and ntc_pos have no reset, so f_ranges
   -- holds only while they are in use.
   ---------------------------------------------------------------------------

   gen_formal : if G_FORMAL generate
      signal f_wait   : std_logic := '0';
      signal f_tx     : std_logic;
      signal f_con_ff : std_logic := '0';
      signal f_ntc    : std_logic := '0';
      signal f_ans    : std_logic := '0';
   begin

      f_tx <= ser_tx_valid_o and ser_tx_ready_i;

      p_follow : process (clk_i)
      begin
         if rising_edge(clk_i) then
            if wb_stb_o = '1' then
               f_wait <= '1';
            elsif wb_ack_i = '1' then
               f_wait <= '0';
            end if;

            if f_tx = '1' then
               f_con_ff <= '1' when sel = SEL_CON and con_tx_data_i = C_ESC else '0';
               f_ntc    <= '1' when sel = SEL_NTC and ntc_busy = '0' else '0';
               f_ans    <= '1' when sel = SEL_ANS and state = ANS_ESC_ST else '0';
            end if;

            if rst_i = '1' then
               f_wait   <= '0';
               f_con_ff <= '0';
               f_ntc    <= '0';
               f_ans    <= '0';
            end if;
         end if;
      end process p_follow;

      -- psl default clock is rising_edge(clk_i);

      -- The state and the counters stay in their ranges, for the induction.
      -- psl f_state : assert always
      --    state = IDLE_ST or state = ESC_ST or state = HDR_ST or state = ANS_ESC_ST or
      --    state = ANS_TAG_ST or state = RD_REQ_ST or state = RD_WAIT_ST or
      --    state = RD_SEND_ST or state = WR_DATA_ST or state = WR_WAIT_ST;
      -- psl f_ranges : assert always rst_i = '0' ->
      --    (state = IDLE_ST or idle <= C_TIMEOUT) and
      --    (state /= HDR_ST or cnt <= 5) and
      --    ((state /= WR_DATA_ST and state /= RD_SEND_ST) or cnt <= 3) and
      --    (state = IDLE_ST or state = ESC_ST or state = HDR_ST or state = WR_DATA_ST or
      --     state = RD_SEND_ST or cnt = 0) and
      --    (ntc_busy = '0' or ntc_pos <= 2);
      -- psl f_tx_state : assert always rst_i = '0' ->
      --    f_con_ff = con_esc and (con_esc = '0' or ntc_busy = '0') and
      --    (con_esc = '0' or (con_tx_valid_i = '1' and con_tx_data_i = C_ESC)) and
      --    (f_ntc = '1') = (ntc_busy = '1' and ntc_pos = 1) and
      --    (ntc_busy = '0' or ntc_pos /= 0) and
      --    (ntc_busy = '0' or ntc_tag = C_TAG_B or ntc_tag = C_TAG_H) and
      --    (f_ans = '0' or (state = ANS_TAG_ST and ans_open = '1' and ntc_busy = '0' and
      --                     con_esc = '0'));
      -- psl f_cyc_state : assert always rst_i = '0' ->
      --    (wb_cyc_o = '1') = (state = RD_WAIT_ST or state = WR_WAIT_ST) and
      --    f_wait = (wb_cyc_o and not wb_stb_o);

      -- The Wishbone port
      -- psl f_stb_cyc : assert always rst_i = '0' and wb_stb_o = '1' -> wb_cyc_o = '1';
      -- psl f_stb_pulse : assert always {wb_stb_o and not rst_i} |=> {not wb_stb_o};
      -- psl f_stb_one : assert always rst_i = '0' and wb_stb_o = '1' -> f_wait = '0';
      -- psl f_cyc_req : assert always
      --    rst_i = '0' and wb_cyc_o = '1' -> f_wait = '1' or wb_stb_o = '1';
      -- psl f_cyc_hold : assert always
      --    {f_wait and not wb_ack_i and not rst_i} |=> {wb_cyc_o or rst_i};

      -- The console bytes from the UART
      -- psl f_con_rx : assert always
      --    {rx_take = '1' and state = IDLE_ST and ser_rx_data_i /= C_ESC and rst_i = '0'} |=>
      --    {con_rx_valid_o = '1' and con_rx_data_o = prev(ser_rx_data_i)};
      -- psl f_con_rx_only : assert always {not rx_take} |=> {not con_rx_valid_o};

      -- The packets to the UART stay together.
      -- psl f_tx_con_ff : assert always
      --    f_con_ff and f_tx and not rst_i -> ser_tx_data_o = C_ESC and con_tx_ready_o = '1';
      -- psl f_tx_ntc : assert always
      --    f_ntc and f_tx and not rst_i -> ser_tx_data_o = C_TAG_B or ser_tx_data_o = C_TAG_H;
      -- psl f_tx_ans : assert always
      --    f_ans and f_tx and not rst_i -> ser_tx_data_o = C_TAG_RD or ser_tx_data_o = C_TAG_OK;
      -- psl f_con_tx : assert always
      --    rst_i = '0' and con_tx_ready_o = '1' -> f_tx = '1' and ser_tx_data_o = con_tx_data_i;

      -- A stop waits until its notice is sent.
      -- psl f_stop : assert always {stop_i and not rst_i} |=> {stop_wait or rst_i};

      -- psl c_read : cover {state = RD_SEND_ST and ans_ready = '1' and cnt = 3 and
      --                     words = 0 and op = C_TAG_R and rst_i = '0'};
      -- psl c_write : cover {state = WR_WAIT_ST and wb_ack_i = '1' and words = 1 and
      --                      rst_i = '0'};
      -- psl c_stop : cover {f_tx = '1' and sel = SEL_NTC and ntc_pos = 2 and
      --                     ntc_tag = C_TAG_H and rst_i = '0'};
      -- psl c_con_ff : cover {f_con_ff and f_tx and not rst_i};
      -- psl c_dropped : cover {idle = C_TIMEOUT and state = HDR_ST and rst_i = '0'};
   end generate gen_formal;

end architecture synthesis;
