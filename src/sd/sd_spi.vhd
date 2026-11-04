-- The protocol engine of the SD card controller in SPI mode (#55): the
-- commands Init, Read, and Write of nice_cpu's SYSTEM.md §5, for the
-- registers and the buffer of nice_cpu/hdl/src/sd_regs.vhd.
--
-- THEORY OF OPERATION
-- sd_spi_byte.vhd moves the bytes, at 400 kHz during the start-up of the
-- card and at 25 MHz after it. The engine sends each command with a byte
-- of 0xFF before it, the gap, and its CRC7 after it, and reads up to 16
-- bytes for the answer, R1, a byte whose bit 7 is 0. A command with no
-- answer ends with error 3, a timeout. Each command ends with chip select
-- high and 8 clocks, and then done_o.
--
-- Init (command 0):
-- * With G_POWER, the card's power is off for 20 ms, with every line low,
--   and on for 10 ms before the start-up. So Init starts a card from
--   power-up even if it was left in another mode.
-- * 80 clocks with chip select and MOSI high, then CMD0, GO_IDLE_STATE,
--   until the card answers 0x01, idle, up to 8 times. A card that answered
--   none of them gives error 3, and one that answered something else 8.
-- * CMD8, SEND_IF_COND, with 0x1AA: a card that echoes it is version 2,
--   and one to which CMD8 is illegal is version 1.
-- * CMD59, CRC_ON_OFF, turns the CRCs on, so that a corrupted command or
--   block is caught as on the bus of SD mode (error 4).
-- * CMD55 and ACMD41, SD_SEND_OP_COND, with HCS for a version 2 card,
--   until the card leaves the idle state, for up to a second.
-- * CMD58, READ_OCR, of a version 2 card: its CCS bit says SDHC or SDXC,
--   type 2, which takes sector numbers, and else SDSC, type 1, which takes
--   byte addresses. A version 1 card is SDSC. An SDSC card gets CMD16,
--   SET_BLOCKLEN, of 512.
-- * The fast clock, and CMD9, SEND_CSD: the card's CSD register, as a
--   block of 16 bytes, whose size fields give the last sector, last_o. A
--   CSD of version 1 has C_SIZE, C_SIZE_MULT, and READ_BL_LEN, and one of
--   version 2 the C_SIZE in units of 1024 sectors. Another version, as of
--   an SDUC card, fails.
-- Any other answer than the expected one fails the Init with error 8.
--
-- Read (command 1) sends CMD17, READ_SINGLE_BLOCK, waits up to 100 ms for
-- the start token 0xFE, writes the 512 bytes into the buffer, and checks
-- their CRC16 (error 4). An error token instead of the start token, or an
-- R1 that is not 0, is error 5, or 4 if R1 says the command's CRC was
-- bad.
--
-- Write (command 2) sends CMD24, WRITE_BLOCK, then a gap, the start token,
-- the 512 bytes of the buffer, and their CRC16. The card's data response
-- says accepted, a CRC error (4), or a write error (5). The card then
-- holds MISO low while it writes, for up to 500 ms (error 3 after that).
--
-- The buffer's byte of buf_addr_o comes on buf_data_i in the cycle after;
-- a Write sets the address of the next byte while a byte goes out, so that
-- the byte is there long before it is needed.
--
-- Every wait has a timeout, counted in milliseconds, so every command
-- ends. abort_i ends a command at once, with chip select high and no
-- done_o, as sd_regs asks. A card that was in the middle of a block then
-- finishes it on its own, so the next Init first clocks 1024 bytes with
-- chip select low, more than a block, before CMD0. Only an Init can follow
-- an abort, as sd_regs is reset with it and "ready" is 0.
--
-- With G_FORMAL, it states the properties that formal/sd_spi.sby proves:
-- a command runs from start_i to its one done_o, the buffer is written
-- only with the bytes of a Read's block, chip select is high while no
-- command runs, and an abort or a reset ends a command at once, with no
-- done_o and no write of the buffer.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) start_i comes only while no command runs, with cmd_i and lba_i,
--    which hold until done_o or abort_i. A Read or a Write comes only
--    after an Init that succeeded, of the card that is still there, and
--    with a sector that is at most last_o.
-- b) abort_i comes only while a command runs.
-- c) The lines go to the card as sd_spi_byte.vhd asks.
--
-- RESET
-- Synchronous. Reset abandons a command, with no done_o, and turns the
-- power off with G_POWER. The Init after it clocks the 1024 bytes too.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;
   use ieee.numeric_std_unsigned.all;

