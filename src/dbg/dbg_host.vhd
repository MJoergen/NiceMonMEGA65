-- The host in hardware of the on-board debugger (doc/DEBUGGER.md): it turns
-- a word-level request into a packet of the debug link
-- (nice_cpu/doc/DEBUG.md), and the link's bytes back into the answer, the
-- notices, and the program's console bytes.
--
-- THEORY OF OPERATION
-- Two processes. p_tx sends a request as DEBUG.md §2 frames it: ESC, the
-- tag, the payload in upper-case hex digits, `#`, and the checksum. A read
-- is `R` with A and N; a write is `W` of one word, with A, N = 1, and the
-- word, as the debugger writes one register or one word at a time. A
-- request is taken only while none is open, so the host sends no request
-- before the answer to its last one (DEBUG.md §3).
--
-- p_rx parses every byte from the link: a console byte, ESC ESC as the
-- console byte 0xFF, or a packet. It checks the payload's digits as they
-- come, the length of each field for the tag, and the checksum. The words
-- of an `r` that matches the open request, its A and N, go out on rd_*_o
-- as their last digit arrives, before the checksum is checked, and done_o
-- says at the end whether the whole answer was good: a bad `r` ends in no
-- done_o, and the timeout catches it. A `k` that matches, or an `e` with
-- the request's tag, ends the request; an answer that does not match is
-- dropped, as DEBUG.md §3 says a host does. The notices `b`, `h`, `x`, `p`,
-- and `o` go out on ntc_*_o with their payload byte, and a packet with a
-- bad checksum, length, or tag is dropped.
--
-- The timeout: a request that gets no answer within G_TIMEOUT cycles of
-- the last byte that belongs to a packet, sent or received, ends with
-- done_o and err_o, and the code C_ERR_TIMEOUT. The link answers within
-- 100 ms (DEBUG.md §5), so this happens only if a packet was lost.
--
-- The link's bytes are always taken (ltx_ready_o is '1'), as DEBUG.md's
-- notes for nicemon.vhd ask: a console write of the core waits for the
-- byte before it. The outputs rd_*, ntc_*, con_*, and done_o are pulses of
-- one cycle, with no ready: the words of an `r` come at least 8 cycles
-- apart, and the notices and the console bytes at most one a cycle.
--
-- FORMAL
-- With G_FORMAL, p_f_out parses the bytes that the link takes, as DEBUG.md
-- §1 and §2 frame them: every packet is whole, an `R` with 12 or a `W`
-- with 20 upper-case hex digits, `#`, and its checksum, the digits are the
-- request's fields, and no console byte goes out. A byte offered stays
-- until it is taken. formal/dbg_host.sby proves it.
--
-- RESET
-- Synchronous to clk_i, by rst_i. No request is open, and the parser waits
-- for a console byte or ESC.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity dbg_host is
   generic (
      -- The most clock cycles that a request waits for the next byte of
      -- its answer
      G_TIMEOUT : positive := 10_000_000;
      -- The properties of formal/dbg_host.sby
      G_FORMAL  : boolean  := false
   );
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;

      -- A request: with req_we_i '0', an R of req_n_i words from
      -- req_addr_i; with '1', a W of the one word req_data_i there
      req_valid_i : in  std_logic;
      req_ready_o : out std_logic;
      req_we_i    : in  std_logic;
      req_addr_i  : in  std_logic_vector(31 downto 0);
      req_n_i     : in  std_logic_vector(15 downto 0);
      req_data_i  : in  std_logic_vector(31 downto 0);

      -- The words of the `r`, in order
      rd_valid_o  : out std_logic;
      rd_data_o   : out std_logic_vector(31 downto 0);

      -- The end of the request: err_o '0' for a `k` or a good `r`, and '1'
      -- for an `e`, with its code, or C_ERR_TIMEOUT
      done_o      : out std_logic;
      err_o       : out std_logic;
      err_code_o  : out std_logic_vector(7 downto 0);

      -- A notice: its tag, b, h, x, p, or o, and its payload byte, the
      -- version, the halt reason, or the breakpoint, or 0
      ntc_valid_o : out std_logic;
      ntc_tag_o   : out std_logic_vector(7 downto 0);
      ntc_arg_o   : out std_logic_vector(7 downto 0);

      -- A console byte that the program wrote
      con_valid_o : out std_logic;
      con_data_o  : out std_logic_vector(7 downto 0);

      -- The link's byte streams: to its receiver, and from its transmitter
      lrx_valid_o : out std_logic;
      lrx_ready_i : in  std_logic;
      lrx_data_o  : out std_logic_vector(7 downto 0);
      ltx_valid_i : in  std_logic;
      ltx_ready_o : out std_logic;
      ltx_data_i  : in  std_logic_vector(7 downto 0)
   );
