-- nice_cpu's FPU (nice_cpu/hdl/src/fpu.vhd) against the rules of its
-- port that formal/fpu_free.vhd, its stand-in in the proofs of
-- src/devices.vhd, gives it, for SymbiYosys (issue #146). Every input is
-- free but for what a master promises, so the solver tries every master
-- that holds a stalled request.
--
-- THEORY OF OPERATION
-- The FPU runs with G_FORMAL, which puts a free stand-in in place of its
-- arithmetic unit and its ROMs, so that the check spends no time on the
-- commands. Beside it is fpu_free's count of the requests accepted and
-- not yet acknowledged, and the stand-in's four rules are assertions on
-- it:
-- * f_ack_owed: an acknowledge answers a request owed, so each request
--   gets one, in order, and not in the cycle that accepts it.
-- * f_owed_3: at most three are owed: STALL is high when three are.
-- * f_stall_owed: STALL is high only while one or more are owed.
-- * f_ack_reset: reset drops the requests owed, and no acknowledge
--   follows it.
-- The check is bounded, from the reset to the depth of fpu_port.sby. A
-- proof by induction would need the FPU's own count, f_owed, which is
-- inside fpu.vhd, as a state where the two counts differ breaks the
-- rules only after any number of cycles of a command. So a bump of
-- nice_cpu whose FPU breaks a rule of the stand-in fails here, whatever
-- nice_cpu's own assertions then say. The covers show that the check
-- reaches three requests owed and an acknowledge after STALL.
--
-- RESET
-- The first cycle is a reset.

library ieee;
   use ieee.std_logic_1164.all;

entity formal_fpu_port is
   port (
      clk_i     : in  std_logic;
      rst_i     : in  std_logic;
      wb_cyc_i  : in  std_logic;
      wb_stb_i  : in  std_logic;
      wb_we_i   : in  std_logic;
      wb_addr_i : in  std_logic_vector(2 downto 0);
      wb_data_i : in  std_logic_vector(31 downto 0)
   );
end entity formal_fpu_port;

architecture synthesis of formal_fpu_port is

   signal wb_stall : std_logic;
   signal wb_ack   : std_logic;
   signal wb_data  : std_logic_vector(31 downto 0);

   -- fpu_free's count of the requests owed, which may go past 3 here, so
   -- that f_owed_3 can fail
   signal owed   : natural range 0 to 7 := 0;
   signal accept : std_logic;

begin

   accept <= wb_cyc_i and wb_stb_i and not wb_stall;

   p_owed : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if accept = '1' and wb_ack = '0' then
            owed <= owed + 1;
         elsif accept = '0' and wb_ack = '1' and owed > 0 then
            owed <= owed - 1;
         end if;

         if rst_i = '1' then
            owed <= 0;
         end if;
      end if;
   end process p_owed;

   -- psl default clock is rising_edge(clk_i);
   -- psl f_initial_reset : assume rst_i;
   -- psl f_hold : assume always
   --    {wb_cyc_i and wb_stb_i and wb_stall and not rst_i} |=>
   --    {wb_cyc_i = '1' and wb_stb_i = '1' and stable(wb_we_i) and stable(wb_addr_i) and
   --     stable(wb_data_i)};

   -- psl f_ack_owed : assert always rst_i = '0' and wb_ack = '1' -> owed >= 1;
   -- psl f_owed_3 : assert always owed <= 3 and (owed = 3 -> wb_stall = '1');
   -- psl f_stall_owed : assert always rst_i = '0' and wb_stall = '1' -> owed >= 1;
   -- psl f_ack_reset : assert always {rst_i} |=> {wb_ack = '0'};

   -- psl c_owed_3 : cover {owed = 3 and rst_i = '0'};
   -- psl c_ack_stall : cover {wb_stall and not rst_i; wb_ack and not rst_i};

   i_fpu : entity work.fpu
      generic map (
         G_FORMAL => true
      )
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         wb_cyc_i   => wb_cyc_i,
         wb_stb_i   => wb_stb_i,
         wb_stall_o => wb_stall,
         wb_ack_o   => wb_ack,
         wb_we_i    => wb_we_i,
         wb_addr_i  => wb_addr_i,
         wb_data_i  => wb_data_i,
         wb_data_o  => wb_data
      ); -- i_fpu

end architecture synthesis;
