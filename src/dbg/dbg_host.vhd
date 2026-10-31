-- The on-board debugger's adapter to the debug link (doc/DEBUGGER.md): it
-- turns a request of one or more words into the word accesses of the
-- link's side port (nice_cpu/hdl/src/debug_link.vhd, contract g), and
-- gives the words read back one at a time.
--
-- THEORY OF OPERATION
-- The debugger reads a run of words, R0-R15, the debug registers, or the
-- window of its page, or writes one word, as a host's R and W packets do
-- (nice_cpu/doc/DEBUG.md §2). The side port takes one word at a time:
-- p_req holds side_valid_o with the word's address until side_done_i,
-- then the next address, and so on, as contract g asks. Each word read
-- goes out on rd_valid_o the cycle after its done, and done_o ends the
-- request the cycle after the last word, or after the write. A word that
-- the link refuses, side_err_i, one that is not a debug register while
-- the program runs (DEBUG.md §3), ends the request at once with err_o and
-- the code 02, the `e02` a host gets, and no word after it is asked for. A
-- request is taken only while none is open, and a request of no words
-- ends at once.
--
-- The link answers every request (contract g), so there is no timeout: a
-- word waits behind the host's accesses, for a clear of the memory, and
-- for the memory's acknowledge, as a host's would.
--
-- FORMAL
-- With G_FORMAL, the properties of the side port and of the request:
-- side_valid_o and its fields stay until side_done_i (contract g), no
-- word is out while no request is open, the address of the word out is
-- the request's plus the words done, a read without an error ends after
-- its count of words, and a request ends once. formal/dbg_host.sby
-- proves them.
--
-- RESET
-- Synchronous to clk_i, by rst_i. No request is open, and no word is out
-- on the side port; the link is reset with it.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity dbg_host is
   generic (
      -- The properties of formal/dbg_host.sby
      G_FORMAL : boolean := false
   );
   port (
      clk_i        : in  std_logic;
      rst_i        : in  std_logic;

      -- A request: with req_we_i '0', a read of req_n_i words from
      -- req_addr_i; with '1', a write of the one word req_data_i there
      req_valid_i  : in  std_logic;
      req_ready_o  : out std_logic;
      req_we_i     : in  std_logic;
      req_addr_i   : in  std_logic_vector(31 downto 0);
      req_n_i      : in  std_logic_vector(15 downto 0);
      req_data_i   : in  std_logic_vector(31 downto 0);

      -- The words read, in order, one a cycle at the most
      rd_valid_o   : out std_logic;
      rd_data_o    : out std_logic_vector(31 downto 0);

      -- The end of the request: err_o '0' when every word was done, and
      -- '1' when the link refused one, with its code, 02
      done_o       : out std_logic;
      err_o        : out std_logic;
      err_code_o   : out std_logic_vector(7 downto 0);

      -- The side port of the link (debug_link.vhd, contract g): a word,
      -- held until side_done_i, which brings the word read or the refusal
      side_valid_o : out std_logic;
      side_we_o    : out std_logic;
      side_addr_o  : out std_logic_vector(31 downto 0);
      side_data_o  : out std_logic_vector(31 downto 0);
      side_done_i  : in  std_logic;
      side_err_i   : in  std_logic;
      side_data_i  : in  std_logic_vector(31 downto 0)
   );
end entity dbg_host;

architecture synthesis of dbg_host is

   -- The link's code for a word that is not a debug register while the
   -- program runs (DEBUG.md §3)
   constant C_ERR_RUNNING : std_logic_vector(7 downto 0) := X"02";

   -- The open request: the word out, with its address and the words
   -- left, the write's data, and its end
   signal busy_r  : std_logic                     := '0';
   signal valid_r : std_logic                     := '0'; -- A word is out
   signal we_r    : std_logic                     := '0';
   signal addr_r  : std_logic_vector(31 downto 0) := (others => '0');
   signal data_r  : std_logic_vector(31 downto 0) := (others => '0');
   signal left_r  : std_logic_vector(15 downto 0) := (others => '0');
   signal end_r   : std_logic                     := '0'; -- Ends next cycle
   signal word_r  : std_logic                     := '0'; -- A word was done
   signal done_r  : std_logic                     := '0';
   signal err_r   : std_logic                     := '0';
   signal rd_data : std_logic_vector(31 downto 0) := (others => '0');

