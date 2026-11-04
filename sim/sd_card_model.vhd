-- A model of an SD card in SPI mode, on an image file, for tb_sd and
-- tb_nicemon (#55).
--
-- THEORY OF OPERATION
-- The card takes MOSI on the rising edge of its clock, while chip select
-- is low, and changes MISO after the falling edge: it shows 'X' at once,
-- and the next bit G_TOD later, so that a controller that samples MISO at
-- the wrong time reads 'X'. MISO is '1' while chip select is high, as the
-- pull-up holds it.
--
-- The answers wait in a queue of bytes, which go out one per byte that the
-- host clocks; the card sends 0xFF when the queue is empty. Each command
-- is answered after one byte, NCR. The card knows CMD0, CMD8, CMD9, CMD16,
-- CMD17, CMD24, CMD55, CMD58, CMD59, and ACMD41, and answers any other
-- command with "illegal command". It checks the CRC7 of every command,
-- and the CRC16 of every block written, as a card does after CMD59 turns
-- the CRCs on, and answers a bad one with the CRC error bit of R1 or the
-- data response for a CRC error. It is idle after CMD0 until the
-- G_IDLE_TRIES-th ACMD41, and, as an SDHC card is, for ever while ACMD41
-- does not set HCS, bit 30 of its argument.
--
-- G_TYPE 2 is an SDHC card, which takes sector numbers, with a CSD of
-- version 2; G_TYPE 1 is an SDSC card, which takes byte addresses, with
-- a CSD of version 1 and READ_BL_LEN 10, and G_V1 makes it a card of
-- version 1, to which CMD8 is illegal. The card has G_SECTORS sectors. The
-- image file fills the first ones, and the rest read 0 until they are
-- written; writes change the image in memory only.
--
-- The ports for the tests: crc_err_i corrupts the CRC16 of the blocks the
-- card sends while it is high, and dead_i makes the card answer nothing.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) G_SECTORS is a multiple of 1024. The image file, if any, is a
--    multiple of 512 bytes long, and not longer than the card.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity sd_card_model is
   generic (
      G_FILE       : string   := "";
      G_SECTORS    : positive := 1024;
      G_TYPE       : natural range 1 to 2 := 2;
      G_V1         : boolean  := false;
      G_IDLE_TRIES : positive := 3;
      G_TOD        : time     := 14 ns;
      G_BUSY_BYTES : natural  := 4
   );
   port (
      sclk_i    : in  std_logic;
      mosi_i    : in  std_logic;
      cs_n_i    : in  std_logic;
      miso_o    : out std_logic := '1';
      crc_err_i : in  std_logic := '0';
      dead_i    : in  std_logic := '0'
   );
end entity sd_card_model;

architecture simulation of sd_card_model is

   type t_bytes is array (natural range <>) of natural range 0 to 255;
   type t_image is access t_bytes;

   -- The CRC7 of a command, and the CRC16 of a block, after one more byte
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

   -- The CSD register of the card
   function csd return std_logic_vector is
      variable c_v    : std_logic_vector(127 downto 0) := (others => '0');
      variable size_v : natural;
   begin
      if G_TYPE = 2 then
         c_v(127 downto 126) := "01";
         c_v(83 downto 80)   := X"9";
         c_v(69 downto 48)   := to_slv(G_SECTORS / 1024 - 1, 22);
      else
         -- (C_SIZE + 1) * 2^(C_SIZE_MULT + 2) * 2^10 / 512 sectors
         c_v(127 downto 126) := "00";
         c_v(83 downto 80)   := X"A";
         for mult in 0 to 7 loop
            size_v := G_SECTORS / 2 ** (mult + 3);
            if size_v <= 4096 then
               c_v(73 downto 62) := to_slv(size_v - 1, 12);
               c_v(49 downto 47) := to_slv(mult, 3);
               exit;
            end if;
         end loop;
      end if;
      c_v(0) := '1';
      return c_v;
   end function csd;

   impure function load return t_image is
      type t_char_file is file of character;

      file     f        : t_char_file;
      variable status_v : file_open_status;
      variable c_v      : character;
      variable n_v      : natural := 0;
      variable image_v  : t_image;
   begin
      image_v := new t_bytes'(0 to G_SECTORS * 512 - 1 => 0);
      if G_FILE /= "" then
         file_open(status_v, f, G_FILE, read_mode);
         assert status_v = open_ok
            report "sd_card_model: cannot read " & G_FILE
            severity failure;
         while not endfile(f) loop
            read(f, c_v);
            image_v(n_v) := character'pos(c_v);
            n_v          := n_v + 1;
         end loop;
         file_close(f);
         assert n_v mod 512 = 0
            report "sd_card_model: " & G_FILE & " is not a multiple of 512 bytes"
            severity failure;
      end if;
      return image_v;
   end function load;