entity sd_spi is
   generic (
      G_CLOCK_HZ : positive;
      -- The clock of the card during the start-up, and after it
      G_SLOW_HZ  : positive := 400_000;
      G_FAST_HZ  : positive := 25_000_000;
      -- Whether pwr_n_o switches the card's power
      G_POWER    : boolean  := false;
      -- The cycles of a millisecond, for the timeouts
      G_MS       : positive := G_CLOCK_HZ / 1000;
      -- The properties for formal/sd_spi.sby
      G_FORMAL   : boolean  := false
   );
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;

      -- A command of sd_regs, and its end
      start_i    : in  std_logic;
      abort_i    : in  std_logic;
      cmd_i      : in  std_logic_vector(1 downto 0);
      lba_i      : in  std_logic_vector(31 downto 0);
      done_o     : out std_logic                     := '0';
      error_o    : out std_logic_vector(3 downto 0)  := (others => '0');
      last_o     : out std_logic_vector(31 downto 0) := (others => '0');
      type_o     : out std_logic_vector(1 downto 0)  := (others => '0');

      -- The buffer of sd_regs, a byte at a time
      buf_addr_o : out std_logic_vector(8 downto 0)  := (others => '0');
      buf_we_o   : out std_logic                     := '0';
      buf_data_o : out std_logic_vector(7 downto 0)  := (others => '0');
      buf_data_i : in  std_logic_vector(7 downto 0);

      -- The card: chip select, its power, on while low, and the lines of
      -- sd_spi_byte.vhd
      cs_n_o     : out std_logic;
      pwr_n_o    : out std_logic;
      sclk_o     : out std_logic;
      mosi_o     : out std_logic;
      miso_i     : in  std_logic
   );
end entity sd_spi;