end entity dbg_host;

architecture synthesis of dbg_host is

   subtype t_byte is std_logic_vector(7 downto 0);

   constant C_ESC   : t_byte := X"FF";
   constant C_HASH  : t_byte := X"23";
   constant C_TAG_R : t_byte := X"52";
   constant C_TAG_W : t_byte := X"57";

   -- The tags of the link's answers and notices
   constant C_TAG_B  : t_byte := X"62";
   constant C_TAG_E  : t_byte := X"65";
   constant C_TAG_H  : t_byte := X"68";
   constant C_TAG_K  : t_byte := X"6B";
   constant C_TAG_O  : t_byte := X"6F";
   constant C_TAG_P  : t_byte := X"70";
   constant C_TAG_RA : t_byte := X"72";
   constant C_TAG_X  : t_byte := X"78";

   -- The error code of a request that got no answer in time; the link's
   -- own codes are 01 to 03
   constant C_ERR_TIMEOUT : t_byte := X"FF";

   -- The payload digits of an R and of a W: A and N, and the word
   constant C_DIGS_R : natural := 12;
   constant C_DIGS_W : natural := 20;

   type t_tx_st is (TX_IDLE_ST, TX_ESC_ST, TX_TAG_ST, TX_DIG_ST, TX_HASH_ST, TX_CC1_ST, TX_CC2_ST);

   type t_rx_st is (RX_IDLE_ST, RX_ESC_ST, RX_PAY_ST, RX_CC1_ST, RX_CC2_ST);

   function hex_char(n : std_logic_vector(3 downto 0)) return t_byte is
   begin
      if n < 10 then
         return X"3" & n;
      else
         return ("0000" & n) + X"37";
      end if;
   end function hex_char;

   function is_hex(b : t_byte) return boolean is
   begin
      return (b >= X"30" and b <= X"39") or (b >= X"41" and b <= X"46") or
             (b >= X"61" and b <= X"66");
   end function is_hex;

   -- The value of a hex digit, either case
   function hex_val(b : t_byte) return std_logic_vector is
   begin
      if b <= X"39" then
         return b(3 downto 0);
      else
         return b(3 downto 0) + 9;
      end if;
   end function hex_val;

   function is_letter(b : t_byte) return boolean is
   begin
      return (b >= X"41" and b <= X"5A") or (b >= X"61" and b <= X"7A");
   end function is_letter;

   -- The digits before the words of an `r`, which are the whole payload of
   -- every other tag, and 0 for a tag that is not the link's
   function hdr_len(tag : t_byte) return natural is
   begin
      case tag is
         when C_TAG_RA | C_TAG_K         => return 12;
         when C_TAG_E                    => return 4;
         when C_TAG_B | C_TAG_H | C_TAG_X => return 2;
         when others                     => return 0;
      end case;
   end function hdr_len;

   function is_known(tag : t_byte) return boolean is
   begin
      return tag = C_TAG_RA or tag = C_TAG_K or tag = C_TAG_E or tag = C_TAG_B or
             tag = C_TAG_H or tag = C_TAG_X or tag = C_TAG_P or tag = C_TAG_O;
   end function is_known;

   -- The open request
   signal busy_r : std_logic := '0';
   signal sent   : std_logic;             -- Open, its packet sent, and not ending
   signal we_r   : std_logic;
   signal addr_r : std_logic_vector(31 downto 0);
   signal n_r    : std_logic_vector(15 downto 0);

   -- The packet out: A, N, and the word, sent from bit 79, which the digits
   -- shift out
   signal tx_st   : t_tx_st := TX_IDLE_ST;
   signal tx_fld  : std_logic_vector(79 downto 0);
   signal tx_idx  : natural range 0 to C_DIGS_W - 1;
   signal tx_sum  : t_byte;
   signal tx_data : t_byte;
   signal tx_take : std_logic;

   -- The packet in
   signal rx_st    : t_rx_st := RX_IDLE_ST;
   signal rx_tag   : t_byte;
   signal rx_sum   : t_byte;
   signal rx_hi    : std_logic_vector(3 downto 0);
   signal rx_sh    : std_logic_vector(31 downto 0);
   signal rx_dig   : natural range 0 to 12;               -- Digits of the header
   signal rx_nib   : natural range 0 to 7;                -- Digits of the word of an `r`
   signal rx_words : std_logic_vector(16 downto 0);       -- Words of an `r`
   signal rx_n     : std_logic_vector(15 downto 0);       -- Its N
   signal rx_arg   : t_byte;                              -- The first 2 digits
   signal rx_code  : t_byte;                              -- The next 2, an `e`'s code
   signal rx_bad   : std_logic;                           -- A bad digit or length
   signal rx_match : std_logic;                           -- A and N are the request's
   signal rx_nib_v : std_logic_vector(3 downto 0);
   signal rx_sh_v  : std_logic_vector(31 downto 0);
   signal rx_byte  : std_logic;                           -- A byte of a packet

   signal timer : natural range 0 to G_TIMEOUT := 0;

   signal rd_valid  : std_logic := '0';
   signal rd_data   : std_logic_vector(31 downto 0);
   signal done      : std_logic := '0';
   signal err       : std_logic := '0';
   signal err_code  : t_byte;
   signal ntc_valid : std_logic := '0';
   signal ntc_tag   : t_byte;
   signal ntc_arg   : t_byte;
   signal con_valid : std_logic := '0';
   signal con_data  : t_byte;