begin

   p_card : process
      variable image_v : t_image;

      -- The queue of bytes to send
      variable q_v    : t_bytes(0 to 1023);
      variable head_v : natural := 0;
      variable tail_v : natural := 0;

      -- The byte coming in, and the one going out
      variable rx_v  : std_logic_vector(7 downto 0) := X"FF";
      variable bit_v : natural range 0 to 8 := 0;
      variable tx_v  : std_logic_vector(7 downto 0) := X"FF";

      -- The command coming in
      variable cmd_v : t_bytes(0 to 5);
      variable len_v : natural range 0 to 6 := 0;

      -- The card's state
      variable idle_v  : boolean := true;
      variable app_v   : boolean := false;
      variable tries_v : natural := 0;

      -- A block being written: 0 no, 1 waiting for its token, 2 its data,
      -- and the sector, the bytes, and their CRC
      variable wr_v   : natural range 0 to 2 := 0;
      variable wsec_v : natural;
      variable wbuf_v : t_bytes(0 to 513);
      variable wcnt_v : natural range 0 to 514;

      procedure put(b : natural) is
      begin
         q_v(tail_v) := b;
         tail_v      := (tail_v + 1) mod q_v'length;
      end procedure put;

      impure function r1(bits : natural) return natural is
      begin
         if idle_v then
            return bits + 1;
         end if;
         return bits;
      end function r1;

      -- The sector of the argument of CMD17 or CMD24, or -1 if it is bad
      impure function sector(arg : std_logic_vector(31 downto 0)) return integer is
         variable s_v : natural;
      begin
         if G_TYPE = 2 then
            if to_integer(arg(31 downto 31)) = 1 then
               return -1;
            end if;
            s_v := to_integer(arg(30 downto 0));
         else
            if arg(8 downto 0) /= "000000000" then
               return -1;
            end if;
            s_v := to_integer(arg(31 downto 9));
         end if;
         if s_v >= G_SECTORS then
            return -1;
         end if;
         return s_v;
      end function sector;

      procedure block_out(base : natural; len : natural; csd_v : std_logic_vector) is
         variable crc_v : std_logic_vector(15 downto 0) := (others => '0');
         variable b_v   : std_logic_vector(7 downto 0);
      begin
         put(16#FF#);
         put(16#FE#);
         for i in 0 to len - 1 loop
            if csd_v'length > 0 then
               b_v := csd_v(csd_v'high - 8 * i downto csd_v'high - 8 * i - 7);
            else
               b_v := to_slv(image_v(base + i), 8);
            end if;
            crc_v := crc16(crc_v, b_v);
            put(to_integer(b_v));
         end loop;
         if crc_err_i = '1' then
            crc_v := not crc_v;
         end if;
         put(to_integer(crc_v(15 downto 8)));
         put(to_integer(crc_v(7 downto 0)));
      end procedure block_out;

      procedure command is
         variable idx_v : natural;
         variable arg_v : std_logic_vector(31 downto 0);
         variable crc_v : std_logic_vector(6 downto 0) := (others => '0');
         variable s_v   : integer;
         variable app_c : boolean;
      begin
         idx_v := cmd_v(0) mod 64;
         arg_v := to_slv(cmd_v(1), 8) & to_slv(cmd_v(2), 8) &
                  to_slv(cmd_v(3), 8) & to_slv(cmd_v(4), 8);
         for i in 0 to 4 loop
            crc_v := crc7(crc_v, to_slv(cmd_v(i), 8));
         end loop;
         app_c := app_v;
         app_v := false;
         put(16#FF#);
         if to_slv(cmd_v(5), 8) /= crc_v & '1' then
            put(r1(16#08#));
            return;
         end if;
         case idx_v is
            when 0 =>
               idle_v  := true;
               tries_v := 0;
               put(r1(0));

            when 8 =>
               if G_V1 then
                  put(r1(16#04#));
               else
                  put(r1(0));
                  put(0);
                  put(0);
                  put(to_integer(arg_v(11 downto 8)));
                  put(to_integer(arg_v(7 downto 0)));
               end if;

            when 59 =>
               put(r1(0));

            when 55 =>
               app_v := true;
               put(r1(0));

            when 41 =>
               if not app_c then
                  put(r1(16#04#));
               else
                  tries_v := tries_v + 1;
                  if tries_v >= G_IDLE_TRIES and (G_TYPE = 1 or arg_v(30) = '1') then
                     idle_v := false;
                  end if;
                  put(r1(0));
               end if;

            when 58 =>
               put(r1(0));
               if idle_v then
                  put(16#00#);
               elsif G_TYPE = 2 then
                  put(16#C0#);
               else
                  put(16#80#);
               end if;
               put(16#FF#);
               put(16#80#);
               put(16#00#);

            when 16 =>
               if to_integer(arg_v) = 512 then
                  put(r1(0));
               else
                  put(r1(16#40#));
               end if;

            when 9 =>
               if idle_v then
                  put(r1(16#04#));
               else
                  put(r1(0));
                  block_out(0, 16, csd);
               end if;

            when 17 =>
               s_v := sector(arg_v);
               if idle_v then
                  put(r1(16#04#));
               elsif s_v < 0 then
                  put(r1(16#40#));
               else
                  put(r1(0));
                  block_out(s_v * 512, 512, "");
               end if;

            when 24 =>
               s_v := sector(arg_v);
               if idle_v then
                  put(r1(16#04#));
               elsif s_v < 0 then
                  put(r1(16#40#));
               else
                  put(r1(0));
                  wr_v   := 1;
                  wsec_v := s_v;
               end if;

            when others =>
               put(r1(16#04#));
         end case;
      end procedure command;

      procedure take(b : std_logic_vector(7 downto 0)) is
         variable crc_v : std_logic_vector(15 downto 0) := (others => '0');
      begin
         if wr_v = 1 then
            if b = X"FE" then
               wr_v   := 2;
               wcnt_v := 0;
            end if;
         elsif wr_v = 2 then
            wbuf_v(wcnt_v) := to_integer(b);
            wcnt_v         := wcnt_v + 1;
            if wcnt_v = 514 then
               wr_v := 0;
               for i in 0 to 511 loop
                  crc_v := crc16(crc_v, to_slv(wbuf_v(i), 8));
               end loop;
               if crc_v = to_slv(wbuf_v(512), 8) &
                  to_slv(wbuf_v(513), 8) then
                  for i in 0 to 511 loop
                     image_v(wsec_v * 512 + i) := wbuf_v(i);
                  end loop;
                  put(16#05#);
                  for i in 1 to G_BUSY_BYTES loop
                     put(16#00#);
                  end loop;
               else
                  put(16#0B#);
               end if;
            end if;
         elsif len_v = 0 then
            if b(7 downto 6) = "01" then
               cmd_v(0) := to_integer(b);
               len_v    := 1;
            end if;
         else
            cmd_v(len_v) := to_integer(b);
            len_v        := len_v + 1;
            if len_v = 6 then
               len_v := 0;
               command;
            end if;
         end if;
      end procedure take;

      impure function pop return std_logic_vector is
         variable b_v : natural;
      begin
         if head_v = tail_v or dead_i = '1' then
            return X"FF";
         end if;
         b_v    := q_v(head_v);
         head_v := (head_v + 1) mod q_v'length;
         return to_slv(b_v, 8);
      end function pop;

   begin
      image_v := load;

      loop
         wait on sclk_i, cs_n_i;
         if cs_n_i = '1' then
            bit_v  := 0;
            miso_o <= '1';
         elsif cs_n_i'event then
            -- Selected: the first bit of the next byte
            tx_v   := pop;
            miso_o <= tx_v(7);
         elsif rising_edge(sclk_i) then
            rx_v  := rx_v(6 downto 0) & mosi_i;
            bit_v := bit_v + 1;
            if bit_v = 8 then
               bit_v := 0;
               if dead_i = '0' then
                  take(rx_v);
               end if;
            end if;
         elsif falling_edge(sclk_i) then
            if bit_v = 0 then
               tx_v := pop;
            end if;
            miso_o <= 'X', tx_v(7 - bit_v) after G_TOD;
         end if;
      end loop;
   end process p_card;

end architecture simulation;
