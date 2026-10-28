-- The RMII transmitter of the Ethernet PHY: it sends the frames of
-- eth_tx_fifo.vhd on TXD and TX_EN, with the preamble, the start frame
-- delimiter, the padding to the shortest frame, the frame check sequence,
-- and the gap between frames, all added here.
--
-- THEORY OF OPERATION
-- RMII at 100 Mbit/s sends a di-bit in each cycle of the 50 MHz reference
-- clock, so a byte takes four cycles, LSB first, as rmii_rx.vhd receives
-- them. dibit counts the four, and on the last, "11", the byte after is
-- chosen and loaded into the shift register sh, with en '1' when it is to
-- be sent. txd_o and tx_en_o are registers in front of the pins, so they
-- have sh(1 downto 0) and en a cycle later, and the PHY takes them on the
-- next rising edge of its clock.
-- When a frame's first byte is on valid_i, the frame begins: seven bytes of
-- 0x55 and the start frame delimiter 0xD5, then the frame's bytes, each
-- taken with ready_o in the cycle it is loaded. If the frame ends, with
-- last_i, before C_MIN_LEN bytes, zeros pad it to C_MIN_LEN. The CRC
-- (eth_pkg.vhd) takes each byte of the frame and its padding, and its
-- complement follows, LSB first, as the frame check sequence. Then TX_EN is
-- '0' for C_GAP bytes, the gap between frames, before the next can begin.
-- A frame of n bytes, padded, is on the wire for 8 + n + 4 + 12 bytes.
--
-- INTERFACE CONTRACTS -- these are requirements on the environment:
-- a) Once a frame's first byte has come, each of its bytes is on valid_i,
--    data_i, and last_i when ready_o is '1'. eth_tx_fifo.vhd gives a frame
--    only when it is whole, and a byte in two cycles, which a byte in four
--    cycles leaves time for.
--
-- RESET
-- Synchronous, to clk_i. Reset ends a frame at once, with TX_EN at '0' a
-- cycle later; the registers of the pins have no reset, so that nothing
-- comes between them and the pins.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

library work;
   use work.eth_pkg.all;

entity rmii_tx is
   port (
      clk_i   : in  std_logic;
      rst_i   : in  std_logic;
      -- The frames, from eth_tx_fifo.vhd
      data_i  : in  std_logic_vector(7 downto 0);
      last_i  : in  std_logic;
      valid_i : in  std_logic;
      ready_o : out std_logic;
      -- The PHY's pins, each a register
      txd_o   : out std_logic_vector(1 downto 0) := "00";
      tx_en_o : out std_logic                    := '0'
   );
end entity rmii_tx;

architecture synthesis of rmii_tx is

   -- The shortest frame, without its check sequence, and the gap
   constant C_MIN_LEN : natural := 60;
   constant C_GAP     : natural := 12;

   type t_state is (IDLE_ST, PREAMBLE_ST, DATA_ST, PAD_ST, FCS_ST, GAP_ST);
   -- What the next byte loaded is
   signal state : t_state                       := IDLE_ST;
   -- The di-bit of the byte, 0 to 3
   signal dibit : std_logic_vector(1 downto 0)  := "00";
   signal sh    : std_logic_vector(7 downto 0)  := (others => '0');
   signal en    : std_logic                     := '0';
   signal crc   : std_logic_vector(31 downto 0) := C_CRC_INIT;
   -- The bytes of the preamble, of the frame up to C_MIN_LEN, of the check
   -- sequence, or of the gap, as state has it
   signal cnt : natural range 0 to C_MIN_LEN  := 0;

begin

   ready_o <= '1' when state = DATA_ST and dibit = "11" else
              '0';

   p_tx : process (clk_i)
   begin
      if rising_edge(clk_i) then
         txd_o   <= sh(1 downto 0);
         tx_en_o <= en;
         sh      <= "00" & sh(7 downto 2);
         dibit   <= dibit + 1;

         if dibit = "11" then

            case state is

               when IDLE_ST =>
                  en <= '0';
                  if valid_i = '1' then
                     sh    <= X"55";
                     en    <= '1';
                     cnt   <= 1;
                     state <= PREAMBLE_ST;
                  end if;

               when PREAMBLE_ST =>
                  if cnt = 7 then
                     sh    <= X"D5";
                     cnt   <= 0;
                     crc   <= C_CRC_INIT;
                     state <= DATA_ST;
                  else
                     sh  <= X"55";
                     cnt <= cnt + 1;
                  end if;

               when DATA_ST =>
                  sh  <= data_i;
                  crc <= crc_byte(crc, data_i);
                  if cnt < C_MIN_LEN then
                     cnt <= cnt + 1;
                  end if;
                  if last_i = '1' then
                     if cnt + 1 < C_MIN_LEN then
                        state <= PAD_ST;
                     else
                        cnt   <= 0;
                        state <= FCS_ST;
                     end if;
                  end if;

               when PAD_ST =>
                  sh  <= X"00";
                  crc <= crc_byte(crc, X"00");
                  cnt <= cnt + 1;
                  if cnt + 1 = C_MIN_LEN then
                     cnt   <= 0;
                     state <= FCS_ST;
                  end if;

               when FCS_ST =>
                  sh  <= not crc(7 downto 0);
                  crc <= X"00" & crc(31 downto 8);
                  cnt <= cnt + 1;
                  if cnt = 3 then
                     cnt   <= 0;
                     state <= GAP_ST;
                  end if;

               when GAP_ST =>
                  en  <= '0';
                  cnt <= cnt + 1;
                  if cnt = C_GAP - 1 then
                     cnt   <= 0;
                     state <= IDLE_ST;
                  end if;

            end case;

         end if;

         if rst_i = '1' then
            state   <= IDLE_ST;
            dibit   <= "00";
            sh      <= (others => '0');
            en      <= '0';
            cnt     <= 0;
         end if;
      end if;
   end process p_tx;

end architecture synthesis;
