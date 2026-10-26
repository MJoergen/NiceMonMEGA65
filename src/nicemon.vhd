-- The NiceMon system: the NICE core, its memory and I/O, and the debug link
-- of nice_cpu/doc/DEBUG.md on the UART. It is the same for every board. The
-- board's top level gives it a clock, a reset, the UART pins, and optionally
-- a keyboard: a stream of bytes that is input like the UART's.
--
-- THEORY OF OPERATION
-- The core (src/nice_core.vhd, wrapping one of nice_cpu's cores) has an instruction bus and a
-- data bus, both pipelined Wishbone. The instruction bus is 64 bits wide: it
-- reads an aligned pair of words from port A of the memory, the word at the
-- lower address in bits 31..0. The data bus shares port B with the debug
-- link (nice_cpu/hdl/src/debug_link.vhd), a second Wishbone master. The link
-- shares the UART with the console: through it a host reads and writes the
-- memory, loads and starts a program, and learns when it halts.
--
-- Address map, as in the emulator (nice_cpu/emulator/README.md), and the
-- same for the link and the core's data bus apart from the link's own
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
--                          write to it is dropped. Bit 3 of the link's
--                          control register hides it, so that the RAM is at
--                          0 as in the emulator, and a build without
--                          G_ROM_FILE has no ROM.
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
--                          when it is full is lost, and the link sends `o`.
--                          A break on the UART, a frame of ten 0 bits, ends
--                          the input until the next start, as the end of
--                          the emulator's input does: once the FIFO is
--                          empty, a read returns 0x200 (bit 9), and bytes
--                          after the break are dropped. A read by the link
--                          returns 0 and takes nothing, and a write by the
--                          link is dropped.
--   0xFFFFFF01             The read counter of the emulator: a read by the
--                          core returns the number of its reads since the
--                          last write, and a write sets that number. A read
--                          by the link returns 0 and does not count, and a
--                          write by the link is dropped. It is 0 after
--                          reset, and a start keeps it (SYSTEM.md §1).
--   0xFFFFFF10-0xFFFFFF1F  The timer of SYSTEM.md §4
--                          (nice_cpu/hdl/src/timer.vhd). It counts clock
--                          cycles, and its request goes to the core's IRQ.
--   0xFFFFFF20-0xFFFFFF3F  The math unit of SYSTEM.md §2
--                          (nice_cpu/hdl/src/mpu.vhd).
--   0xFFFFFF40-0xFFFFFF4F  The performance counters of SYSTEM.md §3
--                          (nice_cpu/hdl/src/perf.vhd): cycles,
--                          instructions, and microseconds, the last
--                          derived from G_CLOCK_HZ.
--   0xFFFFFF50-0xFFFFFF7F  The fetch statistics of MICROARCH.md §8.1
--                          (nice_cpu/hdl/src/fetch_stats.vhd), part of the
--                          performance counters of SYSTEM.md §3. The
--                          multi-cycle core reports no events to them, so
--                          only FS_CYCLES and FS_HIST[0] count.
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
--   0xFFFFFF90-0xFFFFFF9F  The board's devices, with G_BOARD_IO (the
--                          Nexys4DDR). Without it, and in the words that
--                          are not registers, a read returns 0 and a write
--                          is dropped. Reset clears the writable ones; a
--                          start of the core does not.
--     90  The 16 LEDs, bit n for LED n. Read and write.
--     91  RGB LED 0: bits 11..8 red, 7..4 green, 3..0 blue, each a level
--         of 0 to 15. Read and write.
--     92  RGB LED 1, as 91.
--     93  The segments of digits 3..0 of the seven-segment display, a byte
--         each, digit 0 in bits 7..0: bit 0 is segment A, up to bit 6 for
--         G, and bit 7 is the decimal point; 1 lights it. Read and write.
--     94  The segments of digits 7..4, as 93, digit 4 in bits 7..0.
--     95  The five buttons, bit 0 for the center one, then up, left, right,
--         and down. Read only, synchronized to the clock.
--     96  The 16 switches, bit n for switch n. Read only, synchronized.
--   0xFFFFFFE0-0xFFFFFFFF  The debug registers of DEBUG.md §6, for the link
--                          only, which debug_link holds: R0-R15 of the core
--                          after a halt or at a pause, the control
--                          register, the halt reason (1 to 4 here), the
--                          version, 4, the free space of the core's input
--                          FIFO, and the G_BREAKS breakpoints: their enable
--                          bits, their number, the stop register, and
--                          their addresses. Bit 0 of the control register holds
--                          the core in reset, bit 2 clears the RAM, the RAM
--                          under the ROM and the screen included, to 0, as
--                          the emulator's memory is at the start, bit 3
--                          hides the ROM; in a build without a ROM it reads
--                          1, and bit 4 pauses the core. The core's data
--                          accesses to these words go to the memory.
-- Instruction fetches from 0xFFFFFF00-0xFFFFFFFF read 0 (ISA.md §8.3).
--
-- The core runs while bit 0 of the control register is 0, it has not
-- halted, and it is not paused. Then the link reaches only its debug
-- registers, and the core owns port B. While the core is held, halted, or
-- paused, the link owns port B, and the core's data bus is stalled. A host
-- loads a program with W packets and starts it by writing 0 to bit 0, and
-- the link sends `h` when it halts, after the core's last console byte.
-- Bit 4 of the control register drives the core's pause_i, and the link
-- sends `p` when the core has paused at a step boundary, with no bus cycle
-- open (nice_cpu's MICROARCH.md §6.1). A write of 0 to bit 4 makes it go
-- on. A write with bits 4 and 5 set to a paused core is a step: the link
-- drops pause_i for one cycle, the core runs one step, and pauses again.
-- The link holds the breakpoints, and passes them to the core, which
-- compares them and pauses on its own before the instruction at an enabled
-- one. Then the link raises pause_i, so that the stop is a pause as any
-- other, and sends `x` with the breakpoint's number instead of `p`. While
-- the core waits for that, it is paused as at any other pause.
-- Console bytes from the host reach the core's FIFO only while it runs
-- or is paused (DEBUG.md §1), and so do the keyboard's: while the core is
-- held or halted, a keyboard byte is taken and dropped.
-- Unlike a UART byte, a keyboard byte is not lost when the core's FIFO is
-- full: it waits until there is room. It is written only while the FIFO has
-- room for two bytes, and not in a cycle with a byte from the link, so a
-- byte that the link's free-space register allowed always finds room.
--
-- The core starts as the emulator does: the math unit, the performance
-- counters, and the timer are reset each time bit 0 of the control
-- register goes to 0. So, after a halt, the instruction counter holds the number
-- of steps that the emulator prints, unless the program starts the timer,
-- whose interrupts come after clock cycles here, not after steps. The cycle
-- counter and the timer's counter run only while the core runs, so they
-- stop at a halt and while the core is paused, as the emulator's do, and
-- run during a step. The
-- fetch statistics are cleared at the start too, and count only while the
-- core runs, as the counters do. A read of CYCLE_LO, INSTR_LO, or TIME_LO
-- by the link takes a snapshot, as one by the core does, where niceemu
-- takes none; DEBUG.md §3 allows both while the core is held, halted, or
-- paused, and a start resets them.
--
-- The data bus of the core is stalled while the link owns port B, and while a
-- write to the UART waits. A request of the link is stalled until no device
-- is busy or owes the core an acknowledge, and the MPU does not stall, and
-- is then served. Every request is acknowledged in the cycle after it is served.
-- A request of the core for the MPU, the performance counters, the fetch
-- statistics, or the timer goes to the device in the cycle it is taken, as
-- one for memory does, and the device acknowledges it. Each device
-- acknowledges in the cycle after it takes a request, except the MPU, which
-- takes a read of a result that it computes and then stalls until it
-- acknowledges it. The core is stalled meanwhile too, so its requests are
-- acknowledged in their order. A link request for a device is latched and
-- passed to the device, and it is acknowledged in the cycle after the
-- device's acknowledge.
--
-- A clear of the memory, which the link asks for with clear_o, writes 0 to
-- one word of the RAM and one of the screen in each cycle, 2^C_CLR_BITS
-- cycles in all, 0.66 ms at 100 MHz, and clears the screen's registers.
-- The link holds the core meanwhile, and makes no access.
--
-- RESET
-- Synchronous. After reset bit 0 of the control register is 1 when
-- G_CPU_RUN_AT_RESET is false, so the core waits for the host, and 0
-- otherwise, so the core boots from the ROM, which reset shows: rom_hidden is
-- cleared, or stays 1 in a build without a ROM. The link sends `b04`, and
-- clears the breakpoints. The
-- screen's registers, the read counter, and the board's writable registers
-- (LEDs, RGB levels, and display segments), which the clear keeps, are
-- cleared. The memory is not changed.

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
      -- The board has LEDs, a seven-segment display, buttons, and switches
      -- in 0xFFFFFF90-9F
      G_BOARD_IO         : boolean := false;
      -- The number of breakpoints of the debug link, 0 to 8 (DEBUG.md §6)
      G_BREAKS           : natural range 0 to C_BREAKS_MAX := 4;
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
      -- '1' while the core runs: not held, halted, or paused
      running_o      : out std_logic;
      -- The writes to the screen, by the core or the link: the word's offset
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
      scr_offs_o     : out std_logic_vector(G_SCR_ADDR_BITS - 1 downto 0);
      -- The board's devices (G_BOARD_IO): the LEDs, the two RGB LEDs'
      -- levels, the display's segments, and the buttons and switches, which
      -- are synchronized here. Without G_BOARD_IO the outputs are 0.
      brd_led_o      : out std_logic_vector(15 downto 0);
      brd_rgb0_o     : out std_logic_vector(11 downto 0);
      brd_rgb1_o     : out std_logic_vector(11 downto 0);
      brd_seg_o      : out std_logic_vector(63 downto 0);
      brd_btn_i      : in  std_logic_vector(4 downto 0)  := (others => '0');
      brd_sw_i       : in  std_logic_vector(15 downto 0) := (others => '0')
   );
