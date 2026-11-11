-- The I2C master at 0xFFFFFF97-9D (issue #105), a device of board_io.vhd:
-- a whole transaction with a chip on the board's I2C bus, started by one
-- write of its command, with up to 16 bytes of data. The ROM reads the
-- MEGA65's real-time clock through it, and the Nexys4DDR has its
-- temperature sensor on it.
--
-- THEORY OF OPERATION
-- The words, by board_io's offset of their address:
--   7  The command, read and write: bits 6..0 the chip's address, bit 7
--      read (1) or write (0), bits 15..8 the register, bits 20..16 the
--      count of bytes, 0 to 16 (more are taken as 16), and bit 21 "no
--      register". A write starts the transaction, unless one runs, and
--      then it is dropped. It reads the last command taken.
--   8  The status, read only: bit 0 present, always 1 here, bit 1 busy,
--      bit 2 NACK, and bit 3 timeout. The other bits read 0.
--   9  The data, bytes 0 to 3, byte 0 in bits 7..0, read and write;
--      A, B, and C bytes 4 to 15 likewise. A write while busy is dropped.
--   D  Reads 0.
-- A write sends START, the address with W, the register, the count's
-- bytes of the data, and STOP. A read sends START, the address with W,
-- the register, a repeated START, the address with R, then takes the
-- count's bytes into the data, with an ACK after each but the last, which
-- has a NACK, and STOP. A read of 0 bytes is a write of 0 bytes. With "no
-- register" the register's byte and the repeated START are left out: a
-- write sends its bytes after the address, and a read takes them after the
-- address with R. A chip's NACK of the address or of a byte written ends
-- the transaction with STOP, and sets NACK. A new command clears NACK and
-- timeout.
--
-- The bus runs at G_BUS_HZ, 100 kHz, by quarters of its clock period. A
-- symbol, a bit, START, or STOP, is a sequence of slots of a quarter each,
-- and each slot sets the two lines, SCL and SDA, from its start:
--   bit b  (0,b) (1,b) (1,b) (0,b): SDA is taken at the end of the second
--   START  (0,1) (1,1) (1,1) (1,0) (1,0) (0,0)
--   STOP   (0,0) (1,0) (1,0) (1,1) (1,1)
-- with 1 a line released, high by the board's pull-up, and 0 a line pulled
-- low. So SDA changes only while SCL is low, but in START and STOP, and
-- the times of the standard mode hold: SCL is low and high for two
-- quarters, 5 us, and START and STOP hold SDA for two quarters around its
-- change. A START on an idle bus, after a STOP, begins at its second slot,
-- with no pulse of SCL. The second slot of each symbol releases SCL, and
-- its quarter starts only when SCL is high, so that a chip may stretch
-- the clock. When SCL stays low for G_TIMEOUT_US, the transaction ends
-- with both lines released, and timeout set.
--
-- At reset, the bus is recovered from a chip that a reset left in the
-- middle of a transaction, holding SDA low: up to 9 pulses of SCL with SDA
-- released, until SDA is high, and STOP. It is busy meanwhile.
--
-- The lines' outputs scl_o and sda_o are registers of their own, copies of
-- the state machine's lines a cycle later, which drive nothing else, so
-- that they fit in the I/O tile, and their inputs pass through two
-- registers, the first of each in the I/O tile (IOB TRUE in the board's
-- XDC). The board's pin is pulled low while its output is 0,
-- and released while it is 1.
--
-- With G_FORMAL, it states the properties that formal/i2c.sby proves.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) stb_i is high for one cycle per request, which is served in that
--    cycle: a write sets its word, and rdata_o is the word at addr_i,
--    combinationally, as board_io.vhd has it.
-- b) G_CLOCK_HZ is at least 16 times G_BUS_HZ, so that a quarter has a few
--    cycles more than the input's two registers take.
--
-- RESET
-- Synchronous. Reset releases both lines, clears the command, the data,
-- and the status, and starts the recovery of the bus.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity i2c is
   generic (
      G_CLOCK_HZ   : positive;
      -- The clock of the bus, and the longest that a chip may hold SCL low
      G_BUS_HZ     : positive := 100_000;
      G_TIMEOUT_US : positive := 10_000;
      -- The properties for formal/i2c.sby
      G_FORMAL     : boolean  := false
   );
   port (
      clk_i   : in  std_logic;
      rst_i   : in  std_logic;
      -- A request to board_io's words 7 to D, the offset in addr_i
      stb_i   : in  std_logic;
      we_i    : in  std_logic;
      addr_i  : in  std_logic_vector(3 downto 0);
      wdata_i : in  std_logic_vector(31 downto 0);
      rdata_o : out std_logic_vector(31 downto 0);
      -- The bus's lines: 0 pulls the pin low, 1 releases it
      scl_o   : out std_logic;
      sda_o   : out std_logic;
      scl_i   : in  std_logic;
      sda_i   : in  std_logic
   );
