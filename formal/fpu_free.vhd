-- A free FPU, for formal/devices.sby: on its Wishbone port it does
-- anything that nice_cpu/hdl/src/fpu.vhd may do, as nice_cpu's
-- formal/formal_fpu.vhd proves it, so that the proof of src/devices.vhd
-- spends no time on the FPU's commands. src/devices.vhd instantiates it
-- with G_FORMAL, in place of the FPU.
--
-- THEORY OF OPERATION
-- It counts the requests that it accepts and has not acknowledged, and
-- gives the count on f_owed_o, so that the proof of devices.vhd can say
-- how its fpu_wait follows it. The FPU acknowledges each request that it
-- accepts once, in order, after the cycle that accepts it, and owes at
-- most three. So an acknowledge here is free in any cycle in which it
-- owes one, from the cycle after it accepted it, and its word is free.
-- STALL is high only while a request waits behind another, so it is free
-- while it owes one or more, and it never makes the count more than
-- three.
--
-- RESET
-- Synchronous. Reset drops the requests owed, and no acknowledge follows
-- it, as fpu.vhd's f_ack_reset says.

library ieee;
   use ieee.std_logic_1164.all;

entity fpu_free is
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;

      wb_cyc_i   : in  std_logic;
      wb_stb_i   : in  std_logic;
      wb_stall_o : out std_logic;
      wb_ack_o   : out std_logic;
      wb_we_i    : in  std_logic;
      wb_addr_i  : in  std_logic_vector(2 downto 0);
      wb_data_i  : in  std_logic_vector(31 downto 0);
      wb_data_o  : out std_logic_vector(31 downto 0);

      -- The requests accepted and not yet acknowledged
      f_owed_o   : out natural range 0 to 3
   );
end entity fpu_free;

architecture formal of fpu_free is

   signal owed   : natural range 0 to 3 := 0;
   signal accept : std_logic;

   -- The free choices
   signal f_ack   : std_logic;
   signal f_stall : std_logic;
   signal f_data  : std_logic_vector(31 downto 0);

   attribute anyseq : boolean;
   attribute anyseq of f_ack   : signal is true;
   attribute anyseq of f_stall : signal is true;
   attribute anyseq of f_data  : signal is true;

begin

   wb_stall_o <= f_stall when owed >= 1 and owed <= 2 else
                 '1' when owed = 3 else
                 '0';
   wb_ack_o   <= f_ack when owed >= 1 else
                 '0';
   wb_data_o  <= f_data;
   f_owed_o   <= owed;

   accept <= wb_cyc_i and wb_stb_i and not wb_stall_o;

   p_owed : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if accept = '1' and wb_ack_o = '0' then
            owed <= owed + 1;
         elsif accept = '0' and wb_ack_o = '1' then
            owed <= owed - 1;
         end if;

         if rst_i = '1' then
            owed <= 0;
         end if;
      end if;
   end process p_owed;

end architecture formal;