end entity nicemon;

architecture synthesis of nicemon is

   -- The received bytes for the core. A power of two, so that the pointers
   -- wrap.
   constant C_RX_FIFO_BITS : natural := G_RX_FIFO_BITS;

   constant C_UART_DATA  : std_logic_vector(31 downto 0) := X"FFFFFF00";
   constant C_READ_COUNT : std_logic_vector(31 downto 0) := X"FFFFFF01";
   -- The screen: 0xFFFF0000 and the 2^G_SCR_ADDR_BITS words from it, of
   -- which the emulator's screen is the first 2000
   constant C_SCR_BITS : natural := G_SCR_ADDR_BITS;
   constant C_SCR_BASE : std_logic_vector(31 downto C_SCR_BITS) := (31 downto 16 => '1', others => '0');
   -- The screen's registers: 0xFFFFFF80-8F
   constant C_SCR_REGS_BASE : std_logic_vector(31 downto 4) := X"FFFFFF8";

   -- The board's devices: 0xFFFFFF90-9F
   constant C_BRD_BASE : std_logic_vector(31 downto 4) := X"FFFFFF9";

   -- The devices of nice_cpu/hdl/src, by the address bits above their offset
   constant C_TIMER_BASE : std_logic_vector(31 downto 4) := X"FFFFFF1";        -- 0xFFFFFF10-1F
   constant C_MPU_BASE   : std_logic_vector(31 downto 5) := X"FFFFFF" & "001"; -- 0xFFFFFF20-3F
   constant C_PERF_BASE  : std_logic_vector(31 downto 4) := X"FFFFFF4";        -- 0xFFFFFF40-4F
   constant C_FS_BASE    : std_logic_vector(31 downto 6) := X"FFFFFF" & "01";  -- 0xFFFFFF40-7F, less the above

   -- The clearing counts through the larger of the RAM and the screen.
   constant C_CLR_BITS : natural := maximum(G_RAM_ADDR_BITS, C_SCR_BITS);

   -- Whether an address is an I/O register, not memory. The words of
   -- 0xFFFFFF00-FF that are not registers are memory, as in the emulator.
   -- They land in the top 256 words of the RAM, which nothing else reaches.
   -- The link never puts its debug registers, 0xFFFFFFE0-FF, on the bus.
   function is_io(addr : std_logic_vector(31 downto 0)) return boolean is
   begin
      if and(addr(31 downto 8)) = '0' then
         return false;
      end if;
      return addr(7 downto 1) = "0000000" or                        -- console, read counter
             addr(7 downto 4) = X"1" or addr(7 downto 5) = "001" or -- timer, MPU
             addr(7 downto 6) = "01" or addr(7 downto 4) = X"8" or  -- perf, fetch statistics, screen registers
             addr(7 downto 4) = X"9";                               -- the board's devices
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
   signal cpu_rst    : std_logic;
   signal cpu_hold   : std_logic;
   signal cpu_halted : std_logic;
   signal cpu_why    : t_halt;
   -- The link's request of a pause, and the core's pause
   signal cpu_pause  : std_logic;
   signal cpu_paused : std_logic;
   -- The breakpoints, which the link holds and the core compares
   signal brk_addr    : t_brk_addrs;
   signal brk_en      : std_logic_vector(C_BREAKS_MAX - 1 downto 0);
   signal cpu_instret : std_logic;
   signal cpu_stats   : t_fetch_events;
   -- The core's registers, for the link, which keeps them at a halt, and
   -- the same as one vector, R(n) in bits 32 * n + 31 .. 32 * n
   signal cpu_regs      : t_regs;
   signal cpu_regs_flat : std_logic_vector(511 downto 0);
   -- '1' while the core is started and has not halted: it runs or is
   -- paused, and takes input
   signal cpu_started : std_logic;
   -- '1' while the core runs: started, and not paused. The counters, the
   -- timer, and the fetch statistics count only then.
   signal cpu_running : std_logic;
   -- The hold bit in the cycle before, for a pulse when the core starts,
   -- which resets the math unit, the performance counters, and the timer
   signal cpu_hold_d : std_logic := '1';
   signal dev_rst    : std_logic;
   -- The halt reason, the code of nice_cpu's DEBUG.md §6
   signal halt_reason : std_logic_vector(2 downto 0);

   -- Clearing the memory: the address, and a pulse for the link when it is
   -- done
   signal clearing : std_logic := '0';
   signal clr_addr : std_logic_vector(C_CLR_BITS - 1 downto 0);
   signal clr_done : std_logic := '0';
   -- The link's request for a clear, high until clr_done
   signal link_clear : std_logic;

   -- Bit 3 of the control register: the ROM is hidden, and the RAM is at 0
   signal rom_hidden : std_logic;

   -- The screen's registers: the state's bits 11..4, the cursor's column
   -- and row, and the display offset
   signal scr_state  : std_logic_vector(11 downto 4) := (others => '0');
   signal scr_cur_x  : std_logic_vector(6 downto 0) := (others => '0');
   signal scr_cur_y  : std_logic_vector(4 downto 0) := (others => '0');
   signal scr_offs   : std_logic_vector(C_SCR_BITS - 1 downto 0) := (others => '0');
   signal scr_ctl_we : std_logic := '0';

   -- The board's devices. The buttons and the switches are synchronized.
   signal brd_led  : std_logic_vector(15 downto 0) := (others => '0');
   signal brd_rgb0 : std_logic_vector(11 downto 0) := (others => '0');
   signal brd_rgb1 : std_logic_vector(11 downto 0) := (others => '0');
   signal brd_seg  : std_logic_vector(63 downto 0) := (others => '0');
   signal brd_btn  : std_logic_vector(4 downto 0)  := (others => '0');
   signal brd_sw   : std_logic_vector(15 downto 0) := (others => '0');
   signal btn_sync : std_logic_vector(4 downto 0)  := (others => '0');
   signal sw_sync  : std_logic_vector(15 downto 0) := (others => '0');
   attribute async_reg : string;
   attribute async_reg of btn_sync : signal is "TRUE";
   attribute async_reg of sw_sync  : signal is "TRUE";
   attribute async_reg of brd_btn  : signal is "TRUE";
   attribute async_reg of brd_sw   : signal is "TRUE";

   -- The number of the core's data reads of 0xFFFFFF01 since it was written
   signal read_count : std_logic_vector(31 downto 0) := (others => '0');

   signal ibus_cyc  : std_logic;
   signal ibus_stb  : std_logic;
   signal ibus_ack  : std_logic := '0';
   signal core_iack : std_logic;
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

   -- The link's Wishbone master. It owns port B while the core is held,
   -- halted, or paused, and its request is taken in a cycle with no stall.
   signal link_cyc   : std_logic;
   signal link_stb   : std_logic;
   signal link_stall : std_logic;
   signal link_ack   : std_logic := '0';
   signal link_we    : std_logic;
   signal link_addr  : std_logic_vector(31 downto 0);
   signal link_wdata : std_logic_vector(31 downto 0);
   signal link_owns  : std_logic;
   signal link_take  : std_logic;

   -- A core write to the UART that waits for the byte before it to go
   signal tx_wait      : std_logic := '0';
   signal tx_wait_data : std_logic_vector(7 downto 0);

   -- A link request for the MPU, the performance counters, or the timer. It
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

   -- The devices' ports: the link's latch while it is busy, else the core
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
   signal ser_rx_valid : std_logic;
   signal ser_rx_ready : std_logic;
   signal ser_rx_data  : std_logic_vector(7 downto 0);
   signal ser_rx_break : std_logic;
   signal ser_tx_valid : std_logic;
   signal ser_tx_ready : std_logic;
   signal ser_tx_data  : std_logic_vector(7 downto 0);

   -- The input: a console byte from the link, or a keyboard byte
   signal link_in_valid : std_logic;
   signal link_in_data  : std_logic_vector(7 downto 0);
   signal kbd_room      : std_logic;
   signal kbd_take      : std_logic;
   signal in_valid      : std_logic;
   signal in_data       : std_logic_vector(7 downto 0);
   -- The end of the input, from a break until the next start
   signal link_eoi : std_logic;

   -- The core's console output, to the link
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
   -- The free bytes of the FIFO
   signal rx_free : std_logic_vector(C_RX_FIFO_BITS downto 0);
   signal free    : std_logic_vector(15 downto 0);

