-- Copied from https://github.com/MJoergen/cmod-s7 (src/cmd.vhd, commit d3d544d), MIT License.
-- Changed: the banner is "NICE", not "WBUS". A pulse on halt_i prints
-- CR LF "HALT" CR LF, before the next command is taken. The commands may be
-- lower case. The layout and names follow CODING_STYLE.md.
--
-- ----------------------------------------------------------------------------
-- Description: Simple command line interpreter
-- Commands available:
-- W <ADDR> <DATA>
-- R <ADDR>
-- Both <ADDR> and <DATA> must be 32-bit numbers written in hex (i.e. 8 characters).
-- The command letter and the hex digits may be upper or lower case.
--
-- The output is a Wishbone Master interface 32-bit (Revision B.4)
-- https://cdn.opencores.org/downloads/wbspec_b4.pdf
-- ----------------------------------------------------------------------------

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std.all;

entity cmd is
   generic (
      G_ADDR_SIZE  : natural;
      G_BUFFER_LEN : natural
   );
   port (
      clk_i             : in  std_logic;
      rst_i             : in  std_logic;

      -- Line buffer
      rx_buffer_ready_o : out std_logic;
      rx_buffer_valid_i : in  std_logic;
      rx_buffer_size_i  : in  natural range 0 to G_BUFFER_LEN;
      rx_buffer_data_i  : in  std_logic_vector(8 * G_BUFFER_LEN - 1 downto 0);
      tx_buffer_ready_i : in  std_logic;
      tx_buffer_valid_o : out std_logic;
      tx_buffer_size_o  : out natural range 0 to G_BUFFER_LEN;
      tx_buffer_data_o  : out std_logic_vector(8 * G_BUFFER_LEN - 1 downto 0);

      -- A pulse prints the halt message
      halt_i            : in  std_logic;

      -- Wishbone bus Master interface
      wbus_addr_o       : out std_logic_vector(G_ADDR_SIZE - 1 downto 0); -- lower address bits
      wbus_wrdat_o      : out std_logic_vector(31 downto 0);              -- Write Databus
      wbus_we_o         : out std_logic;                                  -- Write enable
      wbus_cyc_o        : out std_logic;                                  -- Valid bus cycle
      wbus_stb_o        : out std_logic;                                  -- Strobe signals / core select signal
      wbus_rddat_i      : in  std_logic_vector(31 downto 0);              -- Read Databus
      wbus_ack_i        : in  std_logic                                   -- Bus cycle acknowledge
   );
end entity cmd;

architecture synthesis of cmd is

   -- Convert ASCII string to std_logic_vector
   pure function str2slv(str : string;
                         len : natural) return std_logic_vector is
      variable res_v : std_logic_vector(len * 8 - 1 downto 0) := (others => '0');
   begin
      for i in 0 to str'length - 1 loop
         res_v(8 * i + 7 downto 8 * i) := std_logic_vector(to_unsigned(character'pos(str(str'length - i)), 8));
      end loop;

      return res_v;
   end function str2slv;

   constant C_CRLF : string(1 to 2) := "" & character'val(13) & character'val(10);

   constant C_START_STR  : string                                          := C_CRLF & "NICE" & C_CRLF & C_CRLF;
   constant C_START_DATA : std_logic_vector(8 * G_BUFFER_LEN - 1 downto 0) := str2slv(C_START_STR, G_BUFFER_LEN);
   constant C_START_SIZE : natural                                         := C_START_STR'length;

   constant C_WHAT_STR  : string                                          := "WHAT?" & C_CRLF;
   constant C_WHAT_DATA : std_logic_vector(8 * G_BUFFER_LEN - 1 downto 0) := str2slv(C_WHAT_STR, G_BUFFER_LEN);
   constant C_WHAT_SIZE : natural                                         := C_WHAT_STR'length;

   constant C_OK_STR  : string                                          := "OK" & C_CRLF;
   constant C_OK_DATA : std_logic_vector(8 * G_BUFFER_LEN - 1 downto 0) := str2slv(C_OK_STR, G_BUFFER_LEN);
   constant C_OK_SIZE : natural                                         := C_OK_STR'length;

   constant C_HALT_STR  : string                                          := C_CRLF & "HALT" & C_CRLF;
   constant C_HALT_DATA : std_logic_vector(8 * G_BUFFER_LEN - 1 downto 0) := str2slv(C_HALT_STR, G_BUFFER_LEN);
   constant C_HALT_SIZE : natural                                         := C_HALT_STR'length;

   -- A halt message waits here until the line buffer is free
   signal halt_pend : std_logic := '0';

   type t_state is (START_ST, IDLE_ST, BUSY_ST);

   signal state : t_state := START_ST;

