-- The NiceMon system: the NICE core, its memory and I/O, and the command line
-- interpreter (CLI) on the UART. It is the same for every board. The board's
-- top level gives it a clock, a reset, and the UART pins.
--
-- THEORY OF OPERATION
-- The core (nice_cpu/hdl/src/multicycle.vhd) has an instruction bus and a
-- data bus, both pipelined Wishbone. The instruction bus reads port A of the
-- memory. The data bus shares port B with the CLI, which is a second
-- Wishbone master (src/cmd.vhd from cmod-s7). The CLI takes the lines
-- "R <ADDR>" and "W <ADDR> <DATA>", with 8 hex digits for each number, and
-- answers with the word read, or "OK".
--
-- Address map, as in the emulator (nice_cpu/emulator/README.md), and the
-- same for the CLI and the core's data bus apart from the CLI's own
-- registers at the end:
--   0x00000000-0xFFFFFFFF  Memory, where no register below is. It has
--                          2^G_RAM_ADDR_BITS words and repeats through the
--                          address space, so the runtime's stack below
--                          0xFFFFFF00 lands in the top of the memory, and so
--                          do the words of 0xFFFFFF00-FF that are not
--                          registers.
--   0xFFFF0000-0xFFFF07FF  The screen: 2048 words of memory of their own, so
--                          that the emulator's 80x25 screen, the first 2000,
--                          does not land on word 0. Nothing displays it, but
--                          the CLI can read it.
--   0xFFFFFF00             The UART, as the console of ISA.md §8.3. A write
--                          sends bits 7..0. It waits while the previous byte
--                          is still waiting to be sent. A read by the core
--                          takes the oldest received byte, and returns it in
--                          bits 7..0 with bit 8 set, or 0 when no byte has
--                          arrived. The core's input waits in a FIFO of
--                          2^G_RX_FIFO_BITS bytes, in block RAM, and a byte
--                          that arrives when it is full is lost. A break on
--                          the UART, a frame of ten 0 bits, ends the input,
--                          as the end of the emulator's input does: once the
--                          FIFO is empty, a read returns 0x200 (bit 9), and
--                          bytes after the break are dropped. A break while
--                          the CLI has the UART is ignored. A read by the
--                          CLI returns 0 and takes nothing.
--   0xFFFFFF01             The read counter of the emulator: a read by the
--                          core returns the number of its reads since the
--                          last write, and a write sets that number. A read
--                          by the CLI does not count. It is 0 when the core
--                          starts.
--   0xFFFFFF10-0xFFFFFF1F  The performance counters of ISA.md §8.5
--                          (nice_cpu/hdl/src/perf.vhd).
--   0xFFFFFF20-0xFFFFFF3F  The math unit of ISA.md §8.4
--                          (nice_cpu/hdl/src/mpu.vhd).
--   0xFFFFFFE0-0xFFFFFFEF  For the CLI only: R0-R15 of the core, read only,
--                          so that they can be read after HALT, as the
--                          emulator prints them.
--   0xFFFFFFF0             Control, for the CLI only. Bit 0 holds the core
--                          in reset while it is 1. A read returns bit 0, and
--                          the core's halted flag in bit 1. A write with bit
--                          2 set first clears the memory, the screen
--                          included, to 0, as the emulator's memory is at
--                          the start, with the core held. Its OK comes when
--                          the memory is clear, and then bit 0 takes effect.
--   0xFFFFFFF1             For the CLI only, read only: why the core halted,
--                          as the emulator's "Halted (...)" line says. 0
--                          while it has not halted, 1 for HALT, 2 for a
--                          reserved control word, 3 for INT inside an
--                          interrupt routine, and 4 for RTI outside one.
-- Instruction fetches from 0xFFFFFF00-0xFFFFFFFF read 0 (ISA.md §8.3).
--
-- The core runs when the control bit is 0. While it runs and has not halted,
-- the UART input goes to the core, at 0xFFFFFF00. Otherwise it goes to the
-- CLI. So the CLI loads a program with W commands, starts it with
-- "W FFFFFFF0 00000000", and gets the UART back when the program halts. A
-- command line should end with CR alone: a LF after the CR of the line that
-- starts the core reaches the program. The CLI's output goes out before the
-- core's, so its "OK" comes first. When the core halts, and its last byte
-- has gone, the CLI prints CR LF "HALT" CR LF, so that the host knows that
-- the UART is the CLI's again.
--
-- The core starts as the emulator does: the read counter, the math unit,
-- and the performance counters are reset each time the control bit goes
-- to 0. So, after a halt, the instruction counter holds the number of steps
-- that the emulator prints, as no interrupt is raised.
--
-- The data bus of the core is stalled while a CLI request waits, and while a
-- write to the UART waits. The CLI pulses STB for one cycle and does not
-- wait for STALL, so its request is latched and served in the next free
-- cycle. Every request is acknowledged in the cycle after it is served,
-- except one for the MPU or the performance counters. That one is latched
-- and passed to the device, which may stall it (the MPU does while it
-- computes), and it is acknowledged in the cycle after the device's
-- acknowledge. The data bus is stalled meanwhile.
--
-- RESET
-- Synchronous. After reset the control bit is 1 when G_CPU_RUN_AT_RESET is
-- false, so the core waits for the CLI, and 0 otherwise. Memory is not
-- changed.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;
   use ieee.numeric_std.all;

