-- The core's input FIFO: the bytes that the UART and the keyboard send to the
-- console of ISA.md §8.3, 2^G_ADDR_BITS of them, in block RAM, and the end
-- of the input.
--
-- THEORY OF OPERATION
-- The FIFO holds the bytes from rd to wr. Each pointer has one bit more than
-- an index, so that a full FIFO differs from an empty one. A byte on
-- wr_data_i with wr_en_i high is written, unless the FIFO is full or the
-- input has ended; then it is lost. end_i ends the input, and ended_o stays
-- high until reset.
--
-- rd_en_i takes the oldest byte, and is ignored when the FIFO is empty. The
-- memory is read in every cycle at rd into rd_data_o, so rd_data_o holds the
-- byte taken in the cycle after rd_en_i. No byte is written to the word at rd
-- while the FIFO holds a byte: it is written when the FIFO is empty, and not
-- when it is full.
--
-- With G_FORMAL, it states the properties that formal/rx_fifo.sby proves.
-- The solver picks any byte written, and follows it: it stays in its word,
-- and when its turn comes it is the byte read. The pointers stay at most
-- 2^G_ADDR_BITS apart, a byte is not written to the word at rd while the
-- FIFO holds one, an accepted byte makes the FIFO not empty, and nothing is
-- written after the end of the input.
--
-- RESET
-- Synchronous. Reset empties the FIFO and clears ended_o. The memory is not
-- changed.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity rx_fifo is
   generic (
      G_ADDR_BITS : natural;
      -- The properties for formal/rx_fifo.sby
      G_FORMAL    : boolean := false
   );
   port (
      clk_i     : in  std_logic;
      rst_i     : in  std_logic;

      -- A byte arrives
      wr_en_i   : in  std_logic;
      wr_data_i : in  std_logic_vector(7 downto 0);
      full_o    : out std_logic;

      -- The input ends
      end_i     : in  std_logic;
      ended_o   : out std_logic;

      -- The oldest byte is taken; rd_data_o has it in the next cycle
      rd_en_i   : in  std_logic;
      empty_o   : out std_logic;
      rd_data_o : out std_logic_vector(7 downto 0)
   );
end entity rx_fifo;

architecture synthesis of rx_fifo is

   constant C_LEN : natural := 2 ** G_ADDR_BITS;

   type t_mem is array (0 to C_LEN - 1) of std_logic_vector(7 downto 0);

   signal mem   : t_mem;
   signal wr    : std_logic_vector(G_ADDR_BITS downto 0) := (others => '0');
   signal rd    : std_logic_vector(G_ADDR_BITS downto 0) := (others => '0');
   signal ended : std_logic                              := '0';
   signal full  : std_logic;
   signal empty : std_logic;
   signal we    : std_logic;
   signal re    : std_logic;

begin

   full    <= '1' when wr - rd = C_LEN else
              '0';
   empty   <= '1' when wr = rd else
              '0';
   we      <= wr_en_i and not full and not ended;
   re      <= rd_en_i and not empty;
   full_o  <= full;
   empty_o <= empty;
   ended_o <= ended;

   p_mem : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if we = '1' then
            mem(to_integer(wr(G_ADDR_BITS - 1 downto 0))) <= wr_data_i;
         end if;
         rd_data_o <= mem(to_integer(rd(G_ADDR_BITS - 1 downto 0)));
      end if;
   end process p_mem;

   p_ptr : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if we = '1' then
            wr <= wr + 1;
         end if;
         if re = '1' then
            rd <= rd + 1;
         end if;
         if end_i = '1' then
            ended <= '1';
         end if;

         if rst_i = '1' then
            wr    <= (others => '0');
            rd    <= (others => '0');
            ended <= '0';
         end if;
      end if;
   end process p_ptr;


   gen_formal : if G_FORMAL generate
      -- The byte that the solver picks, at any write, and where it is
      signal f_pick   : std_logic;
      signal f_follow : std_logic                              := '0';
      signal f_ptr    : std_logic_vector(G_ADDR_BITS downto 0) := (others => '0');
      signal f_data   : std_logic_vector(7 downto 0)           := (others => '0');
      signal f_word   : std_logic_vector(7 downto 0);
      signal f_turn   : std_logic;
      signal f_inside : std_logic;

      attribute anyseq : boolean;
      attribute anyseq of f_pick : signal is true;
   begin

      p_follow : process (clk_i)
      begin
         if rising_edge(clk_i) then
            if f_follow = '0' and we = '1' and f_pick = '1' then
               f_follow <= '1';
               f_ptr    <= wr;
               f_data   <= wr_data_i;
            elsif f_follow = '1' and re = '1' and rd = f_ptr then
               f_follow <= '0';
            end if;

            if rst_i = '1' then
               f_follow <= '0';
            end if;
         end if;
      end process p_follow;

      f_word   <= mem(to_integer(f_ptr(G_ADDR_BITS - 1 downto 0)));
      f_turn   <= '1' when f_follow = '1' and re = '1' and rd = f_ptr else
                  '0';
      f_inside <= '1' when f_ptr - rd < wr - rd else
                  '0';

      -- psl default clock is rising_edge(clk_i);

      -- psl f_size : assert always wr - rd <= C_LEN;
      -- psl f_follow_inside : assert always f_follow -> f_inside;
      -- psl f_follow_word : assert always f_follow -> f_word = f_data;
      -- psl f_order : assert always {f_turn} |=> {rd_data_o = prev(f_data)};
      -- psl f_rd_word : assert always we = '1' ->
      --    (empty = '1' or wr(G_ADDR_BITS - 1 downto 0) /= rd(G_ADDR_BITS - 1 downto 0));
      -- psl f_write_shows : assert always {we and not rst_i} |=> {rst_i or not empty};
      -- psl f_end_holds : assert always {ended and not rst_i} |=> {rst_i or ended};
      -- psl f_end_stops : assert always ended -> not we;
      -- psl f_reset : assert always {rst_i} |=> {empty and not ended};

      -- psl c_full : cover {full and not rst_i};
      -- psl c_order : cover {f_turn and not rst_i};
      -- psl c_wrap : cover {(wr = C_LEN + 1 and rd = C_LEN) and not rst_i};
      -- psl c_ended : cover {ended and empty and not rst_i; rd_en_i};
   end generate gen_formal;

end architecture synthesis;