begin

   req_ready_o  <= not busy_r;
   side_valid_o <= valid_r;
   side_we_o    <= we_r;
   side_addr_o  <= addr_r;
   side_data_o  <= data_r;
   rd_valid_o   <= word_r and not we_r;
   rd_data_o    <= rd_data;
   done_o       <= done_r;
   err_o        <= err_r;
   err_code_o   <= C_ERR_RUNNING;

   p_req : process (clk_i)
   begin
      if rising_edge(clk_i) then
         word_r <= '0';
         done_r <= '0';
         end_r  <= '0';

         if req_valid_i = '1' and busy_r = '0' then
            busy_r <= '1';
            we_r   <= req_we_i;
            addr_r <= req_addr_i;
            data_r <= req_data_i;
            if req_we_i = '1' then
               left_r  <= X"0001";
               valid_r <= '1';
            elsif req_n_i = X"0000" then
               left_r <= X"0000";
               end_r  <= '1';
            else
               left_r  <= req_n_i;
               valid_r <= '1';
            end if;
         end if;

         -- A word done: the next one, or the end of the request
         if valid_r = '1' and side_done_i = '1' then
            if side_err_i = '1' then
               valid_r <= '0';
               done_r  <= '1';
               err_r   <= '1';
            else
               word_r  <= '1';
               rd_data <= side_data_i;
               addr_r  <= addr_r + 1;
               left_r  <= left_r - 1;
               if left_r = X"0001" then
                  valid_r <= '0';
                  end_r   <= '1';
               end if;
            end if;
         end if;

         if end_r = '1' then
            done_r <= '1';
            err_r  <= '0';
         end if;
         if done_r = '1' then
            busy_r <= '0';
         end if;

         if rst_i = '1' then
            busy_r  <= '0';
            valid_r <= '0';
            end_r   <= '0';
            word_r  <= '0';
            done_r  <= '0';
            err_r   <= '0';
         end if;
      end if;
   end process p_req;

   ---------------------------------------------------------------------------
   -- The formal properties
   ---------------------------------------------------------------------------

   gen_formal : if G_FORMAL generate

      -- The request as it was taken, the words done since, a bit wider so
      -- that the count never wraps, and whether the link refused one
      signal f_we   : std_logic                     := '0';
      signal f_addr : std_logic_vector(31 downto 0) := (others => '0');
      signal f_n    : std_logic_vector(16 downto 0) := (others => '0');
      signal f_cnt  : std_logic_vector(16 downto 0) := (others => '0');
      signal f_ref  : std_logic                     := '0';

   begin

      p_f_req : process (clk_i)
      begin
         if rising_edge(clk_i) then
            f_ref <= '0';
            if req_valid_i = '1' and req_ready_o = '1' then
               f_we   <= req_we_i;
               f_addr <= req_addr_i;
               f_cnt  <= (others => '0');
               if req_we_i = '1' then
                  f_n <= "0" & X"0001";
               else
                  f_n <= "0" & req_n_i;
               end if;
            end if;
            if valid_r = '1' and side_done_i = '1' then
               if side_err_i = '1' then
                  f_ref <= '1';
               else
                  f_cnt <= f_cnt + 1;
               end if;
            end if;
            if rst_i = '1' then
               f_ref <= '0';
            end if;
         end if;
      end process p_f_req;

      -- psl default clock is rising_edge(clk_i);

      -- Contract g: a word out stays, with its fields, until the link is
      -- done with it
      -- psl f_hold : assert always {valid_r = '1' and side_done_i = '0' and rst_i = '0'} |=>
      --    {valid_r = '1' and we_r = prev(we_r) and addr_r = prev(addr_r) and data_r = prev(data_r)};

      -- A word is out only for an open request, and is the request's: its
      -- write bit, and its address plus the words done before it
      -- psl f_open : assert always valid_r = '1' -> busy_r = '1' and done_r = '0' and end_r = '0';
      -- psl f_word : assert always valid_r = '1' -> we_r = f_we and addr_r = f_addr + f_cnt;
      -- psl f_left : assert always valid_r = '1' -> f_cnt < f_n and ("0" & left_r) = f_n - f_cnt;

      -- A request ends once, after its words, or when the link refused one;
      -- a word read comes out once, the cycle after its done
      -- psl f_ends : assert always done_r = '1' -> busy_r = '1';
      -- psl f_once : assert always {done_r = '1'} |=> {done_r = '0'};
      -- psl f_count : assert always done_r = '1' and err_r = '0' -> f_cnt = f_n;
      -- psl f_err : assert always done_r = '1' and err_r = '1' -> f_ref = '1';
      -- psl f_rd : assert always rd_valid_o = '1' -> busy_r = '1' and f_we = '0';
      -- psl f_end : assert always end_r = '1' -> busy_r = '1' and valid_r = '0' and done_r = '0';
      -- psl f_idle : assert always busy_r = '0' -> valid_r = '0' and end_r = '0' and done_r = '0';

      -- psl c_read : cover {done_r = '1' and err_r = '0' and f_we = '0' and f_n = "0" & X"0003"};
      -- psl c_write : cover {done_r = '1' and err_r = '0' and f_we = '1'};
      -- psl c_err : cover {done_r = '1' and err_r = '1' and f_cnt = "0" & X"0002"};
      -- psl c_none : cover {done_r = '1' and err_r = '0' and f_n = "0" & X"0000"};

   end generate gen_formal;

end architecture synthesis;