end entity i2c;

architecture synthesis of i2c is

   pure function maximum (a : natural;
                          b : natural) return natural is
   begin
      if a > b then
         return a;
      end if;
      return b;
   end function maximum;

   -- The cycles of a quarter of the bus's clock, and of the timeout
   constant C_QUARTER : positive := maximum(1, G_CLOCK_HZ / (4 * G_BUS_HZ));
   constant C_TIMEOUT : positive := maximum(2, G_CLOCK_HZ / 1000 * G_TIMEOUT_US / 1000);

   type t_kind is (BIT_K, START_K, STOP_K);

   -- The lines of a symbol's slot, SCL in bit 1 and SDA in bit 0, with b
   -- the bit of a bit
   pure function lines (kind : t_kind;
                        slot : natural;
                        b    : std_logic) return std_logic_vector is
   begin

      case kind is

         when BIT_K =>
            if slot = 1 or slot = 2 then
               return '1' & b;
            end if;
            return '0' & b;

         when START_K =>

            case slot is
               when 0      => return "01";
               when 1 | 2  => return "11";
               when 3 | 4  => return "10";
               when others => return "00";
            end case;

         when STOP_K =>

            case slot is
               when 0      => return "00";
               when 1 | 2  => return "10";
               when others => return "11";
            end case;

      end case;

   end function lines;

   -- The last slot of a symbol
   pure function last (kind : t_kind) return natural is
   begin

      case kind is
         when BIT_K   => return 3;
         when START_K => return 5;
         when STOP_K  => return 4;
      end case;

   end function last;

   -- The transaction: the recovery after reset, a START or STOP that
   -- runs, or a byte; and of the transaction, which byte the byte is
   type t_state is (IDLE_ST, RECOVER_ST, START_ST, BYTE_ST, STOP_ST);
   type t_phase is (ADDR_PH, REG_PH, WDATA_PH, RADDR_PH, RDATA_PH);

   signal state : t_state := RECOVER_ST;
   signal phase : t_phase := ADDR_PH;

   -- The command, the data, and the status
   signal cmd  : std_logic_vector(21 downto 0)  := (others => '0');
   signal data : std_logic_vector(127 downto 0) := (others => '0');
   signal nack : std_logic                      := '0';
   signal tmo  : std_logic                      := '0';
   signal busy : std_logic;

   -- The symbol that runs: its kind, its bit, its slot, and the cycles
   -- left of the slot's quarter, or waited for SCL to be high
   signal sym_on : std_logic                        := '0';
   signal kind   : t_kind                           := STOP_K;
   signal bitv   : std_logic                        := '1';
   signal slot   : natural range 0 to 5             := 4;
   signal qcnt   : natural range 0 to C_QUARTER - 1 := 0;
   signal tcnt   : natural range 0 to C_TIMEOUT - 1 := 0;
   -- SDA as the last bit took it
   signal sample : std_logic                        := '0';
   -- '1' after a STOP, when a START needs no pulse of SCL
   signal idle : std_logic                        := '0';

   -- The byte that is sent or taken, its bit, 8 for the ACK, whether it
   -- is taken, and its index in the data; and the pulses of the recovery
   signal shreg : std_logic_vector(7 downto 0) := (others => '0');
   signal bitn  : natural range 0 to 8         := 0;
   signal rd    : std_logic                    := '0';
   signal idx   : natural range 0 to 16        := 0;
   signal pulse : natural range 0 to 9         := 0;

   -- The lines' registers, and their inputs' two registers
   signal scl : std_logic                    := '1';
   signal sda : std_logic                    := '1';
   -- The copies of scl and sda in the I/O tiles
   signal scl_q  : std_logic                    := '1';
   signal sda_q  : std_logic                    := '1';
   signal scl_in : std_logic_vector(1 downto 0) := "11";
   signal sda_in : std_logic_vector(1 downto 0) := "11";
   attribute async_reg : string;
   attribute async_reg of scl_in : signal is "TRUE";
   attribute async_reg of sda_in : signal is "TRUE";

   -- The fields of the command
   alias a_chip  : std_logic_vector(6 downto 0) is cmd(6 downto 0);
   alias a_read  : std_logic is cmd(7);
   alias a_reg   : std_logic_vector(7 downto 0) is cmd(15 downto 8);
   alias a_count : std_logic_vector(4 downto 0) is cmd(20 downto 16);
   alias a_noreg : std_logic is cmd(21);

   -- The bytes of the command, at most 16
   pure function count (c : std_logic_vector(4 downto 0)) return natural is
   begin
      if c(4) = '1' then
         return 16;
      end if;
      return to_integer(c);
   end function count;

   -- Byte i of the data
   pure function byte (d : std_logic_vector(127 downto 0);
                       i : natural) return std_logic_vector is
   begin
      return d(8 * i + 7 downto 8 * i);
   end function byte;