library work;
   use work.trace_pkg.all;

entity nicemon is
   generic (
      G_CLOCK_HZ         : natural;
      G_UART_BAUDRATE    : natural := 115_200;
      G_RAM_ADDR_BITS    : natural := 16;
      -- The core's input FIFO has 2^G_RX_FIFO_BITS bytes.
      G_RX_FIFO_BITS     : natural := 11;
      G_INIT_FILE        : string  := "";
      G_CPU_RUN_AT_RESET : boolean := false
   );
   port (
      clk_i      : in  std_logic;
      rst_i      : in  std_logic;
      uart_rxd_i : in  std_logic;
      uart_txd_o : out std_logic;
      -- '1' while the core runs and owns the UART input
      running_o  : out std_logic
   );
end entity nicemon;

architecture synthesis of nicemon is

   constant C_BUFFER_LEN : natural := 20;
   -- The received bytes for the core. A power of two, so that the pointers
   -- wrap.
   constant C_RX_FIFO_BITS : natural := G_RX_FIFO_BITS;
   constant C_RX_FIFO_LEN  : natural := 2 ** C_RX_FIFO_BITS;

   constant C_UART_DATA  : std_logic_vector(31 downto 0) := X"FFFFFF00";
   constant C_READ_COUNT : std_logic_vector(31 downto 0) := X"FFFFFF01";
   constant C_CONTROL    : std_logic_vector(31 downto 0) := X"FFFFFFF0";
   constant C_HALT_WHY   : std_logic_vector(31 downto 0) := X"FFFFFFF1";
   -- The core's registers, for the CLI: 0xFFFFFFE0-EF
   constant C_REGS_BASE : std_logic_vector(31 downto 4) := X"FFFFFFE";
   -- The screen: 0xFFFF0000-07FF, of which the emulator's screen is the
   -- first 2000 words
   constant C_SCR_BITS : natural := 11;
   constant C_SCR_BASE : std_logic_vector(31 downto C_SCR_BITS) := X"FFFF" & "00000";

   -- The devices of nice_cpu/hdl/src, by the address bits above their offset
   constant C_PERF_BASE : std_logic_vector(31 downto 4) := X"FFFFFF1";        -- 0xFFFFFF10-1F
   constant C_MPU_BASE  : std_logic_vector(31 downto 5) := X"FFFFFF" & "001"; -- 0xFFFFFF20-3F

   -- Whether an address is an I/O register, not memory, for the core or, with
   -- cli, for the CLI. The words of 0xFFFFFF00-FF that are not registers
   -- are memory, as in the emulator. They land in the top 256 words of the
   -- RAM, which nothing else reaches.
   function is_io(addr : std_logic_vector(31 downto 0); cli : boolean) return boolean is
   begin
      if and(addr(31 downto 8)) = '0' then
         return false;
      end if;
      return addr(7 downto 1) = "0000000" or                        -- console, read counter
             addr(7 downto 4) = X"1" or addr(7 downto 5) = "001" or -- perf, MPU
             (cli and (addr(7 downto 4) = X"E" or addr(7 downto 1) = "1111000"));
   end function is_io;

   -- Core
   signal cpu_rst     : std_logic;
   signal cpu_hold    : std_logic;
   signal cpu_halted  : std_logic;
   signal cpu_instret : std_logic;
   signal cpu_retire  : t_retire;
   -- The hold bit in the cycle before, for a pulse when the core starts,
   -- which resets the math unit and the performance counters
   signal cpu_hold_d : std_logic := '1';
   signal dev_rst    : std_logic;
   -- A halt waits in halt_wait until the core's last byte has gone, and
   -- then halt_note tells the CLI.
   signal cpu_halted_d : std_logic := '0';
   signal halt_wait    : std_logic := '0';
   signal halt_note    : std_logic := '0';

   -- Clearing the memory: the address, and the hold bit after it
   signal clearing : std_logic := '0';
   signal clr_addr : std_logic_vector(G_RAM_ADDR_BITS - 1 downto 0);
   signal clr_hold : std_logic;

   -- The number of the core's data reads of 0xFFFFFF01 since it was written
   signal read_count : std_logic_vector(31 downto 0) := (others => '0');

   signal ibus_cyc  : std_logic;
   signal ibus_stb  : std_logic;
   signal ibus_ack  : std_logic := '0';
   signal ibus_addr : std_logic_vector(31 downto 0);
   signal ibus_data : std_logic_vector(31 downto 0);
   signal ibus_io   : std_logic := '0';
   signal ibus_scr  : std_logic := '0';

   signal dbus_cyc   : std_logic;
   signal dbus_stb   : std_logic;
   signal dbus_stall : std_logic;
   signal dbus_ack   : std_logic := '0';
   signal dbus_we    : std_logic;
   signal dbus_addr  : std_logic_vector(31 downto 0);
   signal dbus_wdata : std_logic_vector(31 downto 0);
   signal dbus_rdata : std_logic_vector(31 downto 0);

   -- CLI
   signal cli_addr  : std_logic_vector(31 downto 0);
   signal cli_wdata : std_logic_vector(31 downto 0);
   signal cli_we    : std_logic;
   signal cli_cyc   : std_logic;
   signal cli_stb   : std_logic;
   signal cli_ack   : std_logic := '0';

   -- The CLI request, latched until it is served
   signal cli_pend    : std_logic := '0';
   signal cli_p_addr  : std_logic_vector(31 downto 0);
   signal cli_p_wdata : std_logic_vector(31 downto 0);
   signal cli_p_we    : std_logic;

   -- A core write to the UART that waits for the byte before it to go
   signal tx_wait      : std_logic := '0';
   signal tx_wait_data : std_logic_vector(7 downto 0);

   -- A request for the MPU or the performance counters. It is latched, and
   -- the device's port is driven from the latch until the device acknowledges.
   signal dev_busy  : std_logic := '0';
   signal dev_stb   : std_logic := '0';
   signal dev_mpu   : std_logic;           -- '1' for the MPU, '0' for perf
   signal dev_cli   : boolean;             -- the request is the CLI's
   signal dev_drop  : std_logic;           -- the core was reset meanwhile
   signal dev_addr  : std_logic_vector(4 downto 0);
   signal dev_we    : std_logic;
   signal dev_wdata : std_logic_vector(31 downto 0);
   signal dev_stall : std_logic;

   signal mpu_cyc    : std_logic;
   signal mpu_stb    : std_logic;
   signal mpu_stall  : std_logic;
   signal mpu_ack    : std_logic;
   signal mpu_data   : std_logic_vector(31 downto 0);
   signal perf_cyc   : std_logic;
   signal perf_stb   : std_logic;
   signal perf_stall : std_logic;
   signal perf_ack   : std_logic;
   signal perf_data  : std_logic_vector(31 downto 0);

   -- Memory port B, and the source of the read data of the last request
   signal ram_a_addr  : std_logic_vector(G_RAM_ADDR_BITS - 1 downto 0);
   signal ram_a_data  : std_logic_vector(31 downto 0);
   signal ram_b_addr  : std_logic_vector(G_RAM_ADDR_BITS - 1 downto 0);
   signal ram_b_we    : std_logic;
   signal ram_b_wdata : std_logic_vector(31 downto 0);
   signal ram_b_rdata : std_logic_vector(31 downto 0);
   signal rd_ram      : std_logic := '0';
   signal rd_scr      : std_logic := '0';
   signal rd_rx       : std_logic := '0';

   -- The screen memory, like the main memory
   signal scr_a_data  : std_logic_vector(31 downto 0);
   signal scr_b_addr  : std_logic_vector(C_SCR_BITS - 1 downto 0);
   signal scr_b_we    : std_logic;
   signal scr_b_rdata : std_logic_vector(31 downto 0);
   signal rd_io       : std_logic_vector(31 downto 0);

   -- UART
   signal uart_owner_cpu : std_logic;

   signal ser_rx_valid : std_logic;
   signal ser_rx_ready : std_logic;
   signal ser_rx_data  : std_logic_vector(7 downto 0);
   signal ser_rx_break : std_logic;
   signal ser_tx_valid : std_logic;
   signal ser_tx_ready : std_logic;
   signal ser_tx_data  : std_logic_vector(7 downto 0);

   signal lb_rx_valid : std_logic;
   signal lb_rx_ready : std_logic;
   signal lb_tx_valid : std_logic;
   signal lb_tx_ready : std_logic;
   signal lb_tx_data  : std_logic_vector(7 downto 0);

   signal cpu_tx_valid : std_logic := '0';
   signal cpu_tx_ready : std_logic;
   signal cpu_tx_data  : std_logic_vector(7 downto 0);
   -- The FIFO holds the bytes from rx_rd to rx_wr. Each pointer has one bit
   -- more than an index, so that a full FIFO differs from an empty one. It
   -- is block RAM, read in every cycle at rx_rd into rx_q, so rx_q holds
   -- the oldest byte in the cycle after a read of the console is served.
   -- No byte is written to the word at rx_rd while the FIFO holds a byte:
   -- it is written when the FIFO is empty, and not when it is full.
   type t_rx_fifo is array (0 to C_RX_FIFO_LEN - 1) of std_logic_vector(7 downto 0);

   signal rx_fifo : t_rx_fifo;
   signal rx_we   : std_logic;
   signal rx_q    : std_logic_vector(7 downto 0);
   signal rx_wr   : std_logic_vector(C_RX_FIFO_BITS downto 0) := (others => '0');
   signal rx_rd   : std_logic_vector(C_RX_FIFO_BITS downto 0) := (others => '0');
   -- The core's input has ended with a break.
   signal rx_eof : std_logic := '0';

   signal rx_buffer_ready : std_logic;
   signal rx_buffer_valid : std_logic;
   signal rx_buffer_size  : natural range 0 to C_BUFFER_LEN;
   signal rx_buffer_data  : std_logic_vector(8 * C_BUFFER_LEN - 1 downto 0);
   signal tx_buffer_ready : std_logic;
   signal tx_buffer_valid : std_logic;
   signal tx_buffer_size  : natural range 0 to C_BUFFER_LEN;
   signal tx_buffer_data  : std_logic_vector(8 * C_BUFFER_LEN - 1 downto 0);