begin

   req_ready_o <= not busy_r;
   sent        <= '1' when busy_r = '1' and tx_st = TX_IDLE_ST and done = '0' else '0';
   ltx_ready_o <= '1';

   rd_valid_o  <= rd_valid;
   rd_data_o   <= rd_data;
   done_o      <= done;
   err_o       <= err;
   err_code_o  <= err_code;
   ntc_valid_o <= ntc_valid;
   ntc_tag_o   <= ntc_tag;
   ntc_arg_o   <= ntc_arg;
   con_valid_o <= con_valid;
   con_data_o  <= con_data;

   ---------------------------------------------------------------------------
   -- The request out
   ---------------------------------------------------------------------------

   p_tx_data : process (all)
   begin
      case tx_st is
         when TX_ESC_ST  => tx_data <= C_ESC;
         when TX_TAG_ST  => tx_data <= C_TAG_W when we_r = '1' else C_TAG_R;
         when TX_DIG_ST  => tx_data <= hex_char(tx_fld(79 downto 76));
         when TX_HASH_ST => tx_data <= C_HASH;
         when TX_CC1_ST  => tx_data <= hex_char(tx_sum(7 downto 4));
         when TX_CC2_ST  => tx_data <= hex_char(tx_sum(3 downto 0));
         when others     => tx_data <= X"00";
      end case;
   end process p_tx_data;

   lrx_valid_o <= '0' when tx_st = TX_IDLE_ST else '1';
   lrx_data_o  <= tx_data;
   tx_take     <= '1' when tx_st /= TX_IDLE_ST and lrx_ready_i = '1' else '0';

   p_tx : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if tx_take = '1' then
            case tx_st is

               when TX_ESC_ST =>
                  tx_st <= TX_TAG_ST;

               when TX_TAG_ST =>
                  tx_sum <= tx_data;
                  tx_idx <= 0;
                  tx_st  <= TX_DIG_ST;

               when TX_DIG_ST =>
                  tx_sum <= tx_sum + tx_data;
                  tx_fld <= tx_fld(75 downto 0) & X"0";
                  if (we_r = '1' and tx_idx = C_DIGS_W - 1) or
                     (we_r = '0' and tx_idx = C_DIGS_R - 1) then
                     tx_st <= TX_HASH_ST;
                  else
                     tx_idx <= tx_idx + 1;
                  end if;

               when TX_HASH_ST => tx_st <= TX_CC1_ST;
               when TX_CC1_ST  => tx_st <= TX_CC2_ST;
               when TX_CC2_ST  => tx_st <= TX_IDLE_ST;
               when others     => null;

            end case;
         end if;

         if req_valid_i = '1' and busy_r = '0' then
            we_r   <= req_we_i;
            addr_r <= req_addr_i;
            if req_we_i = '1' then
               n_r    <= X"0001";
               tx_fld <= req_addr_i & X"0001" & req_data_i;
            else
               n_r    <= req_n_i;
               tx_fld <= req_addr_i & req_n_i & X"00000000";
            end if;
            tx_st <= TX_ESC_ST;
         end if;

         if rst_i = '1' then
            tx_st <= TX_IDLE_ST;
         end if;
      end if;
   end process p_tx;

   ---------------------------------------------------------------------------
   -- The bytes in
   ---------------------------------------------------------------------------

   rx_nib_v <= hex_val(ltx_data_i);
   rx_sh_v  <= rx_sh(27 downto 0) & rx_nib_v;
   rx_byte  <= '1' when ltx_valid_i = '1' and (rx_st /= RX_IDLE_ST or ltx_data_i = C_ESC) else '0';

   p_rx : process (clk_i)
      variable len_ok_v : boolean;
   begin
      if rising_edge(clk_i) then
         rd_valid  <= '0';
         done      <= '0';
         ntc_valid <= '0';
         con_valid <= '0';

         if ltx_valid_i = '1' then
            case rx_st is

               when RX_IDLE_ST =>
                  if ltx_data_i = C_ESC then
                     rx_st <= RX_ESC_ST;
                  else
                     con_valid <= '1';
                     con_data  <= ltx_data_i;
                  end if;

               when RX_ESC_ST =>
                  if ltx_data_i = C_ESC then
                     con_valid <= '1';
                     con_data  <= C_ESC;
                     rx_st     <= RX_IDLE_ST;
                  elsif is_letter(ltx_data_i) then
                     rx_tag   <= ltx_data_i;
                     rx_sum   <= ltx_data_i;
                     rx_dig   <= 0;
                     rx_nib   <= 0;
                     rx_words <= (others => '0');
                     rx_n     <= (others => '0');
                     rx_arg   <= (others => '0');
                     rx_bad   <= '0';
                     rx_match <= '1';
                     rx_st    <= RX_PAY_ST;
                  else
                     rx_st <= RX_IDLE_ST;
                  end if;

               when RX_PAY_ST =>
                  rx_sum <= rx_sum + ltx_data_i;
                  if ltx_data_i = C_ESC then
                     rx_st <= RX_ESC_ST;
                  elsif ltx_data_i = C_HASH then
                     rx_sum <= rx_sum;
                     rx_st  <= RX_CC1_ST;
                  elsif not is_hex(ltx_data_i) then
                     rx_bad <= '1';
                  elsif rx_dig < hdr_len(rx_tag) then
                     -- A, N, or a byte field
                     rx_sh  <= rx_sh_v;
                     rx_dig <= rx_dig + 1;
                     if rx_dig = 1 then
                        rx_arg <= rx_sh_v(7 downto 0);
                     end if;
                     if rx_dig = 3 then
                        rx_code <= rx_sh_v(7 downto 0);
                     end if;
                     if rx_dig = 7 and rx_sh_v /= addr_r then
                        rx_match <= '0';
                     end if;
                     if rx_dig = 11 then
                        rx_n <= rx_sh_v(15 downto 0);
                        if rx_sh_v(15 downto 0) /= n_r then
                           rx_match <= '0';
                        end if;
                     end if;
                  elsif rx_tag = C_TAG_RA and rx_words < ("0" & rx_n) then
                     -- A word of an `r`
                     rx_sh <= rx_sh_v;
                     if rx_nib = 7 then
                        rx_nib   <= 0;
                        rx_words <= rx_words + 1;
                        if sent = '1' and we_r = '0' and rx_match = '1' then
                           rd_valid <= '1';
                           rd_data  <= rx_sh_v;
                        end if;
                     else
                        rx_nib <= rx_nib + 1;
                     end if;
                  else
                     rx_bad <= '1';
                  end if;

               when RX_CC1_ST =>
                  rx_hi <= rx_nib_v;
                  rx_st <= RX_CC2_ST;
                  if ltx_data_i = C_ESC then
                     rx_st <= RX_ESC_ST;
                  elsif not is_hex(ltx_data_i) then
                     rx_bad <= '1';
                  end if;

               when RX_CC2_ST =>
                  rx_st    <= RX_IDLE_ST;
                  len_ok_v := rx_dig = hdr_len(rx_tag) and
                              (rx_tag /= C_TAG_RA or (rx_nib = 0 and rx_words = ("0" & rx_n)));
                  if ltx_data_i = C_ESC then
                     rx_st <= RX_ESC_ST;
                  elsif is_hex(ltx_data_i) and rx_bad = '0' and len_ok_v and
                        is_known(rx_tag) and (rx_hi & rx_nib_v) = rx_sum then
                     case rx_tag is

                        when C_TAG_RA | C_TAG_K =>
                           if sent = '1' and rx_match = '1' and
                              (we_r = '1') = (rx_tag = C_TAG_K) then
                              done <= '1';
                              err  <= '0';
                           end if;

                        when C_TAG_E =>
                           if sent = '1' and
                              ((we_r = '1' and rx_arg = C_TAG_W) or (we_r = '0' and rx_arg = C_TAG_R)) then
                              done     <= '1';
                              err      <= '1';
                              err_code <= rx_code;
                           end if;

                        when others =>
                           ntc_valid <= '1';
                           ntc_tag   <= rx_tag;
                           ntc_arg   <= rx_arg;

                     end case;
                  end if;

            end case;
         end if;

         if sent = '1' and timer = 0 then
            done     <= '1';
            err      <= '1';
            err_code <= C_ERR_TIMEOUT;
         end if;

         if rst_i = '1' then
            rx_st     <= RX_IDLE_ST;
            rd_valid  <= '0';
            done      <= '0';
            ntc_valid <= '0';
            con_valid <= '0';
         end if;
      end if;
   end process p_rx;


   -- The open request, and its timer, which starts again at every byte of
   -- a packet, sent or received
   p_busy : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if timer /= 0 then
            timer <= timer - 1;
         end if;
         if tx_st /= TX_IDLE_ST or rx_byte = '1' then
            timer <= G_TIMEOUT;
         end if;

         if done = '1' then
            busy_r <= '0';
         end if;
         if req_valid_i = '1' and busy_r = '0' then
            busy_r <= '1';
            timer  <= G_TIMEOUT;
         end if;

         if rst_i = '1' then
            busy_r <= '0';
            timer  <= G_TIMEOUT;
         end if;
      end if;
   end process p_busy;

   ---------------------------------------------------------------------------
   -- The formal properties
   ---------------------------------------------------------------------------

   gen_formal : if G_FORMAL generate

      type t_f_st is (F_IDLE_ST, F_ESC_ST, F_PAY_ST, F_CC1_ST, F_CC2_ST);

      signal f_st   : t_f_st := F_IDLE_ST;
      signal f_bad  : std_logic := '0';
      signal f_we   : std_logic;
      signal f_exp  : std_logic_vector(79 downto 0);   -- The request's fields
      signal f_cnt  : natural range 0 to C_DIGS_W;     -- Digits taken
      signal f_sum  : t_byte;
      signal f_take : std_logic;
      signal f_len  : natural range 0 to C_DIGS_W;

   begin

      f_take <= lrx_valid_o and lrx_ready_i;
      f_len  <= C_DIGS_W when f_we = '1' else C_DIGS_R;

      -- Parses the bytes that the link takes, against the fields of the
      -- request, which f_exp keeps, its next digit in bits 79..76. f_bad is
      -- a byte out of place or a bad checksum.
      p_f_out : process (clk_i)
      begin
         if rising_edge(clk_i) then
            f_bad <= '0';
            if req_valid_i = '1' and req_ready_o = '1' then
               f_we <= req_we_i;
               if req_we_i = '1' then
                  f_exp <= req_addr_i & X"0001" & req_data_i;
               else
                  f_exp <= req_addr_i & req_n_i & X"00000000";
               end if;
            end if;
            if f_take = '1' then
               case f_st is

                  when F_IDLE_ST =>
                     if lrx_data_o = C_ESC then
                        f_st <= F_ESC_ST;
                     else
                        f_bad <= '1';
                     end if;

                  when F_ESC_ST =>
                     if (f_we = '1' and lrx_data_o = C_TAG_W) or (f_we = '0' and lrx_data_o = C_TAG_R) then
                        f_sum <= lrx_data_o;
                        f_cnt <= 0;
                        f_st  <= F_PAY_ST;
                     else
                        f_bad <= '1';
                     end if;

                  when F_PAY_ST =>
                     if f_cnt = f_len then
                        if lrx_data_o = C_HASH then
                           f_st <= F_CC1_ST;
                        else
                           f_bad <= '1';
                        end if;
                     elsif lrx_data_o = hex_char(f_exp(79 downto 76)) then
                        f_exp <= f_exp(75 downto 0) & X"0";
                        f_sum <= f_sum + lrx_data_o;
                        f_cnt <= f_cnt + 1;
                     else
                        f_bad <= '1';
                     end if;

                  when F_CC1_ST =>
                     f_st <= F_CC2_ST;
                     if lrx_data_o /= hex_char(f_sum(7 downto 4)) then
                        f_bad <= '1';
                     end if;

                  when F_CC2_ST =>
                     f_st <= F_IDLE_ST;
                     if lrx_data_o /= hex_char(f_sum(3 downto 0)) then
                        f_bad <= '1';
                     end if;

               end case;
            end if;

            if rst_i = '1' then
               f_st  <= F_IDLE_ST;
               f_bad <= '0';
            end if;
         end if;
      end process p_f_out;

      -- psl default clock is rising_edge(clk_i);

      -- The packet: whole, in order, with the request's fields and its
      -- checksum, and nothing between packets. A byte offered stays until
      -- it is taken, and a request is taken only while none is open.
      -- psl f_framing : assert always f_bad = '0';
      -- psl f_hold : assert always {lrx_valid_o and not lrx_ready_i and not rst_i} |=>
      --    {lrx_valid_o = '1' and lrx_data_o = prev(lrx_data_o)};
      -- psl f_one : assert always req_ready_o = '1' -> tx_st = TX_IDLE_ST;

      -- The states are legal: k-induction starts from any encoding
      -- psl i_tx_st : assert always tx_st = TX_IDLE_ST or tx_st = TX_ESC_ST or tx_st = TX_TAG_ST or
      --    tx_st = TX_DIG_ST or tx_st = TX_HASH_ST or tx_st = TX_CC1_ST or tx_st = TX_CC2_ST;
      -- psl i_rx_st : assert always rx_st = RX_IDLE_ST or rx_st = RX_ESC_ST or rx_st = RX_PAY_ST or
      --    rx_st = RX_CC1_ST or rx_st = RX_CC2_ST;
      -- psl i_f_st : assert always f_st = F_IDLE_ST or f_st = F_ESC_ST or f_st = F_PAY_ST or
      --    f_st = F_CC1_ST or f_st = F_CC2_ST;

      -- The invariants that tie p_tx to the parser
      -- psl i_idle : assert always tx_st = TX_IDLE_ST or tx_st = TX_ESC_ST -> f_st = F_IDLE_ST;
      -- psl i_tag : assert always tx_st = TX_TAG_ST -> f_st = F_ESC_ST;
      -- psl i_pay : assert always tx_st = TX_DIG_ST -> f_st = F_PAY_ST and f_cnt = tx_idx and
      --    tx_idx < f_len;
      -- psl i_hash : assert always tx_st = TX_HASH_ST -> f_st = F_PAY_ST and f_cnt = f_len;
      -- psl i_cc1 : assert always tx_st = TX_CC1_ST -> f_st = F_CC1_ST;
      -- psl i_cc2 : assert always tx_st = TX_CC2_ST -> f_st = F_CC2_ST;
      -- psl i_sum : assert always tx_st /= TX_IDLE_ST and tx_st /= TX_ESC_ST and tx_st /= TX_TAG_ST ->
      --    tx_sum = f_sum;
      -- psl i_fld : assert always tx_st /= TX_IDLE_ST -> tx_fld = f_exp and we_r = f_we;
      -- psl i_busy : assert always tx_st /= TX_IDLE_ST -> busy_r = '1';
      -- psl i_done : assert always done = '1' -> busy_r = '1' and tx_st = TX_IDLE_ST;
      -- psl f_once : assert always done = '1' -> next done = '0';

      -- psl c_read : cover {tx_st = TX_CC2_ST and tx_take = '1' and we_r = '0' and rst_i = '0'};
      -- psl c_write : cover {tx_st = TX_CC2_ST and tx_take = '1' and we_r = '1' and rst_i = '0'};
      -- psl c_wait : cover {lrx_valid_o and not lrx_ready_i and not rst_i};

   end generate gen_formal;

end architecture synthesis;
