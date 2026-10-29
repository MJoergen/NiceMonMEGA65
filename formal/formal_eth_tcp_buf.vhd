-- The TCP server's buffers (src/eth/eth_tcp_buf.vhd), with their
-- properties, for SymbiYosys. The inputs are free but for the buffers'
-- contracts: the connection commits no more than the room, writes only
-- into it, and acknowledges only what the link has written, and its
-- pointers are 0 after reset. Each buffer has 4 bytes, and the output
-- pauses after 2 cycles, so that the solver soon wraps the pointers
-- around; the properties do not depend on the sizes.
--
-- With G_MODEL, it also checks the bytes against a model: a byte that the
-- solver picks, written into the receive buffer at any pointer, is the
-- byte the link takes when its pointer's turn comes, counting the bytes
-- taken from 0, as it was last written there; and a byte that the link
-- writes into the send buffer is read back at its word until the link
-- writes the word again, a whole buffer later. k-induction cannot relate
-- the model's bytes to the memories', so "model" proves these with PDR
-- instead.
--
-- RESET
-- The first cycle is a reset.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity formal_eth_tcp_buf is
   generic (
      G_MODEL : boolean := false
   );
   port (
      clk_i       : in  std_logic;
      rst_i       : in  std_logic;
      conn_i      : in  std_logic;
      una_ptr_i   : in  std_logic_vector(2 downto 0);
      ltx_data_i  : in  std_logic_vector(7 downto 0);
      ltx_valid_i : in  std_logic;
      rd_addr_i   : in  std_logic_vector(1 downto 0);
      wr_we_i     : in  std_logic;
      wr_addr_i   : in  std_logic_vector(2 downto 0);
      wr_data_i   : in  std_logic_vector(7 downto 0);
      cmt_i       : in  std_logic_vector(2 downto 0);
      brk_set_i   : in  std_logic;
      lrx_ready_i : in  std_logic
   );
end entity formal_eth_tcp_buf;

architecture synthesis of formal_eth_tcp_buf is

   constant C_SIZE : natural := 4;

   signal ltx_ready : std_logic;
   signal tail_ptr  : std_logic_vector(2 downto 0);
   signal paused    : std_logic;
   signal rd_data   : std_logic_vector(7 downto 0);
   signal free      : natural range 0 to C_SIZE;
   signal lrx_data  : std_logic_vector(7 downto 0);
   signal lrx_valid : std_logic;
   signal lrx_break : std_logic;
   signal on_s      : std_logic;

begin

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;
   -- psl f_reset : assume always {rst_i} |=> {cmt_i = 0 and una_ptr_i = 0};
   -- psl f_cmt : assume always {not rst_i} |=> {to_integer(cmt_i - prev(cmt_i)) <= prev(free)};
   -- psl f_wr : assume always wr_we_i = '1' -> to_integer(wr_addr_i - cmt_i) < free;
   -- psl f_una : assume always tail_ptr - una_ptr_i <= C_SIZE;


   i_eth_tcp_buf : entity work.eth_tcp_buf
      generic map (
         G_ADDR_BITS => 2,
         G_IDLE      => 2,
         G_FORMAL    => true
      )
      port map (
         clk_i       => clk_i,
         rst_i       => rst_i,
         conn_i      => conn_i,
         una_ptr_i   => una_ptr_i,
         ltx_data_i  => ltx_data_i,
         ltx_valid_i => ltx_valid_i,
         ltx_ready_o => ltx_ready,
         tail_ptr_o  => tail_ptr,
         paused_o    => paused,
         rd_addr_i   => rd_addr_i,
         rd_data_o   => rd_data,
         wr_we_i     => wr_we_i,
         wr_addr_i   => wr_addr_i,
         wr_data_i   => wr_data_i,
         cmt_i       => cmt_i,
         free_o      => free,
         brk_set_i   => brk_set_i,
         lrx_data_o  => lrx_data,
         lrx_valid_o => lrx_valid,
         lrx_ready_i => lrx_ready_i,
         lrx_break_o => lrx_break,
         on_o        => on_s
      ); -- i_eth_tcp_buf


   gen_model : if G_MODEL generate
      -- The byte the solver picks in the receive buffer: at any write, its
      -- pointer, and what was last written there; the bytes the link has
      -- taken, and that it takes one now
      signal f_pick   : std_logic;
      signal f_follow : std_logic                    := '0';
      signal f_ptr    : std_logic_vector(2 downto 0) := (others => '0');
      signal f_data   : std_logic_vector(7 downto 0) := (others => '0');
      signal f_cnt    : std_logic_vector(2 downto 0) := (others => '0');
      signal f_take   : std_logic;
      -- The byte the solver picks in the send buffer: at any write by the
      -- link, its pointer and the byte; and that the link writes one now
      signal f_tpick   : std_logic;
      signal f_tfollow : std_logic                    := '0';
      signal f_tptr    : std_logic_vector(2 downto 0) := (others => '0');
      signal f_tdata   : std_logic_vector(7 downto 0) := (others => '0');
      signal f_twe     : std_logic;

      attribute anyseq : boolean;
      attribute anyseq of f_pick  : signal is true;
      attribute anyseq of f_tpick : signal is true;
   begin

      f_take <= lrx_valid and lrx_ready_i;
      f_twe  <= ltx_valid_i and ltx_ready and conn_i;

      p_follow : process (clk_i)
      begin
         if rising_edge(clk_i) then
            if f_take = '1' then
               f_cnt <= f_cnt + 1;
            end if;
            if f_follow = '0' and wr_we_i = '1' and f_pick = '1' then
               f_follow <= '1';
               f_ptr    <= wr_addr_i;
               f_data   <= wr_data_i;
            elsif f_follow = '1' and wr_we_i = '1' and wr_addr_i = f_ptr then
               f_data <= wr_data_i;
            end if;
            if f_follow = '1' and f_take = '1' and f_cnt = f_ptr then
               f_follow <= '0';
            end if;

            if f_tfollow = '0' and f_twe = '1' and f_tpick = '1' then
               f_tfollow <= '1';
               f_tptr    <= tail_ptr;
               f_tdata   <= ltx_data_i;
            elsif f_tfollow = '1' and f_twe = '1' and tail_ptr = f_tptr + C_SIZE then
               f_tfollow <= '0';
            end if;

            if rst_i = '1' then
               f_cnt     <= (others => '0');
               f_follow  <= '0';
               f_tfollow <= '0';
            end if;
         end if;
      end process p_follow;

      -- psl f_order : assert always (f_follow = '1' and f_take = '1' and f_cnt = f_ptr) ->
      --    lrx_data = f_data;
      -- psl f_kept : assert always {f_tfollow = '1' and rd_addr_i = f_tptr(1 downto 0) and
      --    not (f_twe = '1' and tail_ptr = f_tptr + C_SIZE) and rst_i = '0'} |=>
      --    {rst_i = '1' or rd_data = f_tdata};

      -- psl c_order : cover {f_follow = '1' and f_take = '1' and f_cnt = f_ptr and rst_i = '0'};
      -- psl c_kept : cover {f_tfollow = '1' and rd_addr_i = f_tptr(1 downto 0) and rst_i = '0'};
   end generate gen_model;

end architecture synthesis;