begin

   -- The screen is cleared with the low bits of the memory's address.
   assert G_RAM_ADDR_BITS >= C_SCR_BITS
      report "nicemon: the memory must be at least as large as the screen"
      severity failure;

   ---------------------------------------------------------------------------
   -- The core
   ---------------------------------------------------------------------------

   cpu_rst <= rst_i or cpu_hold;

   i_multicycle : entity work.multicycle
      port map (
         clk_i        => clk_i,
         rst_i        => cpu_rst,
         ibus_cyc_o   => ibus_cyc,
         ibus_stb_o   => ibus_stb,
         ibus_stall_i => '0',
         ibus_ack_i   => ibus_ack,
         ibus_addr_o  => ibus_addr,
         ibus_data_i  => ibus_data,
         dbus_cyc_o   => dbus_cyc,
         dbus_stb_o   => dbus_stb,
         dbus_stall_i => dbus_stall,
         dbus_ack_i   => dbus_ack,
         dbus_we_o    => dbus_we,
         dbus_addr_o  => dbus_addr,
         dbus_data_o  => dbus_wdata,
         dbus_data_i  => dbus_rdata,
         nmi_valid_i  => '0',
         nmi_ready_o  => open,
         nmi_vector_i => X"00",
         irq_valid_i  => '0',
         irq_ready_o  => open,
         irq_vector_i => X"00",
         halted_o     => cpu_halted,
         instret_o    => cpu_instret,
         retire_o     => cpu_retire
      ); -- i_multicycle

   uart_owner_cpu <= not cpu_hold and not cpu_halted;
   running_o      <= uart_owner_cpu;


   ---------------------------------------------------------------------------
   -- Instruction bus: memory port A. It never stalls.
   ---------------------------------------------------------------------------

   ram_a_addr <= ibus_addr(G_RAM_ADDR_BITS - 1 downto 0);

   p_ibus : process (clk_i)
   begin
      if rising_edge(clk_i) then
         ibus_ack <= ibus_cyc and ibus_stb;
         ibus_io  <= and(ibus_addr(31 downto 8));
         ibus_scr <= '1' when ibus_addr(31 downto C_SCR_BITS) = C_SCR_BASE else '0';
         if cpu_rst = '1' then
            ibus_ack <= '0';
         end if;
      end if;
   end process p_ibus;

   ibus_data <= (others => '0') when ibus_io = '1' else
                scr_a_data when ibus_scr = '1' else
                ram_a_data;


   ---------------------------------------------------------------------------
   -- Data bus and CLI: memory port B and the I/O registers
   ---------------------------------------------------------------------------

   -- The core's request is taken in a cycle with no stall.
   dbus_stall <= cli_pend or tx_wait or dev_busy or clearing;

   ram_b_addr  <= clr_addr when clearing = '1' else
                  cli_p_addr(G_RAM_ADDR_BITS - 1 downto 0) when cli_pend = '1' else
                  dbus_addr(G_RAM_ADDR_BITS - 1 downto 0);
   ram_b_wdata <= (others => '0') when clearing = '1' else
                  cli_p_wdata when cli_pend = '1' else
                  dbus_wdata;
   scr_b_addr  <= clr_addr(C_SCR_BITS - 1 downto 0) when clearing = '1' else
                  cli_p_addr(C_SCR_BITS - 1 downto 0) when cli_pend = '1' else
                  dbus_addr(C_SCR_BITS - 1 downto 0);

   -- A write to memory is served in the cycle that the CLI's or the core's
   -- request is taken. It goes to the screen or to the main memory. While
   -- the memory is cleared, both are written.
   p_mem_we : process (all)
      variable we_v   : std_logic;
      variable addr_v : std_logic_vector(31 downto 0);
   begin
      we_v   := '0';
      addr_v := dbus_addr;
      if clearing = '1' then
         null;
      elsif dev_busy = '0' and cli_pend = '1' then
         addr_v := cli_p_addr;
         if not is_io(cli_p_addr, true) then
            we_v := cli_p_we;
         end if;
      elsif dev_busy = '0' and tx_wait = '0' and dbus_cyc = '1' and dbus_stb = '1' then
         if not is_io(dbus_addr, false) then
            we_v := dbus_we;
         end if;
      end if;
      if clearing = '1' then
         ram_b_we <= '1';
         scr_b_we <= '1';
      elsif addr_v(31 downto C_SCR_BITS) = C_SCR_BASE then
         ram_b_we <= '0';
         scr_b_we <= we_v;
      else
         ram_b_we <= we_v;
         scr_b_we <= '0';
      end if;
   end process p_mem_we;

   dbus_rdata <= ram_b_rdata when rd_ram = '1' else
                 scr_b_rdata when rd_scr = '1' else
                 X"00000" & "0001" & rx_q when rd_rx = '1' else
                 rd_io;

   cpu_tx_ready <= ser_tx_ready and not lb_tx_valid;

   p_dbus : process (clk_i)

      -- Serve one request. cli is true for the CLI's.
      procedure serve(cli   : boolean;
                      addr  : std_logic_vector(31 downto 0);
                      we    : std_logic;
                      wdata : std_logic_vector(31 downto 0)) is
      begin
         rd_ram <= '0';
         rd_scr <= '0';
         rd_rx  <= '0';
         rd_io  <= (others => '0');
         if not is_io(addr, cli) then
            -- Memory: port B is driven combinationally above.
            if addr(31 downto C_SCR_BITS) = C_SCR_BASE then
               rd_scr <= '1';
            else
               rd_ram <= '1';
            end if;
         elsif addr(31 downto 5) = C_MPU_BASE or addr(31 downto 4) = C_PERF_BASE then
            -- A device: its port is driven from the latch, and the request
            -- is acknowledged when the device acknowledges it.
            dev_busy  <= '1';
            dev_stb   <= '1';
            dev_mpu   <= addr(5);
            dev_cli   <= cli;
            dev_drop  <= '0';
            dev_addr  <= addr(4 downto 0);
            dev_we    <= we;
            dev_wdata <= wdata;
            return;
         elsif addr = C_UART_DATA and we = '1' and not cli then
            if cpu_tx_valid = '1' and cpu_tx_ready = '0' then
               -- The byte before still waits. The core may drop its request
               -- once it is taken, so the byte is kept until it can go.
               tx_wait      <= '1';
               tx_wait_data <= wdata(7 downto 0);
               return;
            end if;
            cpu_tx_data  <= wdata(7 downto 0);
            cpu_tx_valid <= '1';
         elsif addr = C_UART_DATA and we = '1' and cli then
            -- The UART belongs to the CLI then, so the byte is dropped.
            null;
         elsif addr = C_UART_DATA and we = '0' and not cli then
            if rx_rd /= rx_wr then
               -- The byte comes from rx_q in the next cycle.
               rd_rx <= '1';
               rx_rd <= rx_rd + 1;
            elsif rx_eof = '1' then
               rd_io(9) <= '1';
            end if;
         elsif addr = C_READ_COUNT then
            -- As in the emulator: a write sets the count, and a read by the
            -- core returns it and counts. A read by the CLI only returns it,
            -- as the emulator's --dump does.
            if we = '1' then
               read_count <= wdata;
            else
               rd_io <= read_count;
               if not cli then
                  read_count <= read_count + 1;
               end if;
            end if;
         elsif addr(31 downto 4) = C_REGS_BASE and cli then
            if we = '0' then
               rd_io <= cpu_retire.regs(to_integer(addr(3 downto 0)));
            end if;
         elsif addr = C_CONTROL and cli then
            if we = '1' and wdata(2) = '1' then
               -- Clear the memory with the core held. The request is
               -- acknowledged when the memory is clear.
               clearing <= '1';
               clr_addr <= (others => '0');
               clr_hold <= wdata(0);
               cpu_hold <= '1';
               return;
            elsif we = '1' then
               cpu_hold <= wdata(0);
            else
               rd_io(0) <= cpu_hold;
               rd_io(1) <= cpu_halted;
            end if;
         elsif addr = C_HALT_WHY and cli then
            -- The core keeps the reason until it is reset.
            if we = '0' then
               rd_io(2 downto 0) <= std_logic_vector(to_unsigned(t_halt'pos(cpu_retire.halt), 3));
            end if;
         end if;
         if cli then
            cli_ack <= '1';
         else
            dbus_ack <= '1';
         end if;
      end procedure serve;

   begin
      if rising_edge(clk_i) then
         dbus_ack     <= '0';
         cli_ack      <= '0';
         halt_note    <= '0';
         cpu_hold_d   <= cpu_hold;
         cpu_halted_d <= cpu_halted;

         if cpu_tx_valid = '1' and cpu_tx_ready = '1' then
            cpu_tx_valid <= '0';
         end if;

         -- The CLI is told of a halt once the core's last byte has gone to
         -- the UART.
         if cpu_halted = '1' and cpu_halted_d = '0' then
            halt_wait <= '1';
         end if;
         if halt_wait = '1' and tx_wait = '0' and
            (cpu_tx_valid = '0' or cpu_tx_ready = '1') then
            halt_wait <= '0';
            halt_note <= '1';
         end if;

         if dev_busy = '1' then
            if dev_stb = '1' and dev_stall = '0' then
               dev_stb <= '0';
            end if;
            if mpu_ack = '1' or perf_ack = '1' then
               rd_ram   <= '0';
               rd_scr   <= '0';
               rd_rx    <= '0';
               if mpu_ack = '1' then
                  rd_io <= mpu_data;
               else
                  rd_io <= perf_data;
               end if;
               dev_busy <= '0';
               if dev_cli then
                  cli_ack <= '1';
               elsif dev_drop = '0' then
                  dbus_ack <= '1';
               end if;
            end if;
         elsif clearing = '1' then
            clr_addr <= clr_addr + 1;
            if and(clr_addr) = '1' then
               clearing <= '0';
               cpu_hold <= clr_hold;
               cli_ack  <= '1';
            end if;
         elsif cli_pend = '1' then
            serve(true, cli_p_addr, cli_p_we, cli_p_wdata);
            cli_pend <= '0';
         elsif tx_wait = '1' then
            if cpu_tx_valid = '0' or cpu_tx_ready = '1' then
               cpu_tx_data  <= tx_wait_data;
               cpu_tx_valid <= '1';
               tx_wait      <= '0';
               dbus_ack     <= '1';
            end if;
         elsif dbus_cyc = '1' and dbus_stb = '1' then
            serve(false, dbus_addr, dbus_we, dbus_wdata);
         end if;

         if rx_we = '1' then
            rx_wr <= rx_wr + 1;
         end if;
         if ser_rx_break = '1' and uart_owner_cpu = '1' then
            rx_eof <= '1';
         end if;

         if cli_cyc = '1' and cli_stb = '1' then
            cli_pend    <= '1';
            cli_p_addr  <= cli_addr;
            cli_p_wdata <= cli_wdata;
            cli_p_we    <= cli_we;
         end if;

         -- A request of the core in reset is dropped, and so is a byte
         -- received before, so that a program starts with no input.
         if cpu_rst = '1' then
            dbus_ack     <= '0';
            tx_wait      <= '0';
            halt_wait    <= '0';
            read_count   <= (others => '0');
            rx_wr        <= (others => '0');
            rx_rd        <= (others => '0');
            rx_eof       <= '0';
            if not dev_cli then
               dev_drop <= '1';
            end if;
         end if;

         if rst_i = '1' then
            dev_busy     <= '0';
            dev_stb      <= '0';
            cli_pend     <= '0';
            clearing     <= '0';
            cpu_tx_valid <= '0';
            if G_CPU_RUN_AT_RESET then
               cpu_hold <= '0';
            else
               cpu_hold <= '1';
            end if;
         end if;
      end if;
   end process p_dbus;

   -- A byte for the core goes into its FIFO, unless the FIFO is full or the
   -- input has ended.
   rx_we <= '1' when ser_rx_valid = '1' and uart_owner_cpu = '1' and rx_eof = '0' and
                     rx_wr - rx_rd /= C_RX_FIFO_LEN else
            '0';

   p_rx_fifo : process (clk_i)
   begin
      if rising_edge(clk_i) then
         if rx_we = '1' then
            rx_fifo(to_integer(rx_wr(C_RX_FIFO_BITS - 1 downto 0))) <= ser_rx_data;
         end if;
         rx_q <= rx_fifo(to_integer(rx_rd(C_RX_FIFO_BITS - 1 downto 0)));
      end if;
   end process p_rx_fifo;


   ---------------------------------------------------------------------------
   -- The math unit (ISA.md §8.4) and the performance counters (§8.5) from
   -- nice_cpu. They are reset with the system, and when the core starts, as
   -- the emulator's are when it starts. They are not reset while the CLI
   -- holds the core, so that the CLI can read them after a halt.
   ---------------------------------------------------------------------------

   dev_rst <= rst_i or (cpu_hold_d and not cpu_hold);

   mpu_cyc   <= dev_busy and dev_mpu;
   mpu_stb   <= dev_stb and dev_mpu;
   perf_cyc  <= dev_busy and not dev_mpu;
   perf_stb  <= dev_stb and not dev_mpu;
   dev_stall <= mpu_stall when dev_mpu = '1' else perf_stall;

   i_mpu : entity work.mpu
      port map (
         clk_i      => clk_i,
         rst_i      => dev_rst,
         wb_cyc_i   => mpu_cyc,
         wb_stb_i   => mpu_stb,
         wb_stall_o => mpu_stall,
         wb_ack_o   => mpu_ack,
         wb_we_i    => dev_we,
         wb_addr_i  => dev_addr,
         wb_data_i  => dev_wdata,
         wb_data_o  => mpu_data
      ); -- i_mpu

   i_perf : entity work.perf
      port map (
         clk_i      => clk_i,
         rst_i      => dev_rst,
         instret_i  => cpu_instret,
         wb_cyc_i   => perf_cyc,
         wb_stb_i   => perf_stb,
         wb_stall_o => perf_stall,
         wb_ack_o   => perf_ack,
         wb_we_i    => dev_we,
         wb_addr_i  => dev_addr(3 downto 0),
         wb_data_i  => dev_wdata,
         wb_data_o  => perf_data
      ); -- i_perf

   i_ram : entity work.ram
      generic map (
         G_ADDR_BITS => G_RAM_ADDR_BITS,
         G_INIT_FILE => G_INIT_FILE
      )
      port map (
         clk_i     => clk_i,
         a_addr_i  => ram_a_addr,
         a_data_o  => ram_a_data,
         b_addr_i  => ram_b_addr,
         b_we_i    => ram_b_we,
         b_wdata_i => ram_b_wdata,
         b_rdata_o => ram_b_rdata
      ); -- i_ram

   -- The screen, at 0xFFFF0000. It is memory, as in the emulator, so the CLI
   -- can read what a program wrote there. Without it the address would
   -- land at word 0 of the main memory.
   i_scr : entity work.ram
      generic map (
         G_ADDR_BITS => C_SCR_BITS
      )
      port map (
         clk_i     => clk_i,
         a_addr_i  => ibus_addr(C_SCR_BITS - 1 downto 0),
         a_data_o  => scr_a_data,
         b_addr_i  => scr_b_addr,
         b_we_i    => scr_b_we,
         b_wdata_i => ram_b_wdata,
         b_rdata_o => scr_b_rdata
      ); -- i_scr


   ---------------------------------------------------------------------------
   -- UART: the CLI's line buffer has the output first. The input goes to the
   -- core while it runs, and to the CLI otherwise.
   ---------------------------------------------------------------------------

   i_uart_serdes : entity work.uart_serdes
      generic map (
         G_DIVISOR => G_CLOCK_HZ / G_UART_BAUDRATE
      )
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         tx_valid_i => ser_tx_valid,
         tx_ready_o => ser_tx_ready,
         tx_data_i  => ser_tx_data,
         rx_valid_o => ser_rx_valid,
         rx_ready_i => ser_rx_ready,
         rx_data_o  => ser_rx_data,
         rx_break_o => ser_rx_break,
         uart_tx_o  => uart_txd_o,
         uart_rx_i  => uart_rxd_i
      ); -- i_uart_serdes

   ser_tx_valid <= lb_tx_valid or cpu_tx_valid;
   ser_tx_data  <= lb_tx_data when lb_tx_valid = '1' else cpu_tx_data;
   lb_tx_ready  <= ser_tx_ready;

   lb_rx_valid  <= ser_rx_valid and not uart_owner_cpu;
   ser_rx_ready <= '1' when uart_owner_cpu = '1' else lb_rx_ready;

   i_line_buffer : entity work.line_buffer
      generic map (
         G_BUFFER_LEN => C_BUFFER_LEN
      )
      port map (
         clk_i             => clk_i,
         rst_i             => rst_i,
         rx_ready_o        => lb_rx_ready,
         rx_valid_i        => lb_rx_valid,
         rx_data_i         => ser_rx_data,
         tx_ready_i        => lb_tx_ready,
         tx_valid_o        => lb_tx_valid,
         tx_data_o         => lb_tx_data,
         rx_buffer_ready_i => rx_buffer_ready,
         rx_buffer_valid_o => rx_buffer_valid,
         rx_buffer_size_o  => rx_buffer_size,
         rx_buffer_data_o  => rx_buffer_data,
         tx_buffer_ready_o => tx_buffer_ready,
         tx_buffer_valid_i => tx_buffer_valid,
         tx_buffer_size_i  => tx_buffer_size,
         tx_buffer_data_i  => tx_buffer_data
      ); -- i_line_buffer

   i_cmd : entity work.cmd
      generic map (
         G_ADDR_SIZE  => 32,
         G_BUFFER_LEN => C_BUFFER_LEN
      )
      port map (
         clk_i             => clk_i,
         rst_i             => rst_i,
         rx_buffer_ready_o => rx_buffer_ready,
         rx_buffer_valid_i => rx_buffer_valid,
         rx_buffer_size_i  => rx_buffer_size,
         rx_buffer_data_i  => rx_buffer_data,
         tx_buffer_ready_i => tx_buffer_ready,
         tx_buffer_valid_o => tx_buffer_valid,
         tx_buffer_size_o  => tx_buffer_size,
         tx_buffer_data_o  => tx_buffer_data,
         halt_i            => halt_note,
         wbus_addr_o       => cli_addr,
         wbus_wrdat_o      => cli_wdata,
         wbus_we_o         => cli_we,
         wbus_cyc_o        => cli_cyc,
         wbus_stb_o        => cli_stb,
         wbus_rddat_i      => dbus_rdata,
         wbus_ack_i        => cli_ack
      ); -- i_cmd

end architecture synthesis;
