-- Tests the I2C master (src/i2c.vhd) on three chip models
-- (i2c_chip_model.vhd), through its words, as a program would use them.
--
-- PASS AND FAIL
-- Each check is an assert with severity failure, which stops GHDL with a
-- nonzero exit status. The test ends with stop(0).
--
-- THEORY OF OPERATION
-- The bus has the R6's real-time clock, an RV-3032-C7 at 0x51, which a
-- reset left holding SDA low; the R3's, an ISL12020M at 0x6F, which
-- stretches the clock; and the Nexys4DDR's temperature sensor, an ADT7420
-- at 0x4B, whose register 0x0B, its ID, is 0xCB. The lines are pulled up
-- with 'H'. The clock is 10 MHz and the bus runs at its 100 kHz, but the
-- timeout is 200 us, so that its step is short. The steps:
--
-- 1. After reset the master recovers the bus: it is busy, then idle with
--    SDA high, and the status is present, with no NACK or timeout.
-- 2. A read of 14 bytes of the RV-3032 from register 0: its registers.
-- 3. A read of 8 bytes of the ISL12020M, which stretches the clock.
-- 4. A read of the ADT7420's ID, a byte from register 0x0B.
-- 5. A write of 3 bytes to the ADT7420 at register 0x10, and a read of
--    them.
-- 6. With "no register": a write of the register alone, then a read of a
--    byte, which comes from that register.
-- 7. A count of 20 reads 16 bytes.
-- 8. A chip that is not there: NACK, and the bus idle after STOP.
-- 9. A command and the data written while a transaction runs are dropped.
-- 10. SCL held low: timeout, and the next command clears it.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

   use std.env.all;

entity tb_i2c is
end entity tb_i2c;

architecture simulation of tb_i2c is

   constant C_CLOCK_HZ : natural := 10_000_000;
   constant C_PERIOD   : time    := 1 sec / C_CLOCK_HZ;

   signal clk : std_logic;
   signal rst : std_logic := '1';

   signal stb   : std_logic                     := '0';
   signal we    : std_logic                     := '0';
   signal addr  : std_logic_vector(3 downto 0)  := X"0";
   signal wdata : std_logic_vector(31 downto 0) := (others => '0');
   signal rdata : std_logic_vector(31 downto 0);

   signal scl_o : std_logic;
   signal sda_o : std_logic;
   signal scl   : std_logic;
   signal sda   : std_logic;
   -- The testbench holds SCL low for the timeout
   signal hold : std_logic := '0';

   constant C_CMD    : std_logic_vector(3 downto 0) := X"7";
   constant C_STATUS : std_logic_vector(3 downto 0) := X"8";
   constant C_DATA   : std_logic_vector(3 downto 0) := X"9";

   -- The registers of the chips: the RV-3032 at 2026-11-11 12:34:56.50,
   -- the ISL12020M at the same time, in 24-hour mode, and the ADT7420's ID
   constant C_RV_REGS  : std_logic_vector(255 downto 0) := X"000000000000000000000000000000000F0E0000000000002611110312345650";
   constant C_ISL_REGS : std_logic_vector(255 downto 0) := X"0000000000000000000000000000000000000000000000000003261111923456";
   constant C_ADT_REGS : std_logic_vector(255 downto 0) := X"0000000000000000000000000000000000000000CB0000000000000000000000";

   function regs_byte (r : std_logic_vector(255 downto 0);
                       i : natural) return std_logic_vector is
   begin
      return r(8 * i + 7 downto 8 * i);
   end function regs_byte;

