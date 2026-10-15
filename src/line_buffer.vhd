-- Copied unchanged from https://github.com/MJoergen/cmod-s7 (src/line_buffer.vhd, commit d3d544d), MIT License.
--
-- ----------------------------------------------------------------------------
-- Description: Serial to Parallel and back.
-- ----------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity line_buffer is
  generic (
    G_BUFFER_LEN : natural
  );
  port (
    clk_i             : in    std_logic;
    rst_i             : in    std_logic;

    -- Serial interface
    rx_ready_o        : out   std_logic;
    rx_valid_i        : in    std_logic;
    rx_data_i         : in    std_logic_vector(7 downto 0);
    tx_ready_i        : in    std_logic;
    tx_valid_o        : out   std_logic;
    tx_data_o         : out   std_logic_vector(7 downto 0);

    -- Buffer interface
    rx_buffer_ready_i : in    std_logic;
    rx_buffer_valid_o : out   std_logic;
    rx_buffer_size_o  : out   natural range 0 to G_BUFFER_LEN;
    rx_buffer_data_o  : out   std_logic_vector(8 * G_BUFFER_LEN - 1 downto 0);
    tx_buffer_ready_o : out   std_logic;
    tx_buffer_valid_i : in    std_logic;
    tx_buffer_size_i  : in    natural range 0 to G_BUFFER_LEN;
    tx_buffer_data_i  : in    std_logic_vector(8 * G_BUFFER_LEN - 1 downto 0)
  );
end entity line_buffer;

architecture synthesis of line_buffer is

  constant C_CR : std_logic_vector(7 downto 0) := X"0D";
  constant C_LF : std_logic_vector(7 downto 0) := X"0A";

  type     rx_state_type is (RECEIVING_ST, PROCESSING_ST);
  signal   rx_state : rx_state_type            := RECEIVING_ST;

  type     tx_state_type is (IDLE_ST, SENDING_ST);
  signal   tx_state : tx_state_type            := IDLE_ST;

  signal   tx_buffer_size : natural range 0 to G_BUFFER_LEN;
  signal   tx_buffer_data : std_logic_vector(8 * G_BUFFER_LEN - 1 downto 0);

begin

  rx_ready_o        <= '1' when rx_state = RECEIVING_ST else
                       '0';

  rx_proc : process (clk_i)
  begin
    if rising_edge(clk_i) then

      case rx_state is

        when RECEIVING_ST =>
          if rx_valid_i = '1' then
            if rx_data_i = C_CR or rx_data_i = C_LF then
              if rx_buffer_size_o /= 0 then
                rx_buffer_valid_o <= '1';
                rx_state          <= PROCESSING_ST;
              end if;
            else
              rx_buffer_data_o <= rx_buffer_data_o(8 * G_BUFFER_LEN - 9 downto 0) & rx_data_i;
              rx_buffer_size_o <= rx_buffer_size_o + 1;
              if rx_buffer_size_o = G_BUFFER_LEN - 1 then
                rx_buffer_valid_o <= '1';
                rx_state          <= PROCESSING_ST;
              end if;
            end if;
          end if;

        when PROCESSING_ST =>
          if rx_buffer_ready_i = '1' then
            rx_buffer_valid_o <= '0';
            rx_buffer_size_o  <= 0;
            --            rx_buffer_data_o  <= (others => '0');
            rx_state          <= RECEIVING_ST;
          end if;

      end case;

      if rst_i = '1' then
        rx_buffer_valid_o <= '0';
        rx_buffer_size_o  <= 0;
        --        rx_buffer_data_o  <= (others => '0');
        rx_state          <= RECEIVING_ST;
      end if;
    end if;
  end process rx_proc;


  tx_buffer_ready_o <= '1' when tx_state = IDLE_ST else
                       '0';

  tx_proc : process (clk_i)
  begin
    if rising_edge(clk_i) then
      if tx_ready_i = '1' then
        tx_valid_o <= '0';
      end if;

      case tx_state is

        when IDLE_ST =>
          if tx_buffer_valid_i = '1' then
            if tx_buffer_size_i /= 0 then
              tx_buffer_size <= tx_buffer_size_i - 1;
              tx_buffer_data <= tx_buffer_data_i;
              tx_data_o      <= tx_buffer_data_i((tx_buffer_size_i - 1) * 8 + 7 downto (tx_buffer_size_i - 1) * 8);
              tx_valid_o     <= '1';
              tx_state       <= SENDING_ST;
            end if;
          end if;

        when SENDING_ST =>
          if tx_ready_i = '1' then
            if tx_buffer_size /= 0 then
              tx_data_o      <= tx_buffer_data((tx_buffer_size - 1) * 8 + 7 downto (tx_buffer_size - 1) * 8);
              tx_valid_o     <= '1';
              tx_buffer_size <= tx_buffer_size - 1;
            else
              tx_state <= IDLE_ST;
            end if;
          end if;

      end case;

      if rst_i = '1' then
        tx_state   <= IDLE_ST;
        tx_valid_o <= '0';
      end if;
    end if;
  end process tx_proc;

end architecture synthesis;