begin

   assert C_SCR_BITS >= 11 and C_SCR_BITS <= 15
      report "nicemon: the screen must hold its 2000 words, below the I/O registers"
      severity failure;

   assert G_ROM_ADDR_BITS < G_RAM_ADDR_BITS
      report "nicemon: the ROM must leave room for RAM above it"
      severity failure;

   assert G_RX_FIFO_BITS <= 15
      report "nicemon: the free space of the input FIFO must fit in 16 bits"
      severity failure;

   ---------------------------------------------------------------------------
   -- The core
   ---------------------------------------------------------------------------

   cpu_rst <= rst_i or cpu_hold;

   i_core : entity work.nice_core
      generic map (
         G_BREAKS => G_BREAKS
      )
      port map (
         clk_i         => clk_i,
         rst_i         => cpu_rst,
         ibus_cyc_o    => ibus_cyc,
         ibus_stb_o    => ibus_stb,
         ibus_stall_i  => '0',
         ibus_ack_i    => core_iack,
         ibus_addr_o   => ibus_addr,
         ibus_data_i   => ibus_data,
         dbus_cyc_o    => dbus_cyc,
         dbus_stb_o    => dbus_stb,
         dbus_stall_i  => dbus_stall,
         dbus_ack_i    => dbus_ack,
         dbus_we_o     => dbus_we,
         dbus_addr_o   => dbus_addr,
         dbus_data_o   => dbus_wdata,
         dbus_data_i   => dbus_rdata,
         nmi_valid_i   => '0',
         nmi_ready_o   => open,
         nmi_vector_i  => X"00",
         irq_valid_i   => irq_valid,
         irq_ready_o   => irq_ready,
         irq_vector_i  => irq_vector,
         pause_i       => cpu_pause,
         paused_o      => cpu_paused,
         brk_addr_i    => brk_addr,
         brk_en_i      => brk_en,
         halted_o      => cpu_halted,
         halt_reason_o => cpu_why,
         instret_o     => cpu_instret,
         regs_o        => cpu_regs,
         retire_o      => open,
         stats_o       => cpu_stats
      ); -- i_core

   cpu_started <= not cpu_hold and not cpu_halted;
   cpu_running <= cpu_started and not cpu_paused;
   running_o   <= cpu_running;

   gen_regs : for n in 0 to 15 generate
      cpu_regs_flat(32 * n + 31 downto 32 * n) <= cpu_regs(n);
   end generate gen_regs;

   halt_reason <= halt_code(cpu_why);


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

   -- A hold resets the core with requests in flight. Their ACKs come while
   -- CYC is low, and are dropped, as Wishbone ignores them.
   core_iack <= ibus_ack and ibus_cyc;

   ibus_data <= (others => '0') when ibus_io = '1' else
                scr_a_data when ibus_scr = '1' else
                rom_a_data when ibus_rom = '1' else
                ram_a_data;


   ---------------------------------------------------------------------------
   -- Data bus and link: memory port B and the I/O registers
   ---------------------------------------------------------------------------

   -- The core's request is taken in a cycle with no stall. The MPU's stall
   -- holds the core while it computes a result that the core reads.
   dbus_stall <= link_owns or tx_wait or dev_busy or clearing or mpu_stall;
   dbus_ack   <= (srv_ack or (core_owed and dev_ack)) and dbus_cyc;

   -- The link owns port B while the core is held, halted, or paused. Its
   -- request waits while a device is busy, owes the core an acknowledge, or
   -- the MPU stalls, and is then taken.
   link_owns  <= cpu_hold or cpu_halted or cpu_paused;
   link_stall <= not link_owns or dev_busy or core_owed or mpu_stall or clearing;
   link_take  <= link_cyc and link_stb and not link_stall;

   -- A request of the core in reset is dropped: it is not taken, whatever it
   -- is, though the core's registered request may still show in the first
   -- cycle of a hold.
   core_take <= dbus_cyc and dbus_stb and not dbus_stall and not cpu_rst;
   core_dev  <= '1' when core_take = '1' and is_dev(dbus_addr) else
                '0';

   ram_b_addr  <= clr_addr(G_RAM_ADDR_BITS - 1 downto 0) when clearing = '1' else
                  link_addr(G_RAM_ADDR_BITS - 1 downto 0) when link_owns = '1' else
                  dbus_addr(G_RAM_ADDR_BITS - 1 downto 0);
   ram_b_wdata <= (others => '0') when clearing = '1' else
                  link_wdata when link_owns = '1' else
                  dbus_wdata;
   scr_b_addr  <= clr_addr(C_SCR_BITS - 1 downto 0) when clearing = '1' else
                  link_addr(C_SCR_BITS - 1 downto 0) when link_owns = '1' else
                  dbus_addr(C_SCR_BITS - 1 downto 0);

   -- A write to memory is served in the cycle that the link's or the core's
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
      elsif link_take = '1' then
         addr_v := link_addr;
         if not is_io(link_addr) then
            we_v := link_we;
         end if;
      elsif core_take = '1' then
         if not is_io(dbus_addr) then
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

   p_dbus : process (clk_i)

      -- Serve one request. link is true for the link's.
      procedure serve(link  : boolean;
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
         if not is_io(addr) then
            -- Memory: port B is driven combinationally above.
            if addr(31 downto C_SCR_BITS) = C_SCR_BASE then
               rd_scr <= '1';
            elsif rom_hidden = '0' and in_rom(addr) then
               rd_rom <= '1';
            else
               rd_ram <= '1';
            end if;
         elsif is_dev(addr) and not link then
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
            -- The link's: the device's port is driven from the latch, and the
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
         elsif addr = C_UART_DATA and we = '1' and not link then
            if cpu_tx_valid = '1' and cpu_tx_ready = '0' then
               -- The byte before still waits. The core may drop its request
               -- once it is taken, so the byte is kept until it can go.
               tx_wait      <= '1';
               tx_wait_data <= wdata(7 downto 0);
               return;
            end if;
            cpu_tx_data  <= wdata(7 downto 0);
            cpu_tx_valid <= '1';
         elsif addr = C_UART_DATA and link then
            -- A link read returns 0 and takes no byte, and a write is
            -- dropped (DEBUG.md §3).
            null;
         elsif addr = C_UART_DATA and we = '0' then
            if rx_empty = '0' then
               -- rx_take takes the byte, and it comes from rx_q in the next
               -- cycle.
               rd_rx <= '1';
            elsif rx_eof = '1' then
               rd_io(9) <= '1';
            end if;
         elsif addr = C_READ_COUNT and link then
            -- A link read returns 0 and does not count, and a write is
            -- dropped (DEBUG.md §3).
            null;
         elsif addr = C_READ_COUNT then
            -- As in the emulator: a write sets the count, and a read
            -- returns it and counts.
            if we = '1' then
               read_count <= wdata;
            else
               rd_io      <= read_count;
               read_count <= read_count + 1;
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
         elsif addr(31 downto 4) = C_BRD_BASE then
            -- The board's devices. Without them, and in the words that are
            -- not registers, a read is 0 and a write is dropped.
            if we = '1' and G_BOARD_IO then

               case addr(3 downto 0) is
                  when X"0"   => brd_led              <= wdata(15 downto 0);
                  when X"1"   => brd_rgb0             <= wdata(11 downto 0);
                  when X"2"   => brd_rgb1             <= wdata(11 downto 0);
                  when X"3"   => brd_seg(31 downto 0)  <= wdata;
                  when X"4"   => brd_seg(63 downto 32) <= wdata;
                  when others => null;
               end case;

            elsif G_BOARD_IO then

               case addr(3 downto 0) is
                  when X"0"   => rd_io(15 downto 0) <= brd_led;
                  when X"1"   => rd_io(11 downto 0) <= brd_rgb0;
                  when X"2"   => rd_io(11 downto 0) <= brd_rgb1;
                  when X"3"   => rd_io                <= brd_seg(31 downto 0);
                  when X"4"   => rd_io                <= brd_seg(63 downto 32);
                  when X"5"   => rd_io(4 downto 0)  <= brd_btn;
                  when X"6"   => rd_io(15 downto 0) <= brd_sw;
                  when others => null;
               end case;

            end if;
         end if;
         if link then
            link_ack <= '1';
         else
            srv_ack <= '1';
         end if;
      end procedure serve;

   begin
      if rising_edge(clk_i) then
         srv_ack    <= '0';
         link_ack   <= '0';
         clr_done   <= '0';
         scr_ctl_we <= '0';
         cpu_hold_d <= cpu_hold;

         if cpu_tx_valid = '1' and cpu_tx_ready = '1' then
            cpu_tx_valid <= '0';
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
               link_ack <= '1';
            end if;
         elsif clearing = '1' then
            clr_addr <= clr_addr + 1;
            if and(clr_addr) = '1' then
               clearing <= '0';
               clr_done <= '1';
            end if;
         elsif link_clear = '1' and clr_done = '0' then
            -- The link asks for a clear, with the core held: first the
            -- screen's registers, then every word of the memory.
            clearing   <= '1';
            clr_addr   <= (others => '0');
            scr_state  <= (others => '0');
            scr_cur_x  <= (others => '0');
            scr_cur_y  <= (others => '0');
            scr_offs   <= (others => '0');
            scr_ctl_we <= '1';
         elsif link_take = '1' then
            serve(true, link_addr, link_we, link_wdata);
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

         -- A request of the core in reset is dropped.
         if cpu_rst = '1' then
            srv_ack   <= '0';
            core_owed <= '0';
            tx_wait   <= '0';
         end if;

         if rst_i = '1' then
            dev_busy     <= '0';
            dev_stb      <= '0';
            link_ack     <= '0';
            clearing     <= '0';
            clr_done     <= '0';
            cpu_tx_valid <= '0';
            read_count   <= (others => '0');
            scr_state    <= (others => '0');
            scr_cur_x    <= (others => '0');
            scr_cur_y    <= (others => '0');
            scr_offs     <= (others => '0');
            scr_ctl_we   <= '1';
            brd_led      <= (others => '0');
            brd_rgb0     <= (others => '0');
            brd_rgb1     <= (others => '0');
            brd_seg      <= (others => '0');
         end if;
      end if;
   end process p_dbus;

   -- A byte for the core goes into its FIFO while the core runs or is
   -- paused. The FIFO
   -- drops it when it is full or the input has ended. A read of the console
   -- by the core takes the oldest byte, in the cycle that serves it: the
   -- cycle that accepts the request. The FIFO is in reset while the core is
   -- held, so a program starts with no input.
   rx_wr_en <= in_valid and cpu_started;
   rx_end   <= link_eoi;
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
         full_o    => open,
         free_o    => rx_free,
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
   -- reset while the core is held, so that the link can read them after a
   -- halt. The timer counts clock cycles while the core runs, and it is the only device that
   -- raises an interrupt, so its request goes straight to the core's IRQ.
   ---------------------------------------------------------------------------

   dev_rst <= rst_i or (cpu_hold_d and not cpu_hold);

   -- The link's latched request while it is busy, else the core's request,
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
      generic map (
         G_CLK_HZ => G_CLOCK_HZ
      )
      port map (
         clk_i      => clk_i,
         rst_i      => dev_rst,
         run_i      => cpu_running,
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
         run_i      => cpu_running,
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
         tick_i       => cpu_running,
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

   -- The screen, at 0xFFFF0000. It is memory, as in the emulator, so the link
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

   -- The buttons and the switches pass through two registers.
   p_brd_in : process (clk_i)
   begin
      if rising_edge(clk_i) then
         btn_sync <= brd_btn_i;
         brd_btn  <= btn_sync;
         sw_sync  <= brd_sw_i;
         brd_sw   <= sw_sync;
      end if;
   end process p_brd_in;

   brd_led_o  <= brd_led;
   brd_rgb0_o <= brd_rgb0;
   brd_rgb1_o <= brd_rgb1;
   brd_seg_o  <= brd_seg;

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
   -- UART and the debug link (DEBUG.md). The link sends the answers, the
   -- notices, and the core's console bytes, and passes the host's console
   -- bytes to the core's input while it runs.
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

   free <= (15 downto C_RX_FIFO_BITS + 1 => '0') & rx_free;

   i_debug_link : entity work.debug_link
      generic map (
         G_TIMEOUT   => G_CLOCK_HZ / 10,
         G_HAS_ROM   => G_ROM_FILE /= "",
         G_BOOT_HELD => not G_CPU_RUN_AT_RESET,
         G_BREAKS    => G_BREAKS
      )
      port map (
         clk_i          => clk_i,
         rst_i          => rst_i,
         rx_valid_i     => ser_rx_valid,
         rx_ready_o     => ser_rx_ready,
         rx_data_i      => ser_rx_data,
         rx_break_i     => ser_rx_break,
         tx_valid_o     => ser_tx_valid,
         tx_ready_i     => ser_tx_ready,
         tx_data_o      => ser_tx_data,
         con_valid_i    => cpu_tx_valid,
         con_ready_o    => cpu_tx_ready,
         con_data_i     => cpu_tx_data,
         con_in_valid_o => link_in_valid,
         con_in_data_o  => link_in_data,
         free_i         => free,
         eoi_o          => link_eoi,
         hold_o         => cpu_hold,
         rom_hide_o     => rom_hidden,
         clear_o        => link_clear,
         clear_done_i   => clr_done,
         halted_i       => cpu_halted,
         halt_reason_i  => halt_reason,
         pause_o        => cpu_pause,
         paused_i       => cpu_paused,
         regs_i         => cpu_regs_flat,
         brk_addr_o     => brk_addr,
         brk_en_o       => brk_en,
         wb_cyc_o       => link_cyc,
         wb_stb_o       => link_stb,
         wb_stall_i     => link_stall,
         wb_ack_i       => link_ack,
         wb_we_o        => link_we,
         wb_addr_o      => link_addr,
         wb_data_o      => link_wdata,
         wb_data_i      => dbus_rdata
      ); -- i_debug_link

   -- The input: a console byte from the link, or else a keyboard byte. While
   -- the core runs or is paused, a keyboard byte waits until the FIFO has
   -- room for two, so that a byte from the link, which the link sends only
   -- when the free space was not 0 a cycle earlier, finds room. Otherwise it
   -- is taken and dropped: while the core is held or halted, or after the
   -- end of the input.
   kbd_room <= '1' when rx_free >= 2 else
               '0';
   kbd_take <= kbd_valid_i and not link_in_valid and
               (not cpu_started or rx_eof or kbd_room);
   in_valid <= link_in_valid or kbd_take;
   in_data  <= link_in_data when link_in_valid = '1' else kbd_data_i;

   kbd_ready_o <= kbd_take;


   ---------------------------------------------------------------------------
   -- The checks of formal/nicemon.sby. The core's two buses are pipelined
   -- Wishbone, and nice_cpu's formal checks prove either core right for
   -- any slave that sends ACK only while CYC is high, and only for a
   -- request that waits. These check that this system is such a slave for
   -- the core and for the link, the devices included, that the link is
   -- served only while it owns port B, and that its reads and writes of the
   -- console and the read counter have no side effect (DEBUG.md §3).
   -- With a ROM, a read of it returns the ROM's word, and a write to it
   -- leaves the RAM under it, while the ROM is shown. The board's registers
   -- take the writes to their words and return their values, and the other
   -- words of 0xFFFFFF90-9F, or all of them without G_BOARD_IO, read 0 and
   -- change nothing.
   -- A request of the core waits from the cycle that accepts it until its
   -- ACK, or until the core is reset, which drops it. The pipelined core
   -- has several requests waiting on a bus, so f_ibus_wait and f_dbus_wait
   -- count them. The link has one request at a time.
   ---------------------------------------------------------------------------

   gen_formal : if G_FORMAL generate
      signal f_ibus_wait : natural range 0 to 15 := 0;
      signal f_dbus_wait : natural range 0 to 15 := 0;
      signal f_link_wait : std_logic := '0';
      signal f_rx_byte   : std_logic;
      signal f_rx_end    : std_logic;
      signal f_cpu_rst_d : std_logic := '1';
      -- A link access of the console or the read counter
      signal f_link_con : std_logic;
      -- The request served: the link's, or else the core's
      signal f_take  : std_logic;
      signal f_addr  : std_logic_vector(31 downto 0);
      signal f_we    : std_logic;
      signal f_wdata : std_logic_vector(31 downto 0);
      -- An access of the memory under the ROM, with the ROM shown or hidden
      signal f_rom   : std_logic;
      signal f_unrom : std_logic;
      -- An access of 0xFFFFFF90-9F, the board's writable registers, their
      -- values after the access, and the word that it reads
      signal f_brd      : std_logic;
      signal f_brd_regs : std_logic_vector(103 downto 0);
      signal f_brd_next : std_logic_vector(103 downto 0);
      signal f_brd_rd   : std_logic_vector(31 downto 0);
   begin

      p_wait : process (clk_i)
      begin
         if rising_edge(clk_i) then
            if ibus_cyc = '1' and ibus_stb = '1' and core_iack = '0' then
               f_ibus_wait <= f_ibus_wait + 1;
            elsif (ibus_cyc = '0' or ibus_stb = '0') and core_iack = '1' then
               f_ibus_wait <= f_ibus_wait - 1;
            end if;
            if dbus_cyc = '1' and dbus_stb = '1' and dbus_stall = '0' and dbus_ack = '0' then
               f_dbus_wait <= f_dbus_wait + 1;
            elsif (dbus_cyc = '0' or dbus_stb = '0' or dbus_stall = '1') and dbus_ack = '1' then
               f_dbus_wait <= f_dbus_wait - 1;
            end if;
            if link_take = '1' then
               f_link_wait <= '1';
            elsif link_ack = '1' then
               f_link_wait <= '0';
            end if;

            if cpu_rst = '1' then
               f_ibus_wait <= 0;
               f_dbus_wait <= 0;
            end if;
            if rst_i = '1' then
               f_link_wait <= '0';
            end if;
            f_cpu_rst_d <= cpu_rst;
         end if;
      end process p_wait;

      -- A read of the console by the core takes a byte, or finds the FIFO
      -- empty after the end of the input
      f_rx_byte <= rx_take and not rx_empty;
      f_rx_end  <= rx_take and rx_empty and rx_eof;

      f_link_con <= '1' when link_take = '1' and
                             (link_addr = C_UART_DATA or link_addr = C_READ_COUNT) else
                    '0';

      -- A link request is served before the core's, and they never come in
      -- the same cycle (f_link_take).
      f_take  <= link_take or core_take;
      f_addr  <= link_addr when link_take = '1' else
                 dbus_addr;
      f_we    <= link_we when link_take = '1' else
                 dbus_we;
      f_wdata <= link_wdata when link_take = '1' else
                 dbus_wdata;

      f_rom   <= '1' when f_take = '1' and not is_io(f_addr) and
                          f_addr(31 downto C_SCR_BITS) /= C_SCR_BASE and
                          in_rom(f_addr) and rom_hidden = '0' else
                 '0';
      f_unrom <= '1' when f_take = '1' and not is_io(f_addr) and
                          f_addr(31 downto C_SCR_BITS) /= C_SCR_BASE and
                          in_rom(f_addr) and rom_hidden = '1' else
                 '0';

      f_brd      <= '1' when f_take = '1' and f_addr(31 downto 4) = C_BRD_BASE else
                    '0';
      f_brd_regs <= brd_led & brd_rgb0 & brd_rgb1 & brd_seg;

      p_brd : process (all)
         variable led_v  : std_logic_vector(15 downto 0);
         variable rgb0_v : std_logic_vector(11 downto 0);
         variable rgb1_v : std_logic_vector(11 downto 0);
         variable seg_v  : std_logic_vector(63 downto 0);
      begin
         led_v    := brd_led;
         rgb0_v   := brd_rgb0;
         rgb1_v   := brd_rgb1;
         seg_v    := brd_seg;
         f_brd_rd <= (others => '0');
         if f_brd = '1' and G_BOARD_IO then
            if f_we = '1' then

               case f_addr(3 downto 0) is
                  when X"0"   => led_v  := f_wdata(15 downto 0);
                  when X"1"   => rgb0_v := f_wdata(11 downto 0);
                  when X"2"   => rgb1_v := f_wdata(11 downto 0);
                  when X"3"   => seg_v(31 downto 0)  := f_wdata;
                  when X"4"   => seg_v(63 downto 32) := f_wdata;
                  when others => null;
               end case;

            else

               case f_addr(3 downto 0) is
                  when X"0"   => f_brd_rd(15 downto 0) <= brd_led;
                  when X"1"   => f_brd_rd(11 downto 0) <= brd_rgb0;
                  when X"2"   => f_brd_rd(11 downto 0) <= brd_rgb1;
                  when X"3"   => f_brd_rd <= brd_seg(31 downto 0);
                  when X"4"   => f_brd_rd <= brd_seg(63 downto 32);
                  when X"5"   => f_brd_rd(4 downto 0)  <= brd_btn;
                  when X"6"   => f_brd_rd(15 downto 0) <= brd_sw;
                  when others => null;
               end case;

            end if;
         end if;
         f_brd_next <= led_v & rgb0_v & rgb1_v & seg_v;
      end process p_brd;

      -- psl default clock is rising_edge(clk_i);

      -- The core's buses
      -- psl f_ibus_ack : assert always
      --    rst_i = '0' and core_iack = '1' -> ibus_cyc = '1' and f_ibus_wait /= 0;
      -- psl f_dbus_ack : assert always
      --    rst_i = '0' and dbus_ack = '1' -> dbus_cyc = '1' and f_dbus_wait /= 0;

      -- The link's port: one ACK for each request, while CYC is high, and a
      -- request only while the link owns port B and makes no clear
      -- psl f_link_ack : assert always
      --    rst_i = '0' and link_ack = '1' -> link_cyc = '1' and f_link_wait = '1';
      -- psl f_link_take : assert always
      --    link_take = '1' -> link_owns = '1' and core_take = '0' and clearing = '0';
      -- psl f_link_one : assert always
      --    rst_i = '0' and link_take = '1' -> f_link_wait = '0';

      -- The link's read of the console or the read counter returns 0, and
      -- neither its read nor its write changes the input, the output, or
      -- the count. While the core is paused, a byte may come into the FIFO
      -- in the same cycle, which is not the link's doing.
      -- psl f_link_con_read : assert always
      --    {f_link_con and not link_we and not rst_i} |=>
      --    {rst_i = '1' or (link_ack = '1' and dbus_rdata = 0)};
      -- psl f_link_con_side : assert always
      --    {f_link_con and not rst_i} |=>
      --    {rst_i = '1' or (stable(read_count) and stable(cpu_tx_data) and
      --                     (stable(rx_empty) or prev(rx_wr_en) = '1'))};
      -- psl f_link_con_take : assert always f_link_con = '1' -> rx_take = '0';

      -- The devices answer the link's latched request, or a request of the
      -- core, which is dropped if the core has been reset. The core gets one
      -- acknowledge at a time.
      -- psl f_dev_ack : assert always
      --    rst_i = '0' and dev_ack = '1' ->
      --    dev_busy = '1' or core_owed = '1' or cpu_rst = '1' or f_cpu_rst_d = '1';
      -- psl f_one_ack : assert always
      --    rst_i = '0' -> not (srv_ack = '1' and core_owed = '1' and dev_ack = '1');

      -- The clear: the link hears that it is done only while it asks.
      -- psl f_clr_done : assert always rst_i = '0' and clr_done = '1' -> link_clear = '1';

      -- The console's answer: a byte with bit 8, 0x200 at the end, or 0
      -- psl f_console : assert always
      --    {rx_take and not rst_i} |=>
      --    {rst_i = '1' or cpu_rst = '1' or
      --     (dbus_ack = '1' and dbus_rdata(31 downto 10) = 0 and
      --      dbus_rdata(8) = prev(f_rx_byte) and dbus_rdata(9) = prev(f_rx_end))};

      -- The ROM: nothing writes the RAM under it but the clear. Without a
      -- ROM, rom_hidden is 1.
      -- psl f_rom_we : assert always
      --    rst_i = '0' and clearing = '0' and ram_b_we = '1' ->
      --    rom_hidden = '1' or or(ram_b_addr(G_RAM_ADDR_BITS - 1 downto G_ROM_ADDR_BITS)) = '1';

      -- The board's registers change only on a write to theirs, and a read
      -- of 0xFFFFFF90-9F returns the register, or 0.
      -- psl f_brd_we : assert always
      --    {not rst_i} |=> {rst_i = '1' or f_brd_regs = prev(f_brd_next)};
      -- psl f_brd_read : assert always
      --    {f_brd and not f_we and not rst_i} |=>
      --    {rst_i = '1' or ((link_ack or srv_ack) = '1' and dbus_rdata = prev(f_brd_rd))};

      -- psl c_console : cover {f_rx_byte and not rst_i};
      -- psl c_console_end : cover {f_rx_end and not rst_i};
      -- psl c_tx_wait : cover {tx_wait and not rst_i};
      -- psl c_dev_core : cover {core_dev and not rst_i and not cpu_rst; dbus_ack};
      -- psl c_dev_link : cover {dev_busy and not rst_i; link_ack};
      -- psl c_link_mem : cover {link_take and not link_we and not rst_i; link_ack};
      -- psl c_link_con : cover {f_link_con and not rst_i};
      -- psl c_link_paused : cover
      --    {link_take and cpu_paused and not cpu_hold and not cpu_halted and not rst_i; link_ack};
      -- psl c_clear : cover {clearing and not rst_i};

      gen_formal_rom : if G_ROM_FILE /= "" generate
      begin
         -- The ROM: a read returns its word. The covers here and in
         -- gen_formal_brd are unreachable without the ROM or the registers.
         -- psl f_rom_read : assert always
         --    {f_rom and not f_we and not rst_i} |=>
         --    {rst_i = '1' or ((link_ack or srv_ack) = '1' and dbus_rdata = rom_b_data)};
         -- psl c_rom_fetch : cover {ibus_rom and ibus_ack and not rst_i};
         -- psl c_rom_core : cover {f_rom and core_take and not f_we and not rst_i; srv_ack};
         -- psl c_rom_link : cover {f_rom and link_take and not f_we and not rst_i; link_ack};
         -- psl c_rom_write : cover {f_rom and f_we and not rst_i};
         -- psl c_rom_hidden : cover {f_unrom and not rst_i};
         -- psl c_rom_show : cover {rom_hidden and not rst_i; not rom_hidden and not rst_i};
      end generate gen_formal_rom;

      gen_formal_brd : if G_BOARD_IO generate
      begin
         -- psl c_brd_core : cover {f_brd and core_take and f_we and not rst_i};
         -- psl c_brd_link : cover {f_brd and link_take and not f_we and not rst_i; link_ack};
         -- psl c_brd_btn : cover {f_brd = '1' and f_we = '0' and f_addr(3 downto 0) = X"5" and
         --                        brd_btn /= "00000" and rst_i = '0'};
         -- psl c_brd_none : cover {f_brd = '1' and f_addr(3 downto 0) = X"F" and rst_i = '0'};
      end generate gen_formal_brd;

   end generate gen_formal;

end architecture synthesis;