begin

   assert G_CLOCK_HZ >= 16 * G_BUS_HZ or G_FORMAL
      report "i2c: the clock must be at least 16 times the bus's"
      severity failure;

   busy <= '0' when state = IDLE_ST else
           '1';


   p_fsm : process (clk_i)

      -- Starts a symbol at its first slot, or at its second
      procedure issue (k     : t_kind;
                       b     : std_logic;
                       first : natural) is
         variable l_v : std_logic_vector(1 downto 0);
      begin
         l_v    := lines(k, first, b);
         kind   <= k;
         bitv   <= b;
         slot   <= first;
         scl    <= l_v(1);
         sda    <= l_v(0);
         qcnt   <= C_QUARTER - 1;
         tcnt   <= 0;
         sym_on <= '1';
         idle   <= '0';
      end procedure issue;

      -- Starts a byte: sent from d, or taken with rd_b
      procedure byte_start (d    : std_logic_vector(7 downto 0);
                            rd_b : std_logic) is
      begin
         shreg <= d;
         bitn  <= 0;
         rd    <= rd_b;
         state <= BYTE_ST;
         issue(BIT_K, d(7) or rd_b, 0);
      end procedure byte_start;

      -- Ends the transaction with STOP
      procedure stop is
      begin
         state <= STOP_ST;
         issue(STOP_K, '0', 0);
      end procedure stop;

      -- The data of a write from byte i, or STOP after the last
      procedure write_from (i : natural) is
      begin
         phase <= WDATA_PH;
         idx   <= i;
         if i < count(a_count) then
            byte_start(byte(data, i), '0');
         else
            stop;
         end if;
      end procedure write_from;

      variable l_v : std_logic_vector(1 downto 0);

   begin
      if rising_edge(clk_i) then
         if sym_on = '1' then
            -- A symbol runs. Its second slot waits for SCL to be high.
            if slot = 1 and scl_in(1) = '0' then
               if tcnt = C_TIMEOUT - 1 then
                  scl    <= '1';
                  sda    <= '1';
                  sym_on <= '0';
                  tmo    <= '1';
                  state  <= IDLE_ST;
               else
                  tcnt <= tcnt + 1;
               end if;
            elsif qcnt /= 0 then
               qcnt <= qcnt - 1;
            else
               if slot = 1 then
                  sample <= sda_in(1);
               end if;
               if slot = last(kind) then
                  sym_on <= '0';
               else
                  l_v  := lines(kind, slot + 1, bitv);
                  slot <= slot + 1;
                  scl  <= l_v(1);
                  sda  <= l_v(0);
                  qcnt <= C_QUARTER - 1;
               end if;
            end if;
         else
            -- The symbol before has ended: the next one.
            case state is

               when IDLE_ST =>
                  null;

               when RECOVER_ST =>
                  if (pulse /= 0 and sample = '1') or pulse = 9 then
                     stop;
                  else
                     pulse <= pulse + 1;
                     issue(BIT_K, '1', 0);
                  end if;

               when START_ST =>
                  if phase = RADDR_PH then
                     byte_start(a_chip & '1', '0');
                  elsif a_noreg = '1' and a_read = '1' and count(a_count) /= 0 then
                     byte_start(a_chip & '1', '0');
                  else
                     byte_start(a_chip & '0', '0');
                  end if;

               when BYTE_ST =>
                  if bitn < 8 then
                     -- The next bit: the byte's, 1 to take a bit or an
                     -- ACK, and for the ACK of a byte taken, NACK after
                     -- the last.
                     shreg <= shreg(6 downto 0) & (sample and rd);
                     bitn  <= bitn + 1;
                     if bitn = 7 then
                        if rd = '1' and idx + 1 < count(a_count) then
                           issue(BIT_K, '0', 0);
                        else
                           issue(BIT_K, '1', 0);
                        end if;
                     else
                        issue(BIT_K, shreg(6) or rd, 0);
                     end if;
                  elsif rd = '0' and sample = '1' then
                     -- The chip's NACK
                     nack <= '1';
                     stop;
                  else

                     case phase is

                        when ADDR_PH =>
                           if a_noreg = '0' then
                              phase <= REG_PH;
                              byte_start(a_reg, '0');
                           elsif a_read = '1' and count(a_count) /= 0 then
                              phase <= RDATA_PH;
                              idx   <= 0;
                              byte_start(X"FF", '1');
                           else
                              write_from(0);
                           end if;

                        when REG_PH =>
                           if a_read = '1' and count(a_count) /= 0 then
                              phase <= RADDR_PH;
                              state <= START_ST;
                              issue(START_K, '0', 0);
                           else
                              write_from(0);
                           end if;

                        when WDATA_PH =>
                           write_from(idx + 1);

                        when RADDR_PH =>
                           phase <= RDATA_PH;
                           idx   <= 0;
                           byte_start(X"FF", '1');

                        when RDATA_PH =>
                           data(8 * idx + 7 downto 8 * idx) <= shreg;
                           if idx + 1 < count(a_count) then
                              idx <= idx + 1;
                              byte_start(X"FF", '1');
                           else
                              stop;
                           end if;

                     end case;

                  end if;

               when STOP_ST =>
                  state <= IDLE_ST;
                  idle  <= '1';

            end case;

         end if;

         -- A request: a command or the data, while no transaction runs
         if stb_i = '1' and we_i = '1' and busy = '0' then

            case addr_i is

               when X"7" =>
                  cmd   <= wdata_i(21 downto 0);
                  idx   <= 0;
                  nack  <= '0';
                  tmo   <= '0';
                  phase <= ADDR_PH;
                  state <= START_ST;
                  if idle = '1' then
                     issue(START_K, '0', 1);
                  else
                     issue(START_K, '0', 0);
                  end if;

               when X"9"   => data(31 downto 0)   <= wdata_i;
               when X"A"   => data(63 downto 32)  <= wdata_i;
               when X"B"   => data(95 downto 64)  <= wdata_i;
               when X"C"   => data(127 downto 96) <= wdata_i;
               when others => null;

            end case;

         end if;

         if rst_i = '1' then
            state  <= RECOVER_ST;
            phase  <= ADDR_PH;
            cmd    <= (others => '0');
            data   <= (others => '0');
            nack   <= '0';
            tmo    <= '0';
            sym_on <= '0';
            kind   <= STOP_K;
            slot   <= 4;
            sample <= '0';
            idle   <= '0';
            pulse  <= 0;
            scl    <= '1';
            sda    <= '1';
         end if;
      end if;
   end process p_fsm;


   p_sync : process (clk_i)
   begin
      if rising_edge(clk_i) then
         scl_in <= scl_in(0) & scl_i;
         sda_in <= sda_in(0) & sda_i;
      end if;
   end process p_sync;


   p_read : process (all)
   begin
      rdata_o <= (others => '0');

      case addr_i is
         when X"7"   => rdata_o(21 downto 0) <= cmd;
         when X"8"   => rdata_o(3 downto 0)  <= tmo & nack & busy & '1';
         when X"9"   => rdata_o              <= data(31 downto 0);
         when X"A"   => rdata_o              <= data(63 downto 32);
         when X"B"   => rdata_o              <= data(95 downto 64);
         when X"C"   => rdata_o              <= data(127 downto 96);
         when others => null;
      end case;
   end process p_read;

   -- The registers in the I/O tiles drive only the pins. Reset releases
   -- the lines, as the state machine's reset does.
   p_pins : process (clk_i)
   begin
      if rising_edge(clk_i) then
         scl_q <= scl;
         sda_q <= sda;
         if rst_i = '1' then
            scl_q <= '1';
            sda_q <= '1';
         end if;
      end if;
   end process p_pins;

   scl_o <= scl_q;
   sda_o <= sda_q;


   gen_formal : if G_FORMAL generate
      -- The lines in the cycle before
      signal f_scl : std_logic := '1';
      signal f_sda : std_logic := '1';
      signal f_rst : std_logic := '1';
      -- A write of a command, taken or dropped
      signal f_cmd : std_logic;
      -- The lines of the symbol's slot, and of its last slot
      signal f_now : std_logic_vector(1 downto 0);
      signal f_end : std_logic_vector(1 downto 0);
   begin

      p_prev : process (clk_i)
      begin
         if rising_edge(clk_i) then
            f_scl <= scl;
            f_sda <= sda;
            f_rst <= rst_i;
         end if;
      end process p_prev;

      f_cmd <= stb_i and we_i when addr_i = X"7" else
               '0';
      f_now <= lines(kind, slot, bitv);
      f_end <= lines(kind, last(kind), bitv);

      -- psl default clock is rising_edge(clk_i);

      -- SDA changes while SCL is released only as START or STOP has it,
      -- or when a timeout or reset releases both lines.
      -- psl f_sda_start : assert always
      --    (scl = '1' and f_scl = '1' and sda = '0' and f_sda = '1') ->
      --    (kind = START_K and slot = 3);
      -- psl f_sda_stop : assert always
      --    (scl = '1' and f_scl = '1' and sda = '1' and f_sda = '0') ->
      --    ((kind = STOP_K and slot = 3) or tmo = '1' or f_rst = '1');

      -- No transaction leaves a line pulled low.
      -- psl f_idle_lines : assert always state = IDLE_ST -> (scl = '1' and sda = '1');
      -- psl f_idle_sym : assert always state = IDLE_ST -> sym_on = '0';

      -- The lines are those of the symbol's slot while it runs, and of its
      -- last slot after it.
      -- psl f_lines_on : assert always sym_on = '1' -> (scl & sda) = f_now;
      -- psl f_lines_end : assert always (sym_on = '0' and state /= IDLE_ST) -> (scl & sda) = f_end;
      -- psl f_slot : assert always slot <= last(kind);

      -- The registers hold values of their types, which their encodings
      -- may exceed.
      -- psl f_valid : assert always
      --    (state = IDLE_ST or state = RECOVER_ST or state = START_ST or state = BYTE_ST or
      --     state = STOP_ST) and
      --    (phase = ADDR_PH or phase = REG_PH or phase = WDATA_PH or phase = RADDR_PH or
      --     phase = RDATA_PH) and
      --    (kind = BIT_K or kind = START_K or kind = STOP_K) and
      --    slot <= 5 and pulse <= 9 and bitn <= 8 and idx <= 16 and
      --    qcnt <= C_QUARTER - 1 and tcnt <= C_TIMEOUT - 1;

      -- Each state runs its kind of symbol; the recovery starts after the
      -- STOP of reset.
      -- psl f_kind_start : assert always state = START_ST -> kind = START_K;
      -- psl f_kind_byte : assert always state = BYTE_ST -> kind = BIT_K;
      -- psl f_kind_stop : assert always state = STOP_ST -> kind = STOP_K;
      -- psl f_kind_recover : assert always
      --    state = RECOVER_ST -> (kind = BIT_K or (kind = STOP_K and pulse = 0 and sym_on = '0'));

      -- A command is taken while no transaction runs, and dropped while
      -- one does; so are the data.
      -- psl f_cmd_take : assert always
      --    {f_cmd and not busy and not rst_i} |=> {busy = '1' and cmd = prev(wdata_i(21 downto 0)) and
      --                                           nack = '0' and tmo = '0'};
      -- psl f_cmd_drop : assert always {f_cmd and busy and not rst_i} |=> {stable(cmd)};
      -- psl f_data_keep : assert always {stb_i = '0' and state = IDLE_ST and rst_i = '0'} |=> {stable(data)};
      -- psl f_cmd_keep : assert always {not f_cmd and not rst_i} |=> {stable(cmd)};

      -- The status: present, and 0 above bit 3; the free word reads 0.
      -- psl f_rd_status : assert always
      --    addr_i = X"8" -> (rdata_o(31 downto 4) = 0 and rdata_o(0) = '1' and rdata_o(1) = busy);
      -- psl f_rd_none : assert always (addr_i < X"7" or addr_i > X"C") -> rdata_o = 0;

      -- START begins the transaction, or the read after its register.
      -- psl f_start_phase : assert always
      --    state = START_ST -> (phase = ADDR_PH or phase = RADDR_PH);
      -- psl f_reg : assert always phase = REG_PH -> a_noreg = '0';
      -- psl f_rdata : assert always phase = RDATA_PH -> (a_read = '1' and count(a_count) /= 0);
      -- psl f_raddr : assert always
      --    phase = RADDR_PH -> (a_read = '1' and a_noreg = '0' and count(a_count) /= 0);

      -- A byte of the data is one of the command's.
      -- psl f_idx : assert always
      --    (state = BYTE_ST and (phase = WDATA_PH or phase = RDATA_PH)) -> idx < count(a_count);

      -- A read of a byte with no register, which a chip answers
      -- psl c_read : cover {f_cmd = '1' and wdata_i(7) = '1' and wdata_i(21 downto 16) = "100001" and
      --                     busy = '0' and rst_i = '0';
      --                     (not rst_i)[*];
      --                     state = IDLE_ST and nack = '0' and tmo = '0' and rst_i = '0'};
      -- psl c_nack : cover {nack = '1' and state = IDLE_ST and rst_i = '0'};
      -- psl c_tmo : cover {tmo = '1' and rst_i = '0'};
      -- psl c_recover : cover {state = RECOVER_ST and rst_i = '0'; state = STOP_ST and rst_i = '0'};

   end generate gen_formal;

end architecture synthesis;