begin

   rx_buffer_ready_o <= '1' when state = IDLE_ST and tx_buffer_valid_o = '0' and halt_pend = '0' else
                        '0';

   p_fsm : process (clk_i)
      pure function asc2slv(arg : std_logic_vector) return std_logic_vector is
         variable hex_v : std_logic_vector(7 downto 0);
         variable ret_v : std_logic_vector(arg'length / 2 - 1 downto 0);
      begin
         for i in 0 to arg'length / 8 - 1 loop
            hex_v := arg(8 * i + 7 + arg'right downto 8 * i + arg'right);

            case hex_v(7 downto 4) is

               when "0011" =>
                  ret_v(4 * i + 3 downto 4 * i) := hex_v(3 downto 0);

               when "0100" | "0110" =>
                  ret_v(4 * i + 3 downto 4 * i) := std_logic_vector(unsigned(hex_v(3 downto 0)) + "1001");

               when others =>
                  null;

            end case;
         end loop;

         return ret_v;
      end function asc2slv;

      pure function slv2asc(arg : std_logic_vector) return std_logic_vector is
         variable hex_v : std_logic_vector(3 downto 0);
         variable ret_v : std_logic_vector(arg'length * 2 - 1 downto 0);
      begin
         for i in 0 to arg'length / 4 - 1 loop
            hex_v := arg(4 * i + 3 downto 4 * i);
            if unsigned(hex_v) < "1010" then
               ret_v(8 * i + 7 downto 8 * i) := std_logic_vector(X"30" + unsigned(hex_v));
            else
               ret_v(8 * i + 7 downto 8 * i) := std_logic_vector(X"41" + unsigned(hex_v) - 10);
            end if;
         end loop;

         return ret_v;
      end function slv2asc;

      -- The command letter and the space after it, with the letter in upper
      -- case, so that "r " is "R " and "w " is "W ".
      pure function cmd2upper(arg : std_logic_vector(15 downto 0)) return std_logic_vector is
      begin
         return arg and X"DFFF";
      end function cmd2upper;

   begin
      if rising_edge(clk_i) then
         wbus_stb_o <= '0';

         if wbus_ack_i = '1' then
            wbus_cyc_o <= '0';
         end if;
         if tx_buffer_ready_i = '1' then
            tx_buffer_valid_o <= '0';
         end if;

         case state is

            when START_ST =>
               tx_buffer_size_o  <= C_START_SIZE;
               tx_buffer_data_o  <= C_START_DATA;
               tx_buffer_valid_o <= '1';
               state             <= IDLE_ST;

            when IDLE_ST =>
               if halt_pend = '1' then
                  if tx_buffer_valid_o = '0' then
                     tx_buffer_size_o  <= C_HALT_SIZE;
                     tx_buffer_data_o  <= C_HALT_DATA;
                     tx_buffer_valid_o <= '1';
                     halt_pend         <= '0';
                  end if;
               elsif rx_buffer_valid_i = '1' and rx_buffer_ready_o = '1' then
                  if cmd2upper(rx_buffer_data_i(8 * 10 - 1 downto 8 * 10 - 16)) = X"5220" and rx_buffer_size_i = 10 then    -- 'R' or 'r'
                     wbus_addr_o <= asc2slv(rx_buffer_data_i(63 downto 0))(G_ADDR_SIZE - 1 downto 0);
                     wbus_cyc_o  <= '1';
                     wbus_stb_o  <= '1';
                     wbus_we_o   <= '0';
                     state       <= BUSY_ST;
                  elsif cmd2upper(rx_buffer_data_i(8 * 19 - 1 downto 8 * 19 - 16)) = X"5720" and rx_buffer_size_i = 19 then -- 'W' or 'w'
                     wbus_addr_o  <= asc2slv(rx_buffer_data_i(8 * 17 - 1 downto 8 * 17 - 64))(G_ADDR_SIZE - 1 downto 0);
                     wbus_wrdat_o <= asc2slv(rx_buffer_data_i(63 downto 0));
                     wbus_cyc_o   <= '1';
                     wbus_stb_o   <= '1';
                     wbus_we_o    <= '1';
                     state        <= BUSY_ST;
                  else
                     report "WHAT?";
                     tx_buffer_size_o  <= C_WHAT_SIZE;
                     tx_buffer_data_o  <= C_WHAT_DATA;
                     tx_buffer_valid_o <= '1';
                  end if;
               end if;

            when BUSY_ST =>
               if wbus_ack_i = '1' then
                  if wbus_we_o = '1' then
                     tx_buffer_size_o  <= C_OK_SIZE;
                     tx_buffer_data_o  <= C_OK_DATA;
                     tx_buffer_valid_o <= '1';
                     state             <= IDLE_ST;
                  else
                     tx_buffer_size_o               <= 10;
                     tx_buffer_data_o(79 downto 16) <= slv2asc(wbus_rddat_i);
                     tx_buffer_data_o(15 downto 0)  <= str2slv(C_CRLF, 2);
                     tx_buffer_valid_o              <= '1';
                     state                          <= IDLE_ST;
                  end if;
               end if;

         end case;

         if halt_i = '1' then
            halt_pend <= '1';
         end if;

         if rst_i = '1' then
            halt_pend         <= '0';
            tx_buffer_valid_o <= '0';
            wbus_cyc_o        <= '0';
            wbus_stb_o        <= '0';
            wbus_we_o         <= '0';
            state             <= START_ST;
         end if;
      end if;
   end process p_fsm;

end architecture synthesis;

