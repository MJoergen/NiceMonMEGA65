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
-- RESET
-- Synchronous. It drops a request, and sends the reset notice.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity link is
   generic (
      G_CLOCK_HZ : natural
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

         -- A request that waits too long for its next byte is dropped.
         if idle = C_TIMEOUT and (state = ESC_ST or state = HDR_ST or state = WR_DATA_ST) then
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

end architecture synthesis;
