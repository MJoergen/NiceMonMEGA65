-- The receive side of an RMII Ethernet PHY at 100 Mbit/s: the bytes of each
-- frame, without its preamble and start of frame delimiter, and the end of
-- the frame. The frame check sequence is not checked here; it arrives as
-- the last four bytes, for rx_fcs.vhd.
--
-- THEORY OF OPERATION
-- The PHY drives CRS_DV, RXD[1:0], and RX_ER from the 50 MHz reference
-- clock, which is clk_i, and all pass through a register in the IOB first. A di-bit is
-- two bits of a byte, LSB first, so four di-bits make a byte. CRS_DV rises
-- when the PHY sees a carrier, and RXD is then "00" until the preamble's
-- "01" di-bits, which end with the "11" of the start of frame delimiter.
-- The di-bits after that are the frame's, and each byte goes out on data_o
-- with valid_o for a cycle. A "10" in the preamble is a false carrier, and
-- the receiver drops it.
-- When the carrier ends, the PHY may still hold di-bits of the frame. It
-- then clears CRS_DV on the first di-bit of each nibble and sets it on the
-- second, until the last one is out, and CRS_DV stays clear. So CRS_DV is
-- read only on the second di-bit of each nibble: clear there ends the
-- frame, and eof_o is '1' for a cycle, two cycles after the last byte's
-- valid_o. err_o is '1' with eof_o when the frame did not end on a byte,
-- and the partial byte is dropped, or when RX_ER was '1' during the frame,
-- as the PHY sets it for a symbol it could not decode (bad).
-- At 10 Mbit/s the PHY repeats each di-bit ten times; that is not handled.
--
-- RESET
-- Synchronous, to clk_i. Reset drops a frame being received, with no eof_o.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity rmii_rx is
   port (
      clk_i    : in  std_logic; -- 50 MHz, the PHY's reference clock
      rst_i    : in  std_logic;
      -- The PHY's pins
      rxd_i    : in  std_logic_vector(1 downto 0);
      crs_dv_i : in  std_logic;
      rx_er_i  : in  std_logic;
      -- The frame
      data_o   : out std_logic_vector(7 downto 0);
      valid_o  : out std_logic;
      eof_o    : out std_logic;
      err_o    : out std_logic
   );
end entity rmii_rx;

architecture synthesis of rmii_rx is

   -- The IOB registers of the pins
   signal rxd    : std_logic_vector(1 downto 0);
   signal crs_dv : std_logic;
   signal rx_er  : std_logic;

   type   t_state is (IDLE_ST, PREAMBLE_ST, DATA_ST, DROP_ST);
   signal state : t_state                      := IDLE_ST;
   -- The di-bit of the byte, 0 to 3; bit 0 is '1' on a nibble's second
   signal dibit : std_logic_vector(1 downto 0) := "00";
   signal byte  : std_logic_vector(7 downto 0) := (others => '0');
   -- RX_ER came during the frame.
   signal bad   : std_logic                    := '0';

begin

   p_pins : process (clk_i)
   begin
      if rising_edge(clk_i) then
         rxd    <= rxd_i;
         crs_dv <= crs_dv_i;
         rx_er  <= rx_er_i;
      end if;
   end process p_pins;

   p_rx : process (clk_i)
   begin
      if rising_edge(clk_i) then
         valid_o <= '0';
         eof_o   <= '0';
         err_o   <= '0';

         case state is

            when IDLE_ST =>
               if crs_dv = '1' then
                  state <= PREAMBLE_ST;
               end if;

            when PREAMBLE_ST =>
               if crs_dv = '0' then
                  state <= IDLE_ST;
               elsif rxd = "11" then
                  dibit <= "00";
                  bad   <= '0';
                  state <= DATA_ST;
               elsif rxd = "10" then
                  state <= DROP_ST;
               end if;

            when DATA_ST =>
               if dibit(0) = '1' and crs_dv = '0' then
                  -- The carrier is gone, and so are the di-bits. On a byte,
                  -- this is the second di-bit after the last byte.
                  eof_o <= '1';
                  if dibit /= "01" or bad = '1' then
                     err_o <= '1';
                  end if;
                  state <= IDLE_ST;
               else
                  if rx_er = '1' then
                     bad <= '1';
                  end if;
                  byte  <= rxd & byte(7 downto 2);
                  dibit <= dibit + 1;
                  if dibit = "11" then
                     data_o  <= rxd & byte(7 downto 2);
                     valid_o <= '1';
                  end if;
               end if;

            when DROP_ST =>
               if crs_dv = '0' then
                  state <= IDLE_ST;
               end if;

         end case;

         if rst_i = '1' then
            state <= IDLE_ST;
         end if;
      end if;
   end process p_rx;

end architecture synthesis;