begin

   p_clk : process
   begin
      clk <= '1', '0' after C_PERIOD / 2;
      wait for C_PERIOD;
   end process p_clk;


   i_i2c : entity work.i2c
      generic map (
         G_CLOCK_HZ   => C_CLOCK_HZ,
         G_TIMEOUT_US => 200
      )
      port map (
         clk_i   => clk,
         rst_i   => rst,
         stb_i   => stb,
         we_i    => we,
         addr_i  => addr,
         wdata_i => wdata,
         rdata_o => rdata,
         scl_o   => scl_o,
         sda_o   => sda_o,
         scl_i   => to_x01(scl),
         sda_i   => to_x01(sda)
      ); -- i_i2c

   -- The open-drain lines, with their pull-ups
   scl <= 'H';
   sda <= 'H';
   scl <= '0' when scl_o = '0' or hold = '1' else
          'Z';
   sda <= '0' when sda_o = '0' else
          'Z';


   i_rv : entity work.i2c_chip_model
      generic map (
         G_ADDR  => "1010001",
         G_REGS  => C_RV_REGS,
         G_STUCK => 3
      )
      port map (
         scl_io => scl,
         sda_io => sda
      ); -- i_rv


   i_isl : entity work.i2c_chip_model
      generic map (
         G_ADDR    => "1101111",
         G_REGS    => C_ISL_REGS,
         G_STRETCH => 15 us
      )
      port map (
         scl_io => scl,
         sda_io => sda
      ); -- i_isl


   i_adt : entity work.i2c_chip_model
      generic map (
         G_ADDR => "1001011",
         G_REGS => C_ADT_REGS
      )
      port map (
         scl_io => scl,
         sda_io => sda
      ); -- i_adt


   p_test : process

      procedure write_word (a : std_logic_vector(3 downto 0);
                            d : std_logic_vector(31 downto 0)) is
      begin
         wait until rising_edge(clk);
         stb   <= '1';
         we    <= '1';
         addr  <= a;
         wdata <= d;
         wait until rising_edge(clk);
         stb   <= '0';
         we    <= '0';
      end procedure write_word;

      procedure read_word (a : std_logic_vector(3 downto 0);
                           d : out std_logic_vector(31 downto 0)) is
      begin
         wait until rising_edge(clk);
         addr <= a;
         wait for C_PERIOD / 4;
         d    := rdata;
      end procedure read_word;

      -- Waits until the master is idle, and returns the status
      procedure wait_idle (s : out std_logic_vector(31 downto 0)) is
         variable s_v : std_logic_vector(31 downto 0);
      begin
         loop
            read_word(C_STATUS, s_v);
            exit when s_v(1) = '0';
         end loop;
         s := s_v;
      end procedure wait_idle;

      -- A command: the chip, read or write, the register, the count, and
      -- "no register"; its status when it is done
      procedure command (chip  : std_logic_vector(6 downto 0);
                         rd    : std_logic;
                         reg   : std_logic_vector(7 downto 0);
                         n     : natural;
                         noreg : std_logic;
                         s     : out std_logic_vector(31 downto 0)) is
         variable s_v : std_logic_vector(31 downto 0);
      begin
         write_word(C_CMD, X"00" & "00" & noreg & to_slv(n, 5) & reg & rd & chip);
         read_word(C_STATUS, s_v);
         assert s_v(1) = '1'
            report "tb_i2c: not busy after a command"
            severity failure;
         wait_idle(s);
      end procedure command;

      -- Byte i of the data
      procedure data_byte (i : natural;
                           b : out std_logic_vector(7 downto 0)) is
         variable w_v : std_logic_vector(31 downto 0);
      begin
         read_word(C_DATA + i / 4, w_v);
         b := w_v(8 * (i mod 4) + 7 downto 8 * (i mod 4));
      end procedure data_byte;

      procedure check_ok (s   : std_logic_vector(31 downto 0);
                          msg : string) is
      begin
         assert s = X"00000001"
            report "tb_i2c: " & msg & ": status " & to_hstring(s)
            severity failure;
      end procedure check_ok;

      -- The bytes of a read, against a chip's registers from register r
      procedure check_bytes (r   : std_logic_vector(255 downto 0);
                             reg : natural;
                             n   : natural;
                             msg : string) is
         variable b_v : std_logic_vector(7 downto 0);
      begin
         for i in 0 to n - 1 loop
            data_byte(i, b_v);
            assert b_v = regs_byte(r, reg + i)
               report "tb_i2c: " & msg & ": byte " & natural'image(i) & " is " &
                      to_hstring(b_v) & ", not " & to_hstring(regs_byte(r, reg + i))
               severity failure;
         end loop;
      end procedure check_bytes;

      variable s_v : std_logic_vector(31 downto 0);
      variable w_v : std_logic_vector(31 downto 0);
      variable b_v : std_logic_vector(7 downto 0);

   begin
      wait for 1 us;
      wait until rising_edge(clk);
      rst <= '0';

      -- 1. The recovery of the bus, with the RV-3032 holding SDA low
      read_word(C_STATUS, s_v);
      assert s_v(1 downto 0) = "11"
         report "tb_i2c: not busy with the recovery after reset"
         severity failure;
      assert to_x01(sda) = '0'
         report "tb_i2c: SDA is not held low after reset"
         severity failure;
      wait_idle(s_v);
      check_ok(s_v, "the recovery");
      assert to_x01(sda) = '1' and to_x01(scl) = '1'
         report "tb_i2c: the bus is not idle after the recovery"
         severity failure;
      report "tb_i2c: step 1 done, the recovery";

      -- 2. The RV-3032's time and status
      command("1010001", '1', X"00", 14, '0', s_v);
      check_ok(s_v, "the RV-3032");
      check_bytes(C_RV_REGS, 0, 14, "the RV-3032");
      data_byte(14, b_v);
      assert b_v = X"00"
         report "tb_i2c: a read of 14 bytes changed byte 14"
         severity failure;
      report "tb_i2c: step 2 done, the RV-3032";

      -- 3. The ISL12020M, which stretches the clock
      command("1101111", '1', X"00", 8, '0', s_v);
      check_ok(s_v, "the ISL12020M");
      check_bytes(C_ISL_REGS, 0, 8, "the ISL12020M");
      report "tb_i2c: step 3 done, the ISL12020M";

      -- 4. The ADT7420's ID
      command("1001011", '1', X"0B", 1, '0', s_v);
      check_ok(s_v, "the ADT7420's ID");
      data_byte(0, b_v);
      assert b_v = X"CB"
         report "tb_i2c: the ADT7420's ID is " & to_hstring(b_v)
         severity failure;
      report "tb_i2c: step 4 done, the ADT7420";

      -- 5. A write of 3 bytes, and a read of them
      write_word(C_DATA, X"00C3B2A1");
      command("1001011", '0', X"10", 3, '0', s_v);
      check_ok(s_v, "the write");
      write_word(C_DATA, X"00000000");
      command("1001011", '1', X"10", 3, '0', s_v);
      check_ok(s_v, "the read of the write");
      read_word(C_DATA, w_v);
      assert w_v = X"00C3B2A1"
         report "tb_i2c: the bytes written read " & to_hstring(w_v)
         severity failure;
      report "tb_i2c: step 5 done, the write";

      -- 6. No register: the register alone, then a byte read
      command("1001011", '0', X"0B", 0, '0', s_v);
      check_ok(s_v, "the register alone");
      command("1001011", '1', X"00", 1, '1', s_v);
      check_ok(s_v, "the read with no register");
      data_byte(0, b_v);
      assert b_v = X"CB"
         report "tb_i2c: the read with no register is " & to_hstring(b_v)
         severity failure;
      report "tb_i2c: step 6 done, no register";

      -- 7. A count of 20 reads 16 bytes.
      command("1010001", '1', X"00", 20, '0', s_v);
      check_ok(s_v, "the count of 20");
      check_bytes(C_RV_REGS, 0, 16, "the count of 20");
      read_word(C_CMD, w_v);
      assert w_v = X"001400D1"
         report "tb_i2c: the command reads " & to_hstring(w_v)
         severity failure;
      report "tb_i2c: step 7 done, the count";

      -- 8. No chip at 0x22
      command("0100010", '1', X"00", 1, '0', s_v);
      assert s_v = X"00000005"
         report "tb_i2c: no chip: status " & to_hstring(s_v)
         severity failure;
      wait for 10 us;
      assert to_x01(sda) = '1' and to_x01(scl) = '1'
         report "tb_i2c: the bus is not idle after a NACK"
         severity failure;
      report "tb_i2c: step 8 done, the NACK";

      -- 9. A command and data while one runs
      write_word(C_DATA, X"11111111");
      write_word(C_CMD, X"00010BCB");
      write_word(C_CMD, X"000200A2");
      write_word(C_DATA, X"22222222");
      wait_idle(s_v);
      check_ok(s_v, "the command while busy");
      read_word(C_CMD, w_v);
      assert w_v = X"00010BCB"
         report "tb_i2c: a command while busy was taken: " & to_hstring(w_v)
         severity failure;
      read_word(C_DATA, w_v);
      assert w_v = X"111111CB"
         report "tb_i2c: data written while busy: " & to_hstring(w_v)
         severity failure;
      report "tb_i2c: step 9 done, busy";

      -- 10. SCL held low
      hold <= '1';
      command("1001011", '1', X"0B", 1, '0', s_v);
      assert s_v = X"00000009"
         report "tb_i2c: SCL held low: status " & to_hstring(s_v)
         severity failure;
      assert sda_o = '1' and scl_o = '1'
         report "tb_i2c: a line is pulled low after the timeout"
         severity failure;
      hold <= '0';
      wait for 10 us;
      command("1001011", '1', X"0B", 1, '0', s_v);
      check_ok(s_v, "after the timeout");
      data_byte(0, b_v);
      assert b_v = X"CB"
         report "tb_i2c: the ID after the timeout is " & to_hstring(b_v)
         severity failure;
      report "tb_i2c: step 10 done, the timeout";

      report "tb_i2c: all steps done";
      stop(0);
   end process p_test;

end architecture simulation;
