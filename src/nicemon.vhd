-- The NiceMon system: the NICE core, its memory and I/O, and the command line
-- interpreter (CLI) on the UART. It is the same for every board. The board's
-- top level gives it a clock, a reset, the UART pins, and optionally a
-- keyboard: a stream of bytes that is input like the UART's.
--
-- THEORY OF OPERATION
-- The core (src/nice_core.vhd, wrapping one of nice_cpu's cores) has an instruction bus and a
-- data bus, both pipelined Wishbone. The instruction bus is 64 bits wide: it
-- reads an aligned pair of words from port A of the memory, the word at the
-- lower address in bits 31..0. The data bus shares port B with the CLI, which is a second
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
--   0x00000000-0x00007FFF  The ROM, 2^G_ROM_ADDR_BITS words from G_ROM_FILE
--                          (src/rom.vhd), with the monitor, which the core
--                          boots from, as QNICE-FPGA's is at 0x0000-0x7FFF.
--                          It is in front of the RAM, and repeats with it. A
--                          write to it is dropped. Bit 3 of the control
--                          register hides it, so that the RAM is at 0 as in
--                          the emulator, and a build without G_ROM_FILE has
--                          no ROM.
--   0xFFFF0000-0xFFFF7FFF  The screen: 2^G_SCR_ADDR_BITS words of memory of
--                          their own, so that the emulator's 80x25 screen,
--                          the first 2000, does not land on word 0. The rest
--                          is for scrolling, through the display offset
--                          below. Every write to it is also given out on
--                          scr_*_o, for a display that keeps a copy
--                          (src/video/text.vhd).
--   0xFFFFFF00             The console of SYSTEM.md §1. A write sends bits
--                          7..0 to the UART. It waits while the previous
--                          byte is still waiting to be sent. A read by the
--                          core takes the oldest byte received from the UART
--                          or the keyboard, and returns it in bits 7..0 with
--                          bit 8 set, or 0 when no byte has arrived. The
--                          core's input waits in a FIFO of 2^G_RX_FIFO_BITS
--                          bytes, in block RAM, and a UART byte that arrives
--                          when it is full is lost. A break on the UART, a
--                          frame of ten 0 bits, ends the input, as the end
--                          of the emulator's input does: once the FIFO is
--                          empty, a read returns 0x200 (bit 9), and bytes
--                          after the break are dropped. A break while the
--                          CLI has the UART is ignored. A read by the CLI
--                          returns 0 and takes nothing.
--   0xFFFFFF01             The read counter of the emulator: a read by the
--                          core returns the number of its reads since the
--                          last write, and a write sets that number. A read
--                          by the CLI does not count. It is 0 when the core
--                          starts.
--   0xFFFFFF10-0xFFFFFF1F  The timer of SYSTEM.md §4
--                          (nice_cpu/hdl/src/timer.vhd). It counts clock
--                          cycles, and its request goes to the core's IRQ.
--   0xFFFFFF20-0xFFFFFF3F  The math unit of SYSTEM.md §2
--                          (nice_cpu/hdl/src/mpu.vhd).
--   0xFFFFFF40-0xFFFFFF4F  The performance counters of SYSTEM.md §3
--                          (nice_cpu/hdl/src/perf.vhd).
--   0xFFFFFF50-0xFFFFFF7F  The fetch statistics of MICROARCH.md §8.1
--                          (nice_cpu/hdl/src/fetch_stats.vhd), part of the
--                          performance counters of SYSTEM.md §3. The
--                          multi-cycle core reports nothing to them.
--   0xFFFFFF80-0xFFFFFF8F  The screen's registers, numbered as QNICE-FPGA's
--                          VGA registers at 0xFF30, for the display: 80 is
--                          the state, with bit 6 showing the cursor, bit 5
--                          making it blink, bit 4 making it small, and bit
--                          10 enabling the display offset; 81 and 82 are
--                          the cursor's column and row; and 85 is the
--                          display offset, in words: the display shows the
--                          2000 words from it, so adding 80 scrolls a line.
--                          Bits 11..4 of the state are kept and read back;
--                          the other bits, and the words 83, 84, and 86-8F,
--                          read 0 and take no write. The registers go out on
--                          scr_cur_*_o and scr_offs_o, with scr_ctl_we_o
--                          for a cycle when one is written, and when they
--                          are cleared by reset or by the clear of the memory.
--   0xFFFFFFE0-0xFFFFFFEF  For the CLI only: R0-R15 of the core, read only,
--                          so that they can be read after HALT, as the
--                          emulator prints them.
--   0xFFFFFFF0             Control, for the CLI only. Bit 0 holds the core
--                          in reset while it is 1. A read returns bit 0, the
--                          core's halted flag in bit 1, and bit 3. A write
--                          with bit 2 set first clears the RAM, the screen
--                          included, to 0, as the emulator's memory is at
--                          the start, with the core held. Bit 3 takes effect
--                          when the clear starts, and bit 0 when it ends,
--                          with the OK, when the memory is clear. Bit 3
--                          hides the ROM: while it is 1 the RAM is at 0,
--                          as in the emulator, and the ROM is not reachable.
--                          In a build without a ROM it reads 1 and cannot
--                          be cleared.
--   0xFFFFFFF1             For the CLI only, read only: why the core halted,
--                          as the emulator's "Halted (...)" line says. 0
--                          while it has not halted, 1 for HALT, 2 for a
--                          reserved control word, 3 for INT inside an
--                          interrupt routine, and 4 for RTI outside one.
-- Instruction fetches from 0xFFFFFF00-0xFFFFFFFF read 0 (ISA.md §8.3).
--
-- The core runs when the control bit is 0. While it runs and has not halted,
-- the UART input goes to the core, at 0xFFFFFF00. Otherwise it goes to the
-- CLI. The keyboard's bytes join the UART's: they go the same way, and
-- nothing after the merge tells them apart. A received UART byte goes first.
-- Unlike a UART byte, a keyboard byte is not lost when the core's FIFO is
-- full: it waits until there is room. So the CLI loads a program with W
-- commands, starts it with "W FFFFFFF0 00000000", and gets the UART back
-- when the program halts. A command line should end with CR alone: a LF
-- after the CR of the line that starts the core reaches the program, except
-- for "00000004", which clears and starts: the UART stays with the CLI for
-- the whole clear. The
-- CLI's output goes out before the core's, so its "OK" comes first. When the
-- core halts, and its last byte has gone, the CLI prints CR LF "HALT" CR LF,
-- so that the host knows that the UART is the CLI's again.
--
-- The core starts as the emulator does: the read counter, the math unit,
-- the performance counters, and the timer are reset each time the control
-- bit goes to 0. So, after a halt, the instruction counter holds the number
-- of steps that the emulator prints, unless the program starts the timer,
-- whose interrupts come after clock cycles here, not after steps.
--
-- The data bus of the core is stalled while a CLI request waits, and while a
-- write to the UART waits. The CLI pulses STB for one cycle and does not
-- wait for STALL, so its request is latched and served in the next free
-- cycle. Every request is acknowledged in the cycle after it is served.
-- A request of the core for the MPU, the performance counters, or the
-- timer goes to the device in the cycle it is taken, as one for memory
-- does, and the device acknowledges it. Each device acknowledges in the
-- cycle after it takes a request, except the MPU, which takes a read of a
-- result that it computes and then stalls until it acknowledges it. The
-- core is stalled meanwhile too, so its requests are acknowledged in their
-- order. A CLI request for a device is latched and passed to the device,
-- and it is acknowledged in the cycle after the device's acknowledge. The
-- core is stalled meanwhile, and the CLI waits for any acknowledge that a
-- device owes the core.
--
-- RESET
-- Synchronous. After reset the control bit is 1 when G_CPU_RUN_AT_RESET is
-- false, so the core waits for the CLI, and 0 otherwise, so the core boots
-- from the ROM, which reset shows. The screen's registers are cleared, as
-- they are by the clear of the memory; the memory is not changed.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;
   use ieee.numeric_std.all;

library work;
   use work.trace_pkg.all;
   use work.pipe_pkg.all;

entity nicemon is
   generic (
      G_CLOCK_HZ         : natural;
      G_UART_BAUDRATE    : natural := 115_200;
      G_RAM_ADDR_BITS    : natural := 16;
      -- The screen has 2^G_SCR_ADDR_BITS words.
      G_SCR_ADDR_BITS    : natural := 15;
      -- The core's input FIFO has 2^G_RX_FIFO_BITS bytes.
      G_RX_FIFO_BITS     : natural := 11;
      -- The ROM: 2^G_ROM_ADDR_BITS words from the .bin file G_ROM_FILE, or
      -- none when the file name is empty
      G_ROM_FILE         : string  := "";
      G_ROM_ADDR_BITS    : natural := 15;
      G_CPU_RUN_AT_RESET : boolean := false;
      -- The checks of formal/nicemon.sby, and a RAM with any contents
      G_FORMAL           : boolean := false
   );
   port (
      clk_i          : in  std_logic;
      rst_i          : in  std_logic;
      uart_rxd_i     : in  std_logic;
      uart_txd_o     : out std_logic;
      -- The keyboard's bytes, input like the UART's
      kbd_valid_i    : in  std_logic := '0';
      kbd_ready_o    : out std_logic;
      kbd_data_i     : in  std_logic_vector(7 downto 0) := X"00";
      -- '1' while the core runs and owns the UART input
      running_o      : out std_logic;
      -- The writes to the screen, by the core or the CLI: the word's offset
      -- from 0xFFFF0000, and the word written
      scr_we_o       : out std_logic;
      scr_addr_o     : out std_logic_vector(G_SCR_ADDR_BITS - 1 downto 0);
      scr_data_o     : out std_logic_vector(31 downto 0);
      -- The screen's registers: the cursor's column, row, and mode (bit 0
      -- shown, bit 1 blinking, bit 2 small), and the display offset, which
      -- is 0 while bit 10 of the state is 0. scr_ctl_we_o is '1' for a
      -- cycle when a register is written.
      scr_ctl_we_o   : out std_logic;
      scr_cur_x_o    : out std_logic_vector(6 downto 0);
      scr_cur_y_o    : out std_logic_vector(4 downto 0);
      scr_cur_mode_o : out std_logic_vector(2 downto 0);
      scr_offs_o     : out std_logic_vector(G_SCR_ADDR_BITS - 1 downto 0)
   );
end entity nicemon;

architecture synthesis of nicemon is

   constant C_BUFFER_LEN : natural := 20;
   -- The received bytes for the core. A power of two, so that the pointers
   -- wrap.
   constant C_RX_FIFO_BITS : natural := G_RX_FIFO_BITS;

   constant C_UART_DATA  : std_logic_vector(31 downto 0) := X"FFFFFF00";
   constant C_READ_COUNT : std_logic_vector(31 downto 0) := X"FFFFFF01";
   constant C_CONTROL    : std_logic_vector(31 downto 0) := X"FFFFFFF0";
   constant C_HALT_WHY   : std_logic_vector(31 downto 0) := X"FFFFFFF1";
   -- The core's registers, for the CLI: 0xFFFFFFE0-EF
   constant C_REGS_BASE : std_logic_vector(31 downto 4) := X"FFFFFFE";
   -- The screen: 0xFFFF0000 and the 2^G_SCR_ADDR_BITS words from it, of
   -- which the emulator's screen is the first 2000
   constant C_SCR_BITS : natural := G_SCR_ADDR_BITS;
   constant C_SCR_BASE : std_logic_vector(31 downto C_SCR_BITS) := (31 downto 16 => '1', others => '0');
   -- The screen's registers: 0xFFFFFF80-8F
   constant C_SCR_REGS_BASE : std_logic_vector(31 downto 4) := X"FFFFFF8";

   -- The devices of nice_cpu/hdl/src, by the address bits above their offset
   constant C_TIMER_BASE : std_logic_vector(31 downto 4) := X"FFFFFF1";        -- 0xFFFFFF10-1F
   constant C_MPU_BASE   : std_logic_vector(31 downto 5) := X"FFFFFF" & "001"; -- 0xFFFFFF20-3F
   constant C_PERF_BASE  : std_logic_vector(31 downto 4) := X"FFFFFF4";        -- 0xFFFFFF40-4F
   constant C_FS_BASE    : std_logic_vector(31 downto 6) := X"FFFFFF" & "01";  -- 0xFFFFFF40-7F, less the above

   -- '1' in a build without a ROM, where the RAM is always at 0
   function no_rom return std_logic is
   begin
      if G_ROM_FILE = "" then
         return '1';
      end if;
      return '0';
   end function no_rom;

   constant C_NO_ROM : std_logic := no_rom;

   -- The clearing counts through the larger of the RAM and the screen.
   constant C_CLR_BITS : natural := maximum(G_RAM_ADDR_BITS, C_SCR_BITS);

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
             addr(7 downto 4) = X"1" or addr(7 downto 5) = "001" or -- timer, MPU
             addr(7 downto 6) = "01" or addr(7 downto 4) = X"8" or  -- perf, fetch statistics, screen registers
             (cli and (addr(7 downto 4) = X"E" or addr(7 downto 1) = "1111000"));
   end function is_io;

   -- Whether a memory address is in the ROM's range, which repeats with the
   -- RAM's
   function in_rom(addr : std_logic_vector(31 downto 0)) return boolean is
   begin
      return or(addr(G_RAM_ADDR_BITS - 1 downto G_ROM_ADDR_BITS)) = '0';
   end function in_rom;

   -- The devices of nice_cpu/hdl/src
   type t_dev is (DEV_PERF, DEV_MPU, DEV_TIMER, DEV_FS);

   -- Whether an address is one of the fetch statistics', which are the
   -- words of 0xFFFFFF40-7F that the performance counters do not take
   function is_fs(addr : std_logic_vector(31 downto 0)) return boolean is
   begin
      return addr(31 downto 6) = C_FS_BASE and addr(5 downto 4) /= "00";
   end function is_fs;

   -- Whether an address is one of a device's
   function is_dev(addr : std_logic_vector(31 downto 0)) return boolean is
   begin
      return addr(31 downto 5) = C_MPU_BASE or addr(31 downto 4) = C_PERF_BASE or
             addr(31 downto 4) = C_TIMER_BASE or is_fs(addr);
   end function is_dev;

   -- Core
   signal cpu_rst     : std_logic;
   signal cpu_hold    : std_logic;
   signal cpu_halted  : std_logic;
   signal cpu_instret : std_logic;
   signal cpu_retire  : t_retire;
   signal cpu_stats   : t_fetch_events;
   -- The core's registers, for the CLI's read of E0-EF. The CLI reads them
   -- only while the core is held or halted, when they hold the registers
   -- after the last step and do not change.
   signal cpu_regs : t_regs;
   -- The hold bit in the cycle before, for a pulse when the core starts,
   -- which resets the math unit, the performance counters, and the timer
   signal cpu_hold_d : std_logic := '1';
   signal dev_rst    : std_logic;
   -- A halt waits in halt_wait until the core's last byte has gone, and
   -- then halt_note tells the CLI.
   signal cpu_halted_d : std_logic := '0';
   signal halt_wait    : std_logic := '0';
   signal halt_note    : std_logic := '0';
   -- The pipelined core reports the reason in the cycle the step retires,
   -- so it is kept here until the core is reset.
   signal halt_why : t_halt := HALT_NONE;

   -- Clearing the memory: the address, and the hold bit after it
   signal clearing : std_logic := '0';
   signal clr_addr : std_logic_vector(C_CLR_BITS - 1 downto 0);
   signal clr_hold : std_logic;

   -- Bit 3 of the control register: the ROM is hidden, and the RAM is at 0
   signal rom_hidden : std_logic := C_NO_ROM;

   -- The screen's registers: the state's bits 11..4, the cursor's column
   -- and row, and the display offset
   signal scr_state  : std_logic_vector(11 downto 4) := (others => '0');
   signal scr_cur_x  : std_logic_vector(6 downto 0) := (others => '0');
   signal scr_cur_y  : std_logic_vector(4 downto 0) := (others => '0');
   signal scr_offs   : std_logic_vector(C_SCR_BITS - 1 downto 0) := (others => '0');
   signal scr_ctl_we : std_logic := '0';

   -- The number of the core's data reads of 0xFFFFFF01 since it was written
   signal read_count : std_logic_vector(31 downto 0) := (others => '0');

   signal ibus_cyc  : std_logic;
   signal ibus_stb  : std_logic;
   signal ibus_ack  : std_logic := '0';
   signal ibus_addr : std_logic_vector(30 downto 0);   -- the pair address
   signal ibus_word : std_logic_vector(31 downto 0);   -- its first word
   signal ibus_data : std_logic_vector(63 downto 0);
   signal ibus_io   : std_logic := '0';
   signal ibus_scr  : std_logic := '0';
   signal ibus_rom  : std_logic := '0';

   signal dbus_cyc   : std_logic;
   signal dbus_stb   : std_logic;
   signal dbus_stall : std_logic;
   signal dbus_ack   : std_logic;
   signal dbus_we    : std_logic;
   signal dbus_addr  : std_logic_vector(31 downto 0);
   signal dbus_wdata : std_logic_vector(31 downto 0);
   signal dbus_rdata : std_logic_vector(31 downto 0);
   -- The acknowledge of a core request served here, not by a device
   signal srv_ack : std_logic := '0';

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

   -- A CLI request for the MPU, the performance counters, or the timer. It
   -- is latched, and the device's port is driven from the latch until the
   -- device acknowledges.
   signal dev_busy  : std_logic := '0';
   signal dev_stb   : std_logic := '0';
   signal dev_sel   : t_dev;               -- the device
   signal dev_addr  : std_logic_vector(5 downto 0);
   signal dev_we    : std_logic;
   signal dev_wdata : std_logic_vector(31 downto 0);
   signal dev_stall : std_logic;
   signal dev_ack   : std_logic;           -- any device's

   -- A request of the core for a device, taken in this cycle, and whether
   -- a device owes the core an acknowledge
   signal core_take : std_logic;
   signal core_dev  : std_logic;
   signal core_owed : std_logic := '0';

   -- The devices' ports: the CLI's latch while it is busy, else the core
   signal io_cyc   : std_logic;
   signal io_we    : std_logic;
   signal io_addr  : std_logic_vector(5 downto 0);
   signal io_wdata : std_logic_vector(31 downto 0);

   signal mpu_cyc     : std_logic;
   signal mpu_stb     : std_logic;
   signal mpu_stall   : std_logic;
   signal mpu_ack     : std_logic;
   signal mpu_data    : std_logic_vector(31 downto 0);
   signal perf_cyc    : std_logic;
   signal perf_stb    : std_logic;
   signal perf_stall  : std_logic;
   signal perf_ack    : std_logic;
   signal perf_data   : std_logic_vector(31 downto 0);
   signal fs_cyc      : std_logic;
   signal fs_stb      : std_logic;
   signal fs_stall    : std_logic;
   signal fs_ack      : std_logic;
   signal fs_data     : std_logic_vector(31 downto 0);
   signal timer_cyc   : std_logic;
   signal timer_stb   : std_logic;
   signal timer_stall : std_logic;
   signal timer_ack   : std_logic;
   signal timer_data  : std_logic_vector(31 downto 0);

   -- The timer's interrupt request, on the core's IRQ port
   signal irq_valid  : std_logic;
   signal irq_ready  : std_logic;
   signal irq_vector : std_logic_vector(7 downto 0);

   -- Memory ports A and B, and the source of the read data of the last request
   signal ram_a_addr  : std_logic_vector(G_RAM_ADDR_BITS - 2 downto 0);
   signal ram_a_data  : std_logic_vector(63 downto 0);
   signal ram_b_addr  : std_logic_vector(G_RAM_ADDR_BITS - 1 downto 0);
   signal ram_b_we    : std_logic;
   signal ram_b_wdata : std_logic_vector(31 downto 0);
   signal ram_b_rdata : std_logic_vector(31 downto 0);
   signal rd_ram      : std_logic := '0';
   signal rd_rom      : std_logic := '0';
   signal rd_scr      : std_logic := '0';
   signal rd_rx       : std_logic := '0';
   signal rd_mpu      : std_logic := '0';
   signal rd_perf     : std_logic := '0';
   signal rd_fs       : std_logic := '0';
   signal rd_timer    : std_logic := '0';

   -- The ROM, read at the addresses of the memory ports
   signal rom_a_data : std_logic_vector(63 downto 0);
   signal rom_b_data : std_logic_vector(31 downto 0);

   -- The screen memory, like the main memory
   signal scr_a_data  : std_logic_vector(63 downto 0);
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

   -- The input, from the UART or the keyboard
   signal kbd_take : std_logic;
   signal in_valid : std_logic;
   signal in_data  : std_logic_vector(7 downto 0);
   signal rx_full  : std_logic;

   signal lb_rx_valid : std_logic;
   signal lb_rx_ready : std_logic;
   signal lb_tx_valid : std_logic;
   signal lb_tx_ready : std_logic;
   signal lb_tx_data  : std_logic_vector(7 downto 0);

   signal cpu_tx_valid : std_logic := '0';
   signal cpu_tx_ready : std_logic;
   signal cpu_tx_data  : std_logic_vector(7 downto 0);
   -- The core's input FIFO (src/rx_fifo.vhd). rx_q holds the oldest byte in
   -- the cycle after a read of the console takes it.
   signal rx_wr_en : std_logic;
   signal rx_end   : std_logic;
   signal rx_take  : std_logic;
   signal rx_empty : std_logic;
   signal rx_q     : std_logic_vector(7 downto 0);
   -- The core's input has ended with a break.
   signal rx_eof : std_logic;

   signal rx_buffer_ready : std_logic;
   signal rx_buffer_valid : std_logic;
   signal rx_buffer_size  : natural range 0 to C_BUFFER_LEN;
   signal rx_buffer_data  : std_logic_vector(8 * C_BUFFER_LEN - 1 downto 0);
   signal tx_buffer_ready : std_logic;
   signal tx_buffer_valid : std_logic;
   signal tx_buffer_size  : natural range 0 to C_BUFFER_LEN;
   signal tx_buffer_data  : std_logic_vector(8 * C_BUFFER_LEN - 1 downto 0);

begin

   assert C_SCR_BITS >= 11 and C_SCR_BITS <= 15
      report "nicemon: the screen must hold its 2000 words, below the I/O registers"
      severity failure;

   assert G_ROM_ADDR_BITS < G_RAM_ADDR_BITS
      report "nicemon: the ROM must leave room for RAM above it"
      severity failure;

   ---------------------------------------------------------------------------
   -- The core
   ---------------------------------------------------------------------------

   cpu_rst <= rst_i or cpu_hold;

   i_core : entity work.nice_core
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
         irq_valid_i  => irq_valid,
         irq_ready_o  => irq_ready,
         irq_vector_i => irq_vector,
         halted_o     => cpu_halted,
         instret_o    => cpu_instret,
         regs_o       => cpu_regs,
         retire_o     => cpu_retire,
         stats_o      => cpu_stats
      ); -- i_core

   uart_owner_cpu <= not cpu_hold and not cpu_halted;
   running_o      <= uart_owner_cpu;


   ---------------------------------------------------------------------------
   -- Instruction bus: memory port A. It never stalls. A pair lies wholly in
   -- the RAM, the ROM, the screen, or the I/O page, so the address of its
   -- first word decides where it is read.
   ---------------------------------------------------------------------------

   ibus_word  <= ibus_addr & '0';
   ram_a_addr <= ibus_addr(G_RAM_ADDR_BITS - 2 downto 0);

   p_ibus : process (clk_i)
   begin
      if rising_edge(clk_i) then
         ibus_ack <= ibus_cyc and ibus_stb;
         ibus_io  <= and(ibus_word(31 downto 8));
         ibus_scr <= '1' when ibus_word(31 downto C_SCR_BITS) = C_SCR_BASE else '0';
         ibus_rom <= '1' when rom_hidden = '0' and in_rom(ibus_word) else '0';
         if cpu_rst = '1' then
            ibus_ack <= '0';
         end if;
      end if;
   end process p_ibus;

   ibus_data <= (others => '0') when ibus_io = '1' else
                scr_a_data when ibus_scr = '1' else
                rom_a_data when ibus_rom = '1' else
                ram_a_data;


   ---------------------------------------------------------------------------
   -- Data bus and CLI: memory port B and the I/O registers
   ---------------------------------------------------------------------------

   -- The core's request is taken in a cycle with no stall. The MPU's stall
   -- holds the core while it computes a result that the core reads.
   dbus_stall <= cli_pend or tx_wait or dev_busy or clearing or mpu_stall;
   dbus_ack   <= srv_ack or (core_owed and dev_ack);

   -- A request of the core in reset is dropped: it is not taken, whatever it
   -- is, though the core's registered request may still show in the first
   -- cycle of a hold.
   core_take <= dbus_cyc and dbus_stb and not dbus_stall and not cpu_rst;
   core_dev  <= '1' when core_take = '1' and is_dev(dbus_addr) else
                '0';

   ram_b_addr  <= clr_addr(G_RAM_ADDR_BITS - 1 downto 0) when clearing = '1' else
                  cli_p_addr(G_RAM_ADDR_BITS - 1 downto 0) when cli_pend = '1' else
                  dbus_addr(G_RAM_ADDR_BITS - 1 downto 0);
   ram_b_wdata <= (others => '0') when clearing = '1' else
                  cli_p_wdata when cli_pend = '1' else
                  dbus_wdata;
   scr_b_addr  <= clr_addr(C_SCR_BITS - 1 downto 0) when clearing = '1' else
                  cli_p_addr(C_SCR_BITS - 1 downto 0) when cli_pend = '1' else
                  dbus_addr(C_SCR_BITS - 1 downto 0);

   -- A write to memory is served in the cycle that the CLI's or the core's
   -- request is taken, and in no other cycle. It goes to the screen or to the main memory, unless
   -- it is to the ROM, where it is dropped. While the memory is cleared,
   -- both are written, the RAM under the ROM included.
   p_mem_we : process (all)
      variable we_v   : std_logic;
      variable addr_v : std_logic_vector(31 downto 0);
   begin
      we_v   := '0';
      addr_v := dbus_addr;
      if clearing = '1' then
         null;
      elsif dev_busy = '0' and cli_pend = '1' and core_owed = '0' and mpu_stall = '0' then
         addr_v := cli_p_addr;
         if not is_io(cli_p_addr, true) then
            we_v := cli_p_we;
         end if;
      elsif core_take = '1' then
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
      elsif rom_hidden = '0' and in_rom(addr_v) then
         ram_b_we <= '0';
         scr_b_we <= '0';
      else
         ram_b_we <= we_v;
         scr_b_we <= '0';
      end if;
   end process p_mem_we;

   dbus_rdata <= ram_b_rdata when rd_ram = '1' else
                 rom_b_data when rd_rom = '1' else
                 scr_b_rdata when rd_scr = '1' else
                 X"00000" & "0001" & rx_q when rd_rx = '1' else
                 mpu_data when rd_mpu = '1' else
                 perf_data when rd_perf = '1' else
                 fs_data when rd_fs = '1' else
                 timer_data when rd_timer = '1' else
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
         rd_rom <= '0';
         rd_scr <= '0';
         rd_rx    <= '0';
         rd_mpu   <= '0';
         rd_perf  <= '0';
         rd_fs    <= '0';
         rd_timer <= '0';
         rd_io    <= (others => '0');
         if not is_io(addr, cli) then
            -- Memory: port B is driven combinationally above.
            if addr(31 downto C_SCR_BITS) = C_SCR_BASE then
               rd_scr <= '1';
            elsif rom_hidden = '0' and in_rom(addr) then
               rd_rom <= '1';
            else
               rd_ram <= '1';
            end if;
         elsif is_dev(addr) and not cli then
            -- A device has taken the core's request, and it acknowledges
            -- it, with the data that rd_mpu, rd_perf, rd_fs, or rd_timer selects.
            if addr(31 downto 5) = C_MPU_BASE then
               rd_mpu <= '1';
            elsif addr(31 downto 4) = C_PERF_BASE then
               rd_perf <= '1';
            elsif is_fs(addr) then
               rd_fs <= '1';
            else
               rd_timer <= '1';
            end if;
            return;
         elsif is_dev(addr) then
            -- The CLI's: the device's port is driven from the latch, and the
            -- request is acknowledged when the device acknowledges it.
            dev_busy <= '1';
            dev_stb  <= '1';
            if addr(31 downto 5) = C_MPU_BASE then
               dev_sel <= DEV_MPU;
            elsif addr(31 downto 4) = C_PERF_BASE then
               dev_sel <= DEV_PERF;
            elsif is_fs(addr) then
               dev_sel <= DEV_FS;
            else
               dev_sel <= DEV_TIMER;
            end if;
            dev_addr  <= addr(5 downto 0);
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
            if rx_empty = '0' then
               -- rx_take takes the byte, and it comes from rx_q in the next
               -- cycle.
               rd_rx <= '1';
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
         elsif addr(31 downto 4) = C_SCR_REGS_BASE then
            -- The screen's registers. A write is told to the display.
            if we = '1' then
               scr_ctl_we <= '1';

               case addr(3 downto 0) is
                  when X"0"   => scr_state <= wdata(11 downto 4);
                  when X"1"   => scr_cur_x <= wdata(6 downto 0);
                  when X"2"   => scr_cur_y <= wdata(4 downto 0);
                  when X"5"   => scr_offs  <= wdata(C_SCR_BITS - 1 downto 0);
                  when others => null;
               end case;

            else

               case addr(3 downto 0) is
                  when X"0"   => rd_io(11 downto 4) <= scr_state;
                  when X"1"   => rd_io(6 downto 0) <= scr_cur_x;
                  when X"2"   => rd_io(4 downto 0) <= scr_cur_y;
                  when X"5"   => rd_io(C_SCR_BITS - 1 downto 0) <= scr_offs;
                  when others => null;
               end case;

            end if;
         elsif addr(31 downto 4) = C_REGS_BASE and cli then
            if we = '0' then
               rd_io <= cpu_regs(to_integer(addr(3 downto 0)));
            end if;
         elsif addr = C_CONTROL and cli then
            if we = '1' and wdata(2) = '1' then
               -- Clear the memory with the core held. The request is
               -- acknowledged when the memory is clear.
               clearing   <= '1';
               scr_state  <= (others => '0');
               scr_cur_x  <= (others => '0');
               scr_cur_y  <= (others => '0');
               scr_offs   <= (others => '0');
               scr_ctl_we <= '1';
               clr_addr   <= (others => '0');
               clr_hold   <= wdata(0);
               cpu_hold   <= '1';
               rom_hidden <= wdata(3) or C_NO_ROM;
               return;
            elsif we = '1' then
               cpu_hold   <= wdata(0);
               rom_hidden <= wdata(3) or C_NO_ROM;
            else
               rd_io(0) <= cpu_hold;
               rd_io(1) <= cpu_halted;
               rd_io(3) <= rom_hidden;
            end if;
         elsif addr = C_HALT_WHY and cli then
            -- The reason is kept until the core is reset.
            if we = '0' then
               rd_io(2 downto 0) <= std_logic_vector(to_unsigned(t_halt'pos(halt_why), 3));
            end if;
         end if;
         if cli then
            cli_ack <= '1';
         else
            srv_ack <= '1';
         end if;
      end procedure serve;

   begin
      if rising_edge(clk_i) then
         srv_ack      <= '0';
         cli_ack      <= '0';
         halt_note    <= '0';
         scr_ctl_we   <= '0';
         cpu_hold_d   <= cpu_hold;
         cpu_halted_d <= cpu_halted;

         if cpu_rst = '1' then
            halt_why <= HALT_NONE;
         elsif cpu_retire.halt /= HALT_NONE then
            halt_why <= cpu_retire.halt;
         end if;

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
            if dev_ack = '1' then
               rd_ram   <= '0';
               rd_rom   <= '0';
               rd_scr   <= '0';
               rd_rx    <= '0';
               rd_mpu   <= '0';
               rd_perf  <= '0';
               rd_fs    <= '0';
               rd_timer <= '0';
               if mpu_ack = '1' then
                  rd_io <= mpu_data;
               elsif perf_ack = '1' then
                  rd_io <= perf_data;
               elsif fs_ack = '1' then
                  rd_io <= fs_data;
               else
                  rd_io <= timer_data;
               end if;
               dev_busy <= '0';
               cli_ack  <= '1';
            end if;
         elsif clearing = '1' then
            clr_addr <= clr_addr + 1;
            if and(clr_addr) = '1' then
               clearing <= '0';
               cpu_hold <= clr_hold;
               cli_ack  <= '1';
            end if;
         elsif cli_pend = '1' and core_owed = '0' and mpu_stall = '0' then
            -- The CLI waits for any acknowledge that a device owes the core,
            -- or would owe it had the core not been reset meanwhile.
            serve(true, cli_p_addr, cli_p_we, cli_p_wdata);
            cli_pend <= '0';
         elsif tx_wait = '1' then
            if cpu_tx_valid = '0' or cpu_tx_ready = '1' then
               cpu_tx_data  <= tx_wait_data;
               cpu_tx_valid <= '1';
               tx_wait      <= '0';
               srv_ack      <= '1';
            end if;
         elsif core_take = '1' then
            serve(false, dbus_addr, dbus_we, dbus_wdata);
         end if;

         -- Each device acknowledges in the cycle after it takes a request,
         -- or stalls the core until it does, so at most one is owed.
         if core_dev = '1' then
            core_owed <= '1';
         elsif dev_ack = '1' then
            core_owed <= '0';
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
            srv_ack      <= '0';
            core_owed    <= '0';
            tx_wait      <= '0';
            halt_wait    <= '0';
            read_count   <= (others => '0');
         end if;

         if rst_i = '1' then
            dev_busy     <= '0';
            dev_stb      <= '0';
            cli_pend     <= '0';
            cli_ack      <= '0';
            clearing     <= '0';
            cpu_tx_valid <= '0';
            rom_hidden   <= C_NO_ROM;
            scr_state    <= (others => '0');
            scr_cur_x    <= (others => '0');
            scr_cur_y    <= (others => '0');
            scr_offs     <= (others => '0');
            scr_ctl_we   <= '1';
            if G_CPU_RUN_AT_RESET then
               cpu_hold <= '0';
            else
               cpu_hold <= '1';
            end if;
         end if;
      end if;
   end process p_dbus;

   -- A byte for the core goes into its FIFO, which drops it when it is full
   -- or the input has ended. A read of the console by the core takes the
   -- oldest byte, in the cycle that serves it: the cycle that accepts the
   -- request. A request of the core in reset is dropped, and so is a byte
   -- received before, so that a program starts with no input.
   rx_wr_en <= in_valid and uart_owner_cpu;
   rx_end   <= ser_rx_break and uart_owner_cpu;
   rx_take  <= '1' when core_take = '1' and
                        dbus_addr = C_UART_DATA and dbus_we = '0' else
               '0';

   i_rx_fifo : entity work.rx_fifo
      generic map (
         G_ADDR_BITS => C_RX_FIFO_BITS
      )
      port map (
         clk_i     => clk_i,
         rst_i     => cpu_rst,
         wr_en_i   => rx_wr_en,
         wr_data_i => in_data,
         full_o    => rx_full,
         end_i     => rx_end,
         ended_o   => rx_eof,
         rd_en_i   => rx_take,
         empty_o   => rx_empty,
         rd_data_o => rx_q
      ); -- i_rx_fifo


   ---------------------------------------------------------------------------
   -- The math unit (SYSTEM.md §2), the performance counters (§3), and the
   -- timer (§4) from nice_cpu. They are reset with the system, and when
   -- the core starts, as the emulator's are when it starts. They are not
   -- reset while the CLI holds the core, so that the CLI can read them after
   -- a halt. The timer counts clock cycles, and it is the only device that
   -- raises an interrupt, so its request goes straight to the core's IRQ.
   ---------------------------------------------------------------------------

   dev_rst <= rst_i or (cpu_hold_d and not cpu_hold);

   -- The CLI's latched request while it is busy, else the core's request,
   -- which goes to a device only in the cycle that takes it
   io_cyc   <= '1' when dev_busy = '1' else dbus_cyc;
   io_we    <= dev_we when dev_busy = '1' else dbus_we;
   io_addr  <= dev_addr when dev_busy = '1' else dbus_addr(5 downto 0);
   io_wdata <= dev_wdata when dev_busy = '1' else dbus_wdata;

   mpu_cyc   <= io_cyc;
   perf_cyc  <= io_cyc;
   fs_cyc    <= io_cyc;
   timer_cyc <= io_cyc;
   mpu_stb   <= dev_stb when dev_busy = '1' and dev_sel = DEV_MPU else
                core_dev when dbus_addr(31 downto 5) = C_MPU_BASE else
                '0';
   perf_stb  <= dev_stb when dev_busy = '1' and dev_sel = DEV_PERF else
                core_dev when dbus_addr(31 downto 4) = C_PERF_BASE else
                '0';
   fs_stb    <= dev_stb when dev_busy = '1' and dev_sel = DEV_FS else
                core_dev when is_fs(dbus_addr) else
                '0';
   timer_stb <= dev_stb when dev_busy = '1' and dev_sel = DEV_TIMER else
                core_dev when dbus_addr(31 downto 4) = C_TIMER_BASE else
                '0';
   dev_stall <= mpu_stall when dev_sel = DEV_MPU else
                perf_stall when dev_sel = DEV_PERF else
                fs_stall when dev_sel = DEV_FS else
                timer_stall;
   dev_ack   <= mpu_ack or perf_ack or fs_ack or timer_ack;

   i_mpu : entity work.mpu
      port map (
         clk_i      => clk_i,
         rst_i      => dev_rst,
         wb_cyc_i   => mpu_cyc,
         wb_stb_i   => mpu_stb,
         wb_stall_o => mpu_stall,
         wb_ack_o   => mpu_ack,
         wb_we_i    => io_we,
         wb_addr_i  => io_addr(4 downto 0),
         wb_data_i  => io_wdata,
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
         wb_we_i    => io_we,
         wb_addr_i  => io_addr(3 downto 0),
         wb_data_i  => io_wdata,
         wb_data_o  => perf_data
      ); -- i_perf

   i_fetch_stats : entity work.fetch_stats
      port map (
         clk_i      => clk_i,
         rst_i      => dev_rst,
         events_i   => cpu_stats,
         wb_cyc_i   => fs_cyc,
         wb_stb_i   => fs_stb,
         wb_stall_o => fs_stall,
         wb_ack_o   => fs_ack,
         wb_we_i    => io_we,
         wb_addr_i  => io_addr,
         wb_data_i  => io_wdata,
         wb_data_o  => fs_data
      ); -- i_fetch_stats


   i_timer : entity work.timer
      port map (
         clk_i        => clk_i,
         rst_i        => dev_rst,
         tick_i       => '1',
         wb_cyc_i     => timer_cyc,
         wb_stb_i     => timer_stb,
         wb_stall_o   => timer_stall,
         wb_ack_o     => timer_ack,
         wb_we_i      => io_we,
         wb_addr_i    => io_addr(3 downto 0),
         wb_data_i    => io_wdata,
         wb_data_o    => timer_data,
         irq_valid_o  => irq_valid,
         irq_ready_i  => irq_ready,
         irq_vector_o => irq_vector
      ); -- i_timer

   i_ram : entity work.ram
      generic map (
         G_ADDR_BITS => G_RAM_ADDR_BITS,
         G_FORMAL    => G_FORMAL
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

   gen_rom : if G_ROM_FILE /= "" generate

      -- The ROM, read at the addresses of both memory ports. Its words are
      -- taken instead of the RAM's while it is not hidden.
      i_rom : entity work.rom
         generic map (
            G_ADDR_BITS => G_ROM_ADDR_BITS,
            G_INIT_FILE => G_ROM_FILE
         )
         port map (
            clk_i    => clk_i,
            a_addr_i => ram_a_addr(G_ROM_ADDR_BITS - 2 downto 0),
            a_data_o => rom_a_data,
            b_addr_i => ram_b_addr(G_ROM_ADDR_BITS - 1 downto 0),
            b_data_o => rom_b_data
         ); -- i_rom

   end generate gen_rom;

   gen_no_rom : if G_ROM_FILE = "" generate

      rom_a_data <= (others => '0');
      rom_b_data <= (others => '0');

   end generate gen_no_rom;

   -- The screen, at 0xFFFF0000. It is memory, as in the emulator, so the CLI
   -- can read what a program wrote there. Without it the address would
   -- land at word 0 of the main memory. A display keeps its own copy, from
   -- the writes given out here, a cycle late, and shows it as the registers
   -- say. The register keeps the core's store paths short, for the display
   -- lies far from the core on the FPGA.
   p_scr_out : process (clk_i)
   begin
      if rising_edge(clk_i) then
         scr_we_o   <= scr_b_we;
         scr_addr_o <= scr_b_addr;
         scr_data_o <= ram_b_wdata;
      end if;
   end process p_scr_out;

   scr_ctl_we_o   <= scr_ctl_we;
   scr_cur_x_o    <= scr_cur_x;
   scr_cur_y_o    <= scr_cur_y;
   scr_cur_mode_o <= scr_state(4) & scr_state(5) & scr_state(6);
   scr_offs_o     <= scr_offs when scr_state(10) = '1' else (others => '0');

   i_scr : entity work.ram
      generic map (
         G_ADDR_BITS => C_SCR_BITS
      )
      port map (
         clk_i     => clk_i,
         a_addr_i  => ibus_addr(C_SCR_BITS - 2 downto 0),
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

   -- The input: a UART byte, or else a keyboard byte, which is taken only
   -- when it has room.
   kbd_take <= kbd_valid_i and not ser_rx_valid and
               ((uart_owner_cpu and not rx_full) or (not uart_owner_cpu and lb_rx_ready));
   in_valid <= ser_rx_valid or kbd_take;
   in_data  <= ser_rx_data when ser_rx_valid = '1' else kbd_data_i;

   kbd_ready_o  <= kbd_take;
   lb_rx_valid  <= in_valid and not uart_owner_cpu;
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
         rx_data_i         => in_data,
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


   ---------------------------------------------------------------------------
   -- The checks of formal/nicemon.sby. The core's two buses are pipelined
   -- Wishbone, and nice_cpu's formal checks prove either core right for
   -- any slave that sends ACK only while CYC is high, and only for a
   -- request that waits. These check that this system is such a slave, the
   -- CLI's request latch and the devices' included, and that the CLI's
   -- port gets one ACK for each request, as formal/formal_cli.vhd assumes.
   -- A request of the core waits from the cycle that accepts it until its
   -- ACK, or until the core is reset, which drops it. The pipelined core
   -- has several requests waiting on a bus, so f_ibus_wait and f_dbus_wait
   -- count them.
   ---------------------------------------------------------------------------

   gen_formal : if G_FORMAL generate
      signal f_ibus_wait : natural range 0 to 15 := 0;
      signal f_dbus_wait : natural range 0 to 15 := 0;
      signal f_cli_wait  : std_logic := '0';
      signal f_rx_byte   : std_logic;
      signal f_rx_end    : std_logic;
      signal f_cpu_rst_d : std_logic := '1';
   begin

      p_wait : process (clk_i)
      begin
         if rising_edge(clk_i) then
            if ibus_cyc = '1' and ibus_stb = '1' and ibus_ack = '0' then
               f_ibus_wait <= f_ibus_wait + 1;
            elsif (ibus_cyc = '0' or ibus_stb = '0') and ibus_ack = '1' then
               f_ibus_wait <= f_ibus_wait - 1;
            end if;
            if dbus_cyc = '1' and dbus_stb = '1' and dbus_stall = '0' and dbus_ack = '0' then
               f_dbus_wait <= f_dbus_wait + 1;
            elsif (dbus_cyc = '0' or dbus_stb = '0' or dbus_stall = '1') and dbus_ack = '1' then
               f_dbus_wait <= f_dbus_wait - 1;
            end if;
            if cli_cyc = '1' and cli_stb = '1' then
               f_cli_wait <= '1';
            elsif cli_ack = '1' then
               f_cli_wait <= '0';
            end if;

            if cpu_rst = '1' then
               f_ibus_wait <= 0;
               f_dbus_wait <= 0;
            end if;
            if rst_i = '1' then
               f_cli_wait <= '0';
            end if;
            f_cpu_rst_d <= cpu_rst;
         end if;
      end process p_wait;

      -- A read of the console by the core takes a byte, or finds the FIFO
      -- empty after the end of the input
      f_rx_byte <= rx_take and not rx_empty;
      f_rx_end  <= rx_take and rx_empty and rx_eof;

      -- psl default clock is rising_edge(clk_i);

      -- The core's buses
      -- psl f_ibus_ack : assert always
      --    rst_i = '0' and ibus_ack = '1' -> ibus_cyc = '1' and f_ibus_wait /= 0;
      -- psl f_dbus_ack : assert always
      --    rst_i = '0' and dbus_ack = '1' -> dbus_cyc = '1' and f_dbus_wait /= 0;

      -- The CLI's port, and its latch
      -- psl f_cli_ack : assert always rst_i = '0' and cli_ack = '1' -> f_cli_wait = '1';
      -- psl f_cli_latch : assert always
      --    rst_i = '0' and cli_stb = '1' -> cli_pend = '0' and f_cli_wait = '0';

      -- The devices answer the CLI's latched request, or a request of the
      -- core, which is dropped if the core has been reset. The core gets one
      -- acknowledge at a time.
      -- psl f_dev_ack : assert always
      --    rst_i = '0' and dev_ack = '1' ->
      --    dev_busy = '1' or core_owed = '1' or cpu_rst = '1' or f_cpu_rst_d = '1';
      -- psl f_one_ack : assert always
      --    rst_i = '0' -> not (srv_ack = '1' and core_owed = '1' and dev_ack = '1');

      -- The console's answer: a byte with bit 8, 0x200 at the end, or 0
      -- psl f_console : assert always
      --    {rx_take and not rst_i} |=>
      --    {rst_i = '1' or cpu_rst = '1' or
      --     (dbus_ack = '1' and dbus_rdata(31 downto 10) = 0 and
      --      dbus_rdata(8) = prev(f_rx_byte) and dbus_rdata(9) = prev(f_rx_end))};

      -- psl c_console : cover {f_rx_byte and not rst_i};
      -- psl c_console_end : cover {f_rx_end and not rst_i};
      -- psl c_tx_wait : cover {tx_wait and not rst_i};
      -- psl c_dev_core : cover {core_dev and not rst_i and not cpu_rst; dbus_ack};
      -- psl c_dev_cli : cover {dev_busy and not rst_i; cli_ack};
      -- psl c_cli : cover {cli_ack and not rst_i};
      -- psl c_halt : cover {halt_note and not rst_i};
   end generate gen_formal;

end architecture synthesis;