architecture synthesis of sd_spi is

   -- The half periods of the card's clock, at least 2 cycles when fast
   function half(hz : positive; min : positive) return positive is
      variable h_v : positive;
   begin
      h_v := (G_CLOCK_HZ + 2 * hz - 1) / (2 * hz);
      if h_v < min then
         return min;
      end if;
      return h_v;
   end function half;

   constant C_SLOW_HALF : positive := half(G_SLOW_HZ, 1);
   constant C_FAST_HALF : positive := half(G_FAST_HZ, 2);

   constant C_INIT  : std_logic_vector(1 downto 0) := "00";
   constant C_READ  : std_logic_vector(1 downto 0) := "01";
   constant C_WRITE : std_logic_vector(1 downto 0) := "10";

   constant C_ERR_NONE    : std_logic_vector(3 downto 0) := X"0";
   constant C_ERR_TIMEOUT : std_logic_vector(3 downto 0) := X"3";
   constant C_ERR_CRC     : std_logic_vector(3 downto 0) := X"4";
   constant C_ERR_CARD    : std_logic_vector(3 downto 0) := X"5";
   constant C_ERR_INIT    : std_logic_vector(3 downto 0) := X"8";

   -- The timeouts, in milliseconds
   constant C_PWR_OFF_MS : natural := 20;
   constant C_PWR_ON_MS  : natural := 10;
   constant C_OP_COND_MS : natural := 1000;
   constant C_TOKEN_MS   : natural := 100;
   constant C_BUSY_MS    : natural := 500;

   -- The tries of CMD0, and the bytes to wait for R1 and a data response
   constant C_CMD0_TRIES : natural := 8;
   constant C_R1_BYTES   : natural := 16;

   -- The states that move a byte (byte_r), and the ones that decide on
   -- what came back (the S_A* states, after a command's R1)
   type t_state is (
      S_IDLE, S_PWR_OFF, S_PWR_ON, S_CLOCKS, S_FLUSH, S_CMD, S_R1, S_R4,
      S_A0, S_A8, S_A8B, S_A59, S_A55, S_A41, S_A58, S_A58B, S_A16, S_A9,
      S_A17, S_A24, S_TOKEN, S_DATA, S_CRC, S_CSD,
      S_W_GAP, S_W_TOKEN, S_W_DATA, S_W_CRC, S_W_RESP, S_W_BUSY, S_END
   );

   signal state_r : t_state := S_IDLE;
   signal ret_r   : t_state := S_IDLE;

   -- The command in progress, its error, and the card's version (2 or 1),
   -- type, and CSD
   signal cmd_r  : std_logic_vector(1 downto 0)    := C_INIT;
   signal err_r  : std_logic_vector(3 downto 0)    := C_ERR_NONE;
   signal v2_r   : std_logic                       := '0';
   signal type_r : std_logic_vector(1 downto 0)    := "00";
   signal csd_r  : std_logic_vector(127 downto 0)  := (others => '0');

   -- The command to send, its argument, and its CRC7; its answer, and the
   -- 4 bytes after R1 of R3 and R7
   signal idx_r   : std_logic_vector(5 downto 0)    := (others => '0');
   signal arg_r   : std_logic_vector(31 downto 0)   := (others => '0');
   signal crc7_r  : std_logic_vector(6 downto 0)    := (others => '0');
   signal r1_r    : std_logic_vector(7 downto 0)    := X"FF";
   signal ocr_r   : std_logic_vector(31 downto 0)   := (others => '0');
   signal crc16_r : std_logic_vector(15 downto 0)   := (others => '0');
   signal rcrc_r  : std_logic_vector(15 downto 0)   := (others => '0');

   -- The bytes of a step, the tries of CMD0 and whether any was answered,
   -- and whether a block is the CSD
   signal cnt_r      : natural range 0 to 1023       := 0;
   signal aborted_r  : std_logic                     := '1';
   signal tries_r    : natural range 0 to C_CMD0_TRIES := 0;
   signal answered_r : std_logic                     := '0';
   signal csd_mode_r : std_logic                     := '0';

   -- The milliseconds left of a wait
   signal tick_cnt_r : natural range 0 to G_MS - 1   := 0;
   signal tick_r     : std_logic                     := '0';
   signal tmo_r      : natural range 0 to C_OP_COND_MS + 1 := 0;

   -- The lines
   signal cs_n_r  : std_logic := '1';
   signal pwr_n_r : std_logic := '1';
   signal fast_r  : std_logic := '0';

   -- The byte that moves, and its end
   signal io_rst   : std_logic;
   signal io_start : std_logic                    := '0';
   signal io_tx    : std_logic_vector(7 downto 0) := X"FF";
   signal io_done  : std_logic;
   signal io_rx    : std_logic_vector(7 downto 0);
   signal byte_r   : std_logic                    := '0';

   -- The CRC7 of the bytes of a command, and the CRC16 of the bytes of a
   -- block, each after one more byte
   function crc7(crc : std_logic_vector(6 downto 0);
                 b   : std_logic_vector(7 downto 0)) return std_logic_vector is
      variable c_v : std_logic_vector(6 downto 0) := crc;
      variable f_v : std_logic;
   begin
      for i in 7 downto 0 loop
         f_v := c_v(6) xor b(i);
         c_v := c_v(5 downto 0) & '0';
         if f_v = '1' then
            c_v := c_v xor "0001001";
         end if;
      end loop;
      return c_v;
   end function crc7;

   function crc16(crc : std_logic_vector(15 downto 0);
                  b   : std_logic_vector(7 downto 0)) return std_logic_vector is
      variable c_v : std_logic_vector(15 downto 0) := crc;
      variable f_v : std_logic;
   begin
      for i in 7 downto 0 loop
         f_v := c_v(15) xor b(i);
         c_v := c_v(14 downto 0) & '0';
         if f_v = '1' then
            c_v := c_v xor X"1021";
         end if;
      end loop;
      return c_v;
   end function crc16;

   -- The byte n of a command, 1 to 5, before its CRC
   function cmd_byte(idx : std_logic_vector(5 downto 0);
                     arg : std_logic_vector(31 downto 0);
                     n   : natural) return std_logic_vector is
   begin
      case n is
         when 1      => return "01" & idx;
         when 2      => return arg(31 downto 24);
         when 3      => return arg(23 downto 16);
         when 4      => return arg(15 downto 8);
         when others => return arg(7 downto 0);
      end case;
   end function cmd_byte;

   -- The last sector of a card from its CSD, and whether the CSD is one
   -- this engine knows
   function csd_last(csd : std_logic_vector(127 downto 0)) return std_logic_vector is
      variable size_v  : std_logic_vector(32 downto 0);
      variable shift_v : integer;
   begin
      if csd(127 downto 126) = "01" then
         return csd(69 downto 48) & "1111111111";
      end if;
      -- (C_SIZE + 1) * 2^(C_SIZE_MULT + 2) * 2^READ_BL_LEN / 512, where
      -- csd_ok has checked that READ_BL_LEN is 9 to 11
      shift_v := to_integer(csd(49 downto 47)) + 2 + to_integer(csd(83 downto 80)) - 9;
      if shift_v < 0 or shift_v > 20 then
         shift_v := 0;
      end if;
      size_v := ("0" & X"00000" & csd(73 downto 62)) + 1;
      size_v := shift_left(size_v, shift_v) - 1;
      return size_v(31 downto 0);
   end function csd_last;

   function csd_ok(csd : std_logic_vector(127 downto 0)) return boolean is
   begin
      if csd(127 downto 126) = "01" then
         return true;
      end if;
      return csd(127 downto 126) = "00" and csd(83 downto 80) >= 9 and csd(83 downto 80) <= 11;
   end function csd_ok;

begin

   io_rst  <= rst_i or abort_i;
   cs_n_o  <= cs_n_r;
   pwr_n_o <= pwr_n_r;

   i_sd_spi_byte : entity work.sd_spi_byte
      generic map (
         G_SLOW_HALF => C_SLOW_HALF,
         G_FAST_HALF => C_FAST_HALF
      )
      port map (
         clk_i   => clk_i,
         rst_i   => io_rst,
         fast_i  => fast_r,
         start_i => io_start,
         data_i  => io_tx,
         done_o  => io_done,
         data_o  => io_rx,
         sclk_o  => sclk_o,
         mosi_o  => mosi_o,
         miso_i  => miso_i
      ); -- i_sd_spi_byte


   -- A tick every millisecond, for the timeouts
   p_tick : process (clk_i)
   begin
      if rising_edge(clk_i) then
         tick_r <= '0';
         if tick_cnt_r = G_MS - 1 then
            tick_cnt_r <= 0;
            tick_r     <= '1';
         else
            tick_cnt_r <= tick_cnt_r + 1;
         end if;
      end if;
   end process p_tick;


   p_fsm : process (clk_i)
      -- Send a command, and go on in ret with its R1 in r1_r, 0xFF if none
      procedure issue(idx : natural; arg : std_logic_vector(31 downto 0); ret : t_state) is
      begin
         idx_r   <= std_logic_vector(to_unsigned(idx, 6));
         arg_r   <= arg;
         ret_r   <= ret;
         cnt_r   <= 0;
         state_r <= S_CMD;
      end procedure issue;

      -- End the command with an error
      procedure fail(err : std_logic_vector(3 downto 0)) is
      begin
         err_r   <= err;
         state_r <= S_END;
      end procedure fail;

      -- The error of an R1 that is not 0 after a Read or a Write
      function r1_err(r1 : std_logic_vector(7 downto 0)) return std_logic_vector is
      begin
         if r1 = X"FF" then
            return C_ERR_TIMEOUT;
         elsif r1(3) = '1' then
            return C_ERR_CRC;
         end if;
         return C_ERR_CARD;
      end function r1_err;

      -- The argument of a Read or a Write: the sector, or its byte address
      function addr(lba : std_logic_vector(31 downto 0);
                    typ : std_logic_vector(1 downto 0)) return std_logic_vector is
      begin
         if typ = "10" then
            return lba;
         end if;
         return lba(22 downto 0) & "000000000";
      end function addr;

      -- Move a byte
      procedure xfer(b : std_logic_vector(7 downto 0)) is
      begin
         io_start <= '1';
         io_tx    <= b;
         byte_r   <= '1';
      end procedure xfer;

      variable rx_v : std_logic_vector(7 downto 0);
   begin
      if rising_edge(clk_i) then
         io_start <= '0';
         done_o   <= '0';
         buf_we_o <= '0';

         if tick_r = '1' and tmo_r /= 0 then
            tmo_r <= tmo_r - 1;
         end if;

         if byte_r = '1' then
            -- What came back of the byte that moved
            if io_done = '1' then
               byte_r <= '0';
               rx_v   := io_rx;

               case state_r is

                  when S_CLOCKS =>
                     if cnt_r = 9 then
                        cnt_r <= 0;
                        if aborted_r = '1' then
                           state_r <= S_FLUSH;
                        else
                           tries_r    <= 0;
                           answered_r <= '0';
                           issue(0, X"00000000", S_A0);
                        end if;
                     else
                        cnt_r <= cnt_r + 1;
                     end if;

                  when S_FLUSH =>
                     if cnt_r = 1023 then
                        aborted_r  <= '0';
                        tries_r    <= 0;
                        answered_r <= '0';
                        issue(0, X"00000000", S_A0);
                     else
                        cnt_r <= cnt_r + 1;
                     end if;

                  when S_CMD =>
                     if cnt_r >= 1 and cnt_r <= 5 then
                        crc7_r <= crc7(crc7_r, cmd_byte(idx_r, arg_r, cnt_r));
                     end if;
                     if cnt_r = 6 then
                        cnt_r   <= 0;
                        state_r <= S_R1;
                     else
                        cnt_r <= cnt_r + 1;
                     end if;

                  when S_R1 =>
                     if rx_v(7) = '0' then
                        r1_r    <= rx_v;
                        state_r <= ret_r;
                     elsif cnt_r = C_R1_BYTES - 1 then
                        r1_r    <= X"FF";
                        state_r <= ret_r;
                     else
                        cnt_r <= cnt_r + 1;
                     end if;

                  when S_R4 =>
                     ocr_r <= ocr_r(23 downto 0) & rx_v;
                     if cnt_r = 3 then
                        state_r <= ret_r;
                     else
                        cnt_r <= cnt_r + 1;
                     end if;

                  when S_TOKEN =>
                     if rx_v = X"FE" then
                        cnt_r   <= 0;
                        crc16_r <= (others => '0');
                        state_r <= S_DATA;
                     elsif rx_v /= X"FF" then
                        if cmd_r = C_INIT then
                           fail(C_ERR_INIT);
                        else
                           fail(C_ERR_CARD);
                        end if;
                     elsif tmo_r = 0 then
                        fail(C_ERR_TIMEOUT);
                     end if;

                  when S_DATA =>
                     crc16_r <= crc16(crc16_r, rx_v);
                     if csd_mode_r = '1' then
                        csd_r <= csd_r(119 downto 0) & rx_v;
                     else
                        buf_we_o   <= '1';
                        buf_addr_o <= std_logic_vector(to_unsigned(cnt_r, 9));
                        buf_data_o <= rx_v;
                     end if;
                     if (csd_mode_r = '1' and cnt_r = 15) or cnt_r = 511 then
                        cnt_r   <= 0;
                        state_r <= S_CRC;
                     else
                        cnt_r <= cnt_r + 1;
                     end if;

                  when S_CRC =>
                     rcrc_r <= rcrc_r(7 downto 0) & rx_v;
                     if cnt_r = 1 then
                        if (rcrc_r(7 downto 0) & rx_v) /= crc16_r then
                           fail(C_ERR_CRC);
                        elsif csd_mode_r = '1' then
                           state_r <= S_CSD;
                        else
                           state_r <= S_END;
                        end if;
                     else
                        cnt_r <= cnt_r + 1;
                     end if;

                  when S_W_GAP =>
                     state_r <= S_W_TOKEN;

                  when S_W_TOKEN =>
                     cnt_r   <= 0;
                     crc16_r <= (others => '0');
                     state_r <= S_W_DATA;

                  when S_W_DATA =>
                     if cnt_r = 511 then
                        cnt_r   <= 0;
                        state_r <= S_W_CRC;
                     else
                        cnt_r <= cnt_r + 1;
                     end if;

                  when S_W_CRC =>
                     if cnt_r = 1 then
                        cnt_r   <= 0;
                        state_r <= S_W_RESP;
                     else
                        cnt_r <= cnt_r + 1;
                     end if;

                  when S_W_RESP =>
                     -- The data response: xxx0sss1
                     if rx_v(4) = '0' and rx_v(0) = '1' then
                        if rx_v(3 downto 1) = "010" then
                           tmo_r   <= C_BUSY_MS + 1;
                           state_r <= S_W_BUSY;
                        elsif rx_v(3 downto 1) = "101" then
                           fail(C_ERR_CRC);
                        else
                           fail(C_ERR_CARD);
                        end if;
                     elsif cnt_r = C_R1_BYTES - 1 then
                        fail(C_ERR_TIMEOUT);
                     else
                        cnt_r <= cnt_r + 1;
                     end if;

                  when S_W_BUSY =>
                     if rx_v /= X"00" then
                        state_r <= S_END;
                     elsif tmo_r = 0 then
                        fail(C_ERR_TIMEOUT);
                     end if;

                  when S_END =>
                     done_o  <= '1';
                     error_o <= err_r;
                     if cmd_r = C_INIT and err_r = C_ERR_NONE then
                        type_o <= type_r;
                        last_o <= csd_last(csd_r);
                     end if;
                     state_r <= S_IDLE;

                  when others =>
                     null;

               end case;
            end if;
         else
            -- Start the byte of the state, or decide
            case state_r is

               when S_IDLE =>
                  if start_i = '1' then
                     cmd_r <= cmd_i;
                     err_r <= C_ERR_NONE;
                     case cmd_i is
                        when C_INIT =>
                           type_r <= "00";
                           fast_r <= '0';
                           cnt_r  <= 0;
                           if G_POWER then
                              tmo_r   <= C_PWR_OFF_MS + 1;
                              state_r <= S_PWR_OFF;
                           else
                              state_r <= S_CLOCKS;
                           end if;

                        when C_READ =>
                           csd_mode_r <= '0';
                           issue(17, addr(lba_i, type_r), S_A17);

                        when C_WRITE =>
                           issue(24, addr(lba_i, type_r), S_A24);

                        when others =>
                           state_r <= S_END;
                     end case;
                  end if;

               when S_PWR_OFF =>
                  pwr_n_r <= '1';
                  if tmo_r = 0 then
                     tmo_r   <= C_PWR_ON_MS + 1;
                     state_r <= S_PWR_ON;
                  end if;

               when S_PWR_ON =>
                  pwr_n_r <= '0';
                  if tmo_r = 0 then
                     state_r <= S_CLOCKS;
                  end if;

               when S_CLOCKS =>
                  cs_n_r <= '1';
                  xfer(X"FF");

               when S_CMD =>
                  cs_n_r <= '0';
                  case cnt_r is
                     when 0 =>
                        crc7_r <= (others => '0');
                        xfer(X"FF");

                     when 6 =>
                        xfer(crc7_r & '1');

                     when others =>
                        xfer(cmd_byte(idx_r, arg_r, cnt_r));
                  end case;

               when S_FLUSH =>
                  cs_n_r <= '0';
                  xfer(X"FF");

               when S_R1 | S_R4 | S_TOKEN | S_DATA | S_CRC | S_W_RESP | S_W_BUSY =>
                  xfer(X"FF");

               when S_A0 =>
                  if r1_r /= X"FF" then
                     answered_r <= '1';
                  end if;
                  if r1_r = X"01" then
                     issue(8, X"000001AA", S_A8);
                  elsif tries_r = C_CMD0_TRIES - 1 then
                     if answered_r = '1' or r1_r /= X"FF" then
                        fail(C_ERR_INIT);
                     else
                        fail(C_ERR_TIMEOUT);
                     end if;
                  else
                     tries_r <= tries_r + 1;
                     issue(0, X"00000000", S_A0);
                  end if;

               when S_A8 =>
                  if r1_r = X"01" then
                     cnt_r   <= 0;
                     ret_r   <= S_A8B;
                     state_r <= S_R4;
                  elsif r1_r = X"05" then
                     v2_r <= '0';
                     issue(59, X"00000001", S_A59);
                  elsif r1_r = X"FF" then
                     fail(C_ERR_TIMEOUT);
                  else
                     fail(C_ERR_INIT);
                  end if;

               when S_A8B =>
                  if ocr_r(11 downto 0) = X"1AA" then
                     v2_r <= '1';
                     issue(59, X"00000001", S_A59);
                  else
                     fail(C_ERR_INIT);
                  end if;

               when S_A59 =>
                  if r1_r = X"01" then
                     tmo_r <= C_OP_COND_MS + 1;
                     issue(55, X"00000000", S_A55);
                  elsif r1_r = X"FF" then
                     fail(C_ERR_TIMEOUT);
                  else
                     fail(C_ERR_INIT);
                  end if;

               when S_A55 =>
                  if r1_r = X"01" or r1_r = X"00" then
                     -- HCS, bit 30, for a version 2 card; an SDHC card
                     -- stays idle without it.
                     issue(41, "0" & v2_r & "00" & X"0000000", S_A41);
                  elsif r1_r = X"FF" then
                     fail(C_ERR_TIMEOUT);
                  else
                     fail(C_ERR_INIT);
                  end if;

               when S_A41 =>
                  if r1_r = X"00" then
                     if v2_r = '1' then
                        issue(58, X"00000000", S_A58);
                     else
                        type_r <= "01";
                        issue(16, X"00000200", S_A16);
                     end if;
                  elsif r1_r = X"01" and tmo_r /= 0 then
                     issue(55, X"00000000", S_A55);
                  elsif r1_r = X"FF" then
                     fail(C_ERR_TIMEOUT);
                  else
                     fail(C_ERR_INIT);
                  end if;

               when S_A58 =>
                  if r1_r = X"00" then
                     cnt_r   <= 0;
                     ret_r   <= S_A58B;
                     state_r <= S_R4;
                  elsif r1_r = X"FF" then
                     fail(C_ERR_TIMEOUT);
                  else
                     fail(C_ERR_INIT);
                  end if;

               when S_A58B =>
                  if ocr_r(30) = '1' then
                     type_r <= "10";
                     fast_r <= '1';
                     issue(9, X"00000000", S_A9);
                  else
                     type_r <= "01";
                     issue(16, X"00000200", S_A16);
                  end if;

               when S_A16 =>
                  if r1_r = X"00" then
                     fast_r <= '1';
                     issue(9, X"00000000", S_A9);
                  elsif r1_r = X"FF" then
                     fail(C_ERR_TIMEOUT);
                  else
                     fail(C_ERR_INIT);
                  end if;

               when S_A9 =>
                  if r1_r = X"00" then
                     csd_mode_r <= '1';
                     tmo_r      <= C_TOKEN_MS + 1;
                     state_r    <= S_TOKEN;
                  elsif r1_r = X"FF" then
                     fail(C_ERR_TIMEOUT);
                  else
                     fail(C_ERR_INIT);
                  end if;

               when S_CSD =>
                  if csd_ok(csd_r) then
                     state_r <= S_END;
                  else
                     fail(C_ERR_INIT);
                  end if;

               when S_A17 =>
                  if r1_r = X"00" then
                     tmo_r   <= C_TOKEN_MS + 1;
                     state_r <= S_TOKEN;
                  else
                     fail(r1_err(r1_r));
                  end if;

               when S_A24 =>
                  if r1_r = X"00" then
                     state_r <= S_W_GAP;
                  else
                     fail(r1_err(r1_r));
                  end if;

               when S_W_GAP =>
                  xfer(X"FF");

               when S_W_TOKEN =>
                  buf_addr_o <= (others => '0');
                  xfer(X"FE");

               when S_W_DATA =>
                  crc16_r    <= crc16(crc16_r, buf_data_i);
                  buf_addr_o <= std_logic_vector(to_unsigned((cnt_r + 1) mod 512, 9));
                  xfer(buf_data_i);

               when S_W_CRC =>
                  if cnt_r = 0 then
                     xfer(crc16_r(15 downto 8));
                  else
                     xfer(crc16_r(7 downto 0));
                  end if;

               when S_END =>
                  cs_n_r <= '1';
                  xfer(X"FF");

            end case;
         end if;

         if abort_i = '1' then
            state_r   <= S_IDLE;
            byte_r    <= '0';
            cs_n_r    <= '1';
            done_o    <= '0';
            buf_we_o  <= '0';
            aborted_r <= '1';
         end if;

         if rst_i = '1' then
            state_r <= S_IDLE;
            byte_r  <= '0';
            cs_n_r  <= '1';
            pwr_n_r <= '1';
            fast_r  <= '0';
            type_r  <= "00";
            done_o  <= '0';
            buf_we_o <= '0';
            tmo_r   <= 0;
            -- The card may have been in the middle of a block.
            aborted_r <= '1';
         end if;
      end if;
   end process p_fsm;


   gen_formal : if G_FORMAL generate
      -- The state of the cycle before, and whether a command runs, as the
      -- environment sees it: from start_i to done_o, abort_i, or reset
      signal f_state_d : t_state   := S_IDLE;
      signal f_run     : std_logic := '0';
      -- The return state is one that issue() or an R4 gives it.
      signal f_ret_ok : std_logic;
      -- The state is one of t_state, not another value of its encoding.
      signal f_valid : std_logic;

      function valid(st : t_state) return std_logic is
      begin
         for i in t_state loop
            if st = i then
               return '1';
            end if;
         end loop;
         return '0';
      end function valid;

   begin

      f_valid <= valid(state_r);

      f_ret_ok <= '1' when ret_r = S_A0 or ret_r = S_A8 or ret_r = S_A8B or ret_r = S_A59 or
                           ret_r = S_A55 or ret_r = S_A41 or ret_r = S_A58 or ret_r = S_A58B or
                           ret_r = S_A16 or ret_r = S_A9 or ret_r = S_A17 or ret_r = S_A24 else
                  '0';

      p_follow : process (clk_i)
      begin
         if rising_edge(clk_i) then
            f_state_d <= state_r;
            if start_i = '1' then
               f_run <= '1';
            end if;
            if done_o = '1' then
               f_run <= '0';
            end if;
            if abort_i = '1' or rst_i = '1' then
               f_run <= '0';
            end if;
         end if;
      end process p_follow;

      -- psl default clock is rising_edge(clk_i);

      -- The contracts a) and b): a start only while no command runs, and
      -- an abort only while one does
      -- psl f_start_idle : assume always start_i -> f_run = '0' and done_o = '0' and abort_i = '0';
      -- psl f_abort_run : assume always abort_i -> f_run = '1' and done_o = '0';

      -- psl f_state_valid : assert always f_valid = '1';
      -- A block is a Read's, or the CSD of an Init, and the commands that
      -- lead to it are those of the command.
      -- psl f_block : assert always
      --    (state_r = S_TOKEN or state_r = S_DATA or state_r = S_CRC) ->
      --    ((cmd_r = C_INIT and csd_mode_r = '1') or (cmd_r = C_READ and csd_mode_r = '0'));
      -- psl f_read_mode : assert always
      --    state_r /= S_IDLE and cmd_r = C_READ -> csd_mode_r = '0';
      -- psl f_cmd_ret : assert always
      --    (state_r = S_CMD or state_r = S_R1 or state_r = S_R4) ->
      --    ((ret_r = S_A17) = (cmd_r = C_READ) and (ret_r = S_A24) = (cmd_r = C_WRITE));
      -- psl f_cmd_known : assert always
      --    state_r /= S_IDLE and state_r /= S_END -> cmd_r /= "11";
      -- psl f_cmd_a17 : assert always state_r = S_A17 -> cmd_r = C_READ;
      -- psl f_cmd_a24 : assert always state_r = S_A24 -> cmd_r = C_WRITE;
      -- psl f_cmd_init : assert always
      --    (state_r = S_PWR_OFF or state_r = S_PWR_ON or state_r = S_CLOCKS or state_r = S_FLUSH or
      --     state_r = S_A0 or state_r = S_A8 or state_r = S_A8B or state_r = S_A59 or
      --     state_r = S_A55 or state_r = S_A41 or state_r = S_A58 or state_r = S_A58B or
      --     state_r = S_A16 or state_r = S_A9 or state_r = S_CSD) -> cmd_r = C_INIT;
      -- psl f_cmd_write : assert always
      --    (state_r = S_W_GAP or state_r = S_W_TOKEN or state_r = S_W_DATA or state_r = S_W_CRC or
      --     state_r = S_W_RESP or state_r = S_W_BUSY) -> cmd_r = C_WRITE;

      -- A command runs while the engine is not idle, or ends with done_o.
      -- psl f_run_state : assert always rst_i = '0' ->
      --    ((f_run = '1') = (state_r /= S_IDLE or done_o = '1'));
      -- psl f_done_end : assert always done_o -> f_state_d = S_END and state_r = S_IDLE;
      -- psl f_done_pulse : assert always {done_o} |=> {not done_o};
      -- psl f_idle_cs : assert always state_r = S_IDLE -> cs_n_r = '1' and byte_r = '0';
      -- psl f_end_cs : assert always state_r = S_END and byte_r = '1' -> cs_n_r = '1';
      -- psl f_ret : assert always
      --    (state_r = S_CMD or state_r = S_R1 or state_r = S_R4) -> f_ret_ok = '1';
      -- psl f_we_read : assert always
      --    buf_we_o -> f_state_d = S_DATA and cmd_r = C_READ and csd_mode_r = '0';
      -- psl f_abort : assert always
      --    {abort_i = '1'} |=> {state_r = S_IDLE and done_o = '0' and buf_we_o = '0'};
      -- psl f_reset : assert always
      --    {rst_i = '1'} |=> {state_r = S_IDLE and done_o = '0' and buf_we_o = '0' and pwr_n_r = '1'};

      -- psl c_read_go : cover {start_i = '1' and cmd_i = C_READ and rst_i = '0'; [*]; cs_n_r = '0' and byte_r = '1'};
      -- psl c_init_go : cover {start_i = '1' and cmd_i = C_INIT and rst_i = '0'; [*]; state_r = S_CLOCKS};
      -- psl c_abort : cover {state_r = S_CMD and byte_r = '1' and rst_i = '0'; abort_i = '1'};
   end generate gen_formal;

end architecture synthesis;
