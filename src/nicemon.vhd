-- The NiceMon system: the NICE core, its memory and I/O, and the debug link
-- of nice_cpu/doc/DEBUG.md on the UART. It is the same for every board. The
-- board's top level gives it a clock, a reset, the UART pins, and optionally
-- a keyboard: a stream of bytes that is input like the UART's.
--
-- Words used here (SYSTEM.md has them in full; DEBUG.md, ISA.md,
-- MICROARCH.md, and SYSTEM.md with a section number are nice_cpu's, in
-- nice_cpu/doc/):
--   link    nice_cpu's debug link, a second bus master that a host drives
--           with packets on the UART
--   held    bit 0 of the link's control register is 1: the core is in reset
--   start   bit 0 goes from 1 to 0: the devices reset, and the core runs
--   hidden  bit 3 is 1: the ROM is out of the way, and the RAM is at 0
--   paused  bit 4 is 1: the core stops between instructions
--   notice  a packet the link sends on its own: b05 at reset, h at a halt,
--           p at a pause, x at a breakpoint, and o for a lost input byte
--
-- THEORY OF OPERATION
-- The core (src/nice_core.vhd, wrapping one of nice_cpu's cores) has an
-- instruction bus and a data bus, both pipelined Wishbone. The instruction
-- bus is 64 bits wide: it reads an aligned pair of words from port A of the
-- memory (src/mem.vhd), the word at the lower address in bits 31..0. The
-- data bus shares port B of the memory and the I/O registers with the debug
-- link (nice_cpu/hdl/src/debug_link.vhd), a second Wishbone master. The link
-- shares the UART with the console: through it a host reads and writes the
-- memory, loads and starts a program, and learns when it halts. While
-- net_on_i is '1', the link's byte streams are those of the net_* ports
-- instead, a connection over TCP (eth/eth_tcp.vhd), and the UART's bytes
-- are dropped, and none is sent on it.
--
-- Address map, as in the emulator (nice_cpu/emulator/README.md), and the
-- same for the link and the core's data bus apart from the link's own
-- registers at the end:
--   0x00000000-0xFFFFFFFF  Memory (src/mem.vhd), where no register below
--                          is. It has 2^G_RAM_ADDR_BITS words and repeats
--                          through the address space, so the runtime's
--                          stack below 0xFFFFFF00 lands in the top of the
--                          memory, and so do the words of 0xFFFFFF00-FF
--                          that are not registers.
--   0x00000000-0x00007FFF  The ROM, 2^G_ROM_ADDR_BITS words from G_ROM_FILE
--                          (src/rom.vhd), which the core boots from, as
--                          QNICE-FPGA's monitor is at 0x0000-0x7FFF.
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
--   0xFFFF8000-0xFFFFFEFF  RAM, between the screen and the I/O page: with
--                          a screen of 2^15 words and a RAM of 2^16, as on
--                          the MEGA65, the RAM words 0x8000-0xFEFF. A
--                          smaller screen leaves more of them: with 2^13
--                          words, as on the Nexys4DDR, they start at
--                          0xFFFF2000. The runtime's stack starts at
--                          0xFFFFFF00 and grows down into them, and so does
--                          the stack of a program in the ROM.
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
--   0xFFFFFF10-0xFFFFFF7F  The devices of nice_cpu (src/devices.vhd):
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
--   0xFFFFFF80-0xFFFFFF8F  The screen's registers (src/scr_regs.vhd),
--                          numbered as QNICE-FPGA's VGA registers at
--                          0xFF30, for the display: 80 is the state, with
--                          bit 6 showing the cursor, bit 5 making it blink,
--                          bit 4 making it small, and bit 10 enabling the
--                          display offset; 81 and 82 are the cursor's
--                          column and row; and 85 is the display offset, in
--                          words: the display shows the 2000 words from it,
--                          so adding 80 scrolls a line.
--                          Bits 11..4 of the state are kept and read back;
--                          the other bits, and the words 83, 84, and 86-8F,
--                          read 0 and take no write. The registers go out on
--                          scr_cur_*_o and scr_offs_o, with scr_ctl_we_o
--                          for a cycle when one is written, and when they
--                          are cleared by reset or by the clear of the memory.
--   0xFFFFFF90-0xFFFFFF9F  The board's devices (src/board_io.vhd): 90-96
--                          with G_BOARD_IO (the Nexys4DDR), and 98-9D on every
--                          board. Without G_BOARD_IO, and in the words that
--                          are not registers, a read returns 0 and a write
--                          is dropped. Reset clears the writable ones, or
--                          sets them as 9A-9C say; a start of the core does
--                          not.
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
--     98  The good Ethernet frames received, eth_rx_i, a count that wraps
--         (system.vhd). Read only.
--     99  The bad or dropped Ethernet frames, eth_rx_bad_i, as 98.
--     9A  The Ethernet station's IP address, eth_ip_o, the first byte sent
--         in bits 31..24: 0xC0A80141 is 192.168.1.65. G_ETH_IP after
--         reset; 0 answers nothing. Read and write.
--     9B  The first two bytes of its MAC address, eth_mac_o(47 downto 32),
--         in bits 15..0. Read and write.
--     9C  The last four bytes of its MAC address, eth_mac_o(31 downto 0).
--         G_ETH_MAC after reset, 02:4E:49:43:45:00 by default. Read and
--         write.
--     9D  The Ethernet frames sent, eth_tx_i, as 98.
--   0xFFFFFFE0-0xFFFFFFFF  The debug registers of DEBUG.md §6, for the link
--                          only, which debug_link holds: R0-R15 of the core
--                          after a halt or at a pause, the control
--                          register, the halt reason (1 to 4 here), the
--                          version, 5 (DEBUG.md §6), the free space of the core's input
--                          FIFO, and the G_BREAKS breakpoints: their enable
--                          bits, their number, the stop register, and
--                          their addresses. The bits of the control
--                          register:
--                            0  hold the core in reset
--                            1  halted, read only
--                            2  clear the RAM, the RAM under the ROM and
--                               the screen included, to 0, as the
--                               emulator's memory is at the start
--                            3  hide the ROM; reads 1 in a build without
--                               a ROM
--                            4  pause the core
--                            5  step, with bit 4, a paused core
--                          The core's data accesses to these words go to
--                          the memory.
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
-- statistics, or the timer goes to src/devices.vhd in the cycle it is
-- taken, as one for memory does, and the device acknowledges it. The MPU
-- may stall until it does, which stalls the core and the link too, so the
-- core's requests are acknowledged in their order. A link request for a
-- device is latched there and passed to the device, and it is
-- acknowledged in the cycle after the device's acknowledge.
--
-- A clear of the memory, which the link asks for with clear_o, writes 0 to
-- one word of the RAM and one of the screen in each cycle, in src/mem.vhd,
-- 2^16 cycles in all on the boards, 0.66 ms at 100 MHz, and clears the
-- screen's registers.
-- The link holds the core meanwhile, and makes no access.
--
-- RESET
-- Synchronous. After reset bit 0 of the control register is 1 when
-- G_CPU_RUN_AT_RESET is false, so the core waits for the host, and 0
-- otherwise, so the core boots from the ROM, which reset shows: rom_hidden is
-- cleared, or stays 1 in a build without a ROM. The link sends `b05`, and
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
      -- The Ethernet station's MAC and IP addresses after reset (board_io.vhd)
      G_ETH_MAC          : std_logic_vector(47 downto 0) := X"024E49434500";
      G_ETH_IP           : std_logic_vector(31 downto 0) := X"00000000";
      -- The checks of formal/nicemon.sby; implies G_RAM_ANY of mem
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
      brd_sw_i       : in  std_logic_vector(15 downto 0) := (others => '0');
      -- The counts of Ethernet frames received, good and bad or dropped,
      -- and of those sent, and the station's addresses, on every board
      eth_rx_i       : in  std_logic_vector(31 downto 0) := (others => '0');
      eth_rx_bad_i   : in  std_logic_vector(31 downto 0) := (others => '0');
      eth_tx_i       : in  std_logic_vector(31 downto 0) := (others => '0');
      eth_mac_o      : out std_logic_vector(47 downto 0);
      eth_ip_o       : out std_logic_vector(31 downto 0);
      -- The link's byte streams over TCP, which take the UART's place
      -- while net_on_i is '1': the host's bytes and its half-close, a
      -- break, and the bytes to the host
      net_on_i       : in  std_logic                    := '0';
      net_rx_data_i  : in  std_logic_vector(7 downto 0) := X"00";
      net_rx_valid_i : in  std_logic                    := '0';
      net_rx_ready_o : out std_logic;
      net_rx_break_i : in  std_logic                    := '0';
      net_tx_data_o  : out std_logic_vector(7 downto 0);
      net_tx_valid_o : out std_logic;
      net_tx_ready_i : in  std_logic                    := '0'
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
   -- The screen's registers: 0xFFFFFF80-8F
   constant C_SCR_REGS_BASE : std_logic_vector(31 downto 4) := X"FFFFFF8";

   -- The board's devices: 0xFFFFFF90-9F
   constant C_BRD_BASE : std_logic_vector(31 downto 4) := X"FFFFFF9";

   -- The devices of nice_cpu/hdl/src, by the address bits above their offset
   constant C_TIMER_BASE : std_logic_vector(31 downto 4) := X"FFFFFF1";        -- 0xFFFFFF10-1F
   constant C_MPU_BASE   : std_logic_vector(31 downto 5) := X"FFFFFF" & "001"; -- 0xFFFFFF20-3F
   constant C_PERF_BASE  : std_logic_vector(31 downto 4) := X"FFFFFF4";        -- 0xFFFFFF40-4F
   constant C_FS_BASE    : std_logic_vector(31 downto 6) := X"FFFFFF" & "01";  -- 0xFFFFFF40-7F; is_fs drops 40-4F

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
             addr(7 downto 6) = "01" or                             -- perf, fetch statistics
             addr(7 downto 4) = X"8" or                             -- screen registers
             addr(7 downto 4) = X"9";                               -- the board's devices
   end function is_io;

   -- Whether an address is one of the fetch statistics', which are the
   -- words of 0xFFFFFF50-7F, after the performance counters at 40-4F
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

   -- The source of the read data of the last request served: the memory,
   -- the console's FIFO, the device that acknowledges the core, or else rd_io
   type t_src is (SRC_IO, SRC_MEM, SRC_RX, SRC_DEV);

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
   -- The halt reason, the code of nice_cpu's DEBUG.md §6
   signal halt_reason : std_logic_vector(2 downto 0);

   -- Clearing the memory (src/mem.vhd), and a pulse for the link when it
   -- is done
   signal clearing : std_logic;
   signal clr_done : std_logic;
   -- The link's request for a clear, high until clr_done, and the cycle
   -- that starts the clear
   signal link_clear : std_logic;
   signal clr_start  : std_logic;

   -- Bit 3 of the control register: the ROM is hidden, and the RAM is at 0
   signal rom_hidden : std_logic;

   -- The screen's registers (src/scr_regs.vhd): the request served, when
   -- it is to 0xFFFFFF80-8F, and the word it reads
   signal sreg_stb   : std_logic;
   signal sreg_rdata : std_logic_vector(31 downto 0);

   -- The board's devices (src/board_io.vhd): the request served, when it is
   -- to 0xFFFFFF90-9F, and the word it reads
   signal brd_stb   : std_logic;
   signal brd_rdata : std_logic_vector(31 downto 0);

   -- The number of the core's data reads of 0xFFFFFF01 since it was written
   signal read_count : std_logic_vector(31 downto 0) := (others => '0');

   signal ibus_cyc  : std_logic;
   signal ibus_stb  : std_logic;
   signal core_iack : std_logic;
   signal ibus_addr : std_logic_vector(30 downto 0);   -- the pair address
   signal ibus_data : std_logic_vector(63 downto 0);

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

   -- The devices (src/devices.vhd): the core's request for one, taken in
   -- this cycle, and the link's, their acknowledges, and the word of the
   -- device that acknowledges. The link's request waits while dev_busy is
   -- high, a device owes the core an acknowledge while core_owed is high,
   -- and dev_stall is the MPU's stall.
   signal core_take    : std_logic;
   signal core_dev     : std_logic;
   signal link_dev     : std_logic;
   signal dev_core_ack : std_logic;
   signal dev_link_ack : std_logic;
   signal dev_rdata    : std_logic_vector(31 downto 0);
   signal dev_busy     : std_logic;
   signal core_owed    : std_logic;
   signal dev_stall    : std_logic;

   -- The request served in this cycle: the link's while it owns port B, or
   -- else the core's
   signal bus_take  : std_logic;
   signal bus_addr  : std_logic_vector(31 downto 0);
   signal bus_we    : std_logic;
   signal bus_wdata : std_logic_vector(31 downto 0);

   -- The timer's interrupt request, on the core's IRQ port
   signal irq_valid  : std_logic;
   signal irq_ready  : std_logic;
   signal irq_vector : std_logic_vector(7 downto 0);

   -- The memory (src/mem.vhd): the request served, when it is to memory,
   -- and the word it reads
   signal mem_stb   : std_logic;
   signal mem_rdata : std_logic_vector(31 downto 0);

   -- The source of the read data of the last request, and the word of an
   -- I/O register
   signal rd_src : t_src := SRC_IO;
   signal rd_io  : std_logic_vector(31 downto 0);

   -- UART
   signal ser_rx_valid : std_logic;
   signal ser_rx_ready : std_logic;
   signal ser_rx_data  : std_logic_vector(7 downto 0);
   signal ser_rx_break : std_logic;
   signal ser_tx_valid : std_logic;
   signal ser_tx_ready : std_logic;
   signal ser_tx_data  : std_logic_vector(7 downto 0);
   -- The link's byte streams, from the UART or over TCP
   signal lnk_rx_valid : std_logic;
   signal lnk_rx_ready : std_logic;
   signal lnk_rx_data  : std_logic_vector(7 downto 0);
   signal lnk_rx_break : std_logic;
   signal lnk_tx_valid : std_logic;
   signal lnk_tx_ready : std_logic;
   signal lnk_tx_data  : std_logic_vector(7 downto 0);

   -- The input: a console byte from the link, or a keyboard byte
   signal link_in_valid : std_logic;
   signal link_in_data  : std_logic_vector(7 downto 0);
   signal kbd_room      : std_logic;
   signal kbd_take      : std_logic;
   signal in_valid      : std_logic;
   signal in_data       : std_logic_vector(7 downto 0);
   -- The end of the input, a break on the UART. The link gives it to the
   -- FIFO's end_i, which keeps it as rx_eof until the next start.
   signal link_eoi : std_logic;

   -- The core's console output, to the link
   signal cpu_tx_valid : std_logic := '0';
   signal cpu_tx_ready : std_logic;
   signal cpu_tx_data  : std_logic_vector(7 downto 0);
   -- The core's input FIFO (src/rx_fifo.vhd). rx_q holds the oldest byte in
   -- the cycle after a read of the console takes it.
   signal rx_wr_en : std_logic;
   signal rx_take  : std_logic;
   signal rx_empty : std_logic;
   signal rx_q     : std_logic_vector(7 downto 0);
   -- The core's input has ended with a break (link_eoi).
   signal rx_eof : std_logic;
   -- The free bytes of the FIFO
   signal rx_free : std_logic_vector(C_RX_FIFO_BITS downto 0);
   signal free    : std_logic_vector(15 downto 0);

begin

   assert C_SCR_BITS >= 11 and C_SCR_BITS <= 15
      report "nicemon: the screen must hold its 2000 words, below the I/O registers"
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
   -- Data bus and link: memory port B and the I/O registers
   ---------------------------------------------------------------------------

   -- The core's request is taken in a cycle with no stall. The MPU's stall
   -- holds the core while it computes a result that the core reads.
   dbus_stall <= link_owns or tx_wait or dev_busy or clearing or dev_stall;
   dbus_ack   <= (srv_ack or dev_core_ack) and dbus_cyc;

   -- The link owns port B while the core is held, halted, or paused. Its
   -- request waits while a device is busy, owes the core an acknowledge, or
   -- the MPU stalls, and is then taken.
   link_owns  <= cpu_hold or cpu_halted or cpu_paused;
   link_stall <= not link_owns or dev_busy or core_owed or dev_stall or clearing;
   link_take  <= link_cyc and link_stb and not link_stall;

   -- A request of the core in reset is dropped: it is not taken, whatever it
   -- is, though the core's registered request may still show in the first
   -- cycle of a hold.
   core_take <= dbus_cyc and dbus_stb and not dbus_stall and not cpu_rst;
   core_dev  <= '1' when core_take = '1' and is_dev(dbus_addr) else
                '0';
   link_dev  <= '1' when link_take = '1' and is_dev(link_addr) else
                '0';

   -- The link's and the core's requests are never taken in the same cycle
   -- (f_link_take), nor while the memory is cleared. The address is the
   -- link's while it owns port B, when the core's request is stalled, so it
   -- does not wait for the stall, and the memory's address does not either.
   bus_take  <= link_take or core_take;
   bus_addr  <= link_addr when link_owns = '1' else
                dbus_addr;
   bus_we    <= link_we when link_owns = '1' else
                dbus_we;
   bus_wdata <= link_wdata when link_owns = '1' else
                dbus_wdata;
   mem_stb   <= '1' when bus_take = '1' and not is_io(bus_addr) else
                '0';

   -- A console read returns the byte in bits 7..0 and bit 8 set (the header,
   -- 0xFFFFFF00).
   dbus_rdata <= mem_rdata when rd_src = SRC_MEM else
                 X"00000" & "0001" & rx_q when rd_src = SRC_RX else
                 dev_rdata when rd_src = SRC_DEV else
                 rd_io;

   p_dbus : process (clk_i)

      -- Serve one request. link is true for the link's.
      procedure serve(link  : boolean;
                      addr  : std_logic_vector(31 downto 0);
                      we    : std_logic;
                      wdata : std_logic_vector(31 downto 0)) is
      begin
         rd_src <= SRC_IO;
         rd_io  <= (others => '0');
         if not is_io(addr) then
            -- The memory has taken the request (mem_stb), and returns its
            -- word in the next cycle.
            rd_src <= SRC_MEM;
         elsif is_dev(addr) and not link then
            -- A device has taken the core's request (core_dev), and it
            -- acknowledges it, with its word.
            rd_src <= SRC_DEV;
            return;
         elsif is_dev(addr) then
            -- The devices have latched the link's request (link_dev), which
            -- is acknowledged when the device acknowledges it.
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
               rd_src <= SRC_RX;
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
            -- The screen's registers, which take a write themselves (sreg_stb)
            if we = '0' then
               rd_io <= sreg_rdata;
            end if;
         elsif addr(31 downto 4) = C_BRD_BASE then
            -- The board's devices, which take a write themselves (brd_stb)
            if we = '0' then
               rd_io <= brd_rdata;
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
         srv_ack  <= '0';
         link_ack <= '0';

         if cpu_tx_valid = '1' and cpu_tx_ready = '1' then
            cpu_tx_valid <= '0';
         end if;

         if dev_busy = '1' then
            if dev_link_ack = '1' then
               rd_src   <= SRC_IO;
               rd_io    <= dev_rdata;
               link_ack <= '1';
            end if;
         elsif clearing = '1' or clr_start = '1' then
            -- The link asks for a clear, with the core held: the screen's
            -- registers now (clr_start), then every word of the memory,
            -- which src/mem.vhd writes meanwhile.
            null;
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

         -- A request of the core in reset is dropped.
         if cpu_rst = '1' then
            srv_ack <= '0';
            tx_wait <= '0';
         end if;

         if rst_i = '1' then
            link_ack     <= '0';
            cpu_tx_valid <= '0';
            read_count   <= (others => '0');
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
         end_i     => link_eoi,
         ended_o   => rx_eof,
         rd_en_i   => rx_take,
         empty_o   => rx_empty,
         rd_data_o => rx_q
      ); -- i_rx_fifo


   ---------------------------------------------------------------------------
   -- The math unit (SYSTEM.md §2), the performance counters (§3), the
   -- fetch statistics, and the timer (§4) from nice_cpu, in
   -- src/devices.vhd. They are reset with the system, and when the core
   -- starts, as the emulator's are when it starts. The timer's request goes
   -- straight to the core's IRQ.
   ---------------------------------------------------------------------------

   i_devices : entity work.devices
      generic map (
         G_CLOCK_HZ => G_CLOCK_HZ
      )
      port map (
         clk_i        => clk_i,
         rst_i        => rst_i,
         hold_i       => cpu_hold,
         run_i        => cpu_running,
         instret_i    => cpu_instret,
         events_i     => cpu_stats,
         core_cyc_i   => dbus_cyc,
         core_stb_i   => core_dev,
         core_we_i    => dbus_we,
         core_addr_i  => dbus_addr(7 downto 0),
         core_wdata_i => dbus_wdata,
         core_ack_o   => dev_core_ack,
         link_stb_i   => link_dev,
         link_we_i    => link_we,
         link_addr_i  => link_addr(7 downto 0),
         link_wdata_i => link_wdata,
         link_ack_o   => dev_link_ack,
         rdata_o      => dev_rdata,
         busy_o       => dev_busy,
         owed_o       => core_owed,
         stall_o      => dev_stall,
         irq_valid_o  => irq_valid,
         irq_ready_i  => irq_ready,
         irq_vector_o => irq_vector
      ); -- i_devices

   -- The memory: the RAM, the ROM, and the screen, on the instruction bus
   -- and on port B, and the clear. A display keeps its own copy of the
   -- screen, from the writes given out on scr_*_o.
   i_mem : entity work.mem
      generic map (
         G_RAM_ADDR_BITS => G_RAM_ADDR_BITS,
         G_SCR_ADDR_BITS => C_SCR_BITS,
         G_ROM_FILE      => G_ROM_FILE,
         G_ROM_ADDR_BITS => G_ROM_ADDR_BITS,
         G_RAM_ANY       => G_FORMAL
      )
      port map (
         clk_i        => clk_i,
         rst_i        => rst_i,
         rom_hidden_i => rom_hidden,
         core_rst_i   => cpu_rst,
         ibus_cyc_i   => ibus_cyc,
         ibus_stb_i   => ibus_stb,
         ibus_addr_i  => ibus_addr,
         ibus_ack_o   => core_iack,
         ibus_data_o  => ibus_data,
         stb_i        => mem_stb,
         we_i         => bus_we,
         addr_i       => bus_addr,
         wdata_i      => bus_wdata,
         rdata_o      => mem_rdata,
         clear_i      => clr_start,
         clearing_o   => clearing,
         clear_done_o => clr_done,
         scr_we_o     => scr_we_o,
         scr_addr_o   => scr_addr_o,
         scr_data_o   => scr_data_o
      ); -- i_mem

   -- The board's devices, which take the request served, when it is theirs
   brd_stb <= '1' when bus_take = '1' and bus_addr(31 downto 4) = C_BRD_BASE else
              '0';

   i_board_io : entity work.board_io
      generic map (
         G_BOARD_IO => G_BOARD_IO,
         G_ETH_MAC  => G_ETH_MAC,
         G_ETH_IP   => G_ETH_IP
      )
      port map (
         clk_i        => clk_i,
         rst_i        => rst_i,
         stb_i        => brd_stb,
         we_i         => bus_we,
         addr_i       => bus_addr(3 downto 0),
         wdata_i      => bus_wdata,
         rdata_o      => brd_rdata,
         led_o        => brd_led_o,
         rgb0_o       => brd_rgb0_o,
         rgb1_o       => brd_rgb1_o,
         seg_o        => brd_seg_o,
         btn_i        => brd_btn_i,
         sw_i         => brd_sw_i,
         eth_rx_i     => eth_rx_i,
         eth_rx_bad_i => eth_rx_bad_i,
         eth_tx_i     => eth_tx_i,
         eth_mac_o    => eth_mac_o,
         eth_ip_o     => eth_ip_o
      ); -- i_board_io

   -- The screen's registers, which take the request served, when it is
   -- theirs, and are cleared at the start of a clear of the memory. The
   -- link makes no request while it asks for a clear (contract f of
   -- debug_link.vhd), and the core is held, so a clear never meets a
   -- request (f_clr_alone).
   sreg_stb  <= '1' when bus_take = '1' and bus_addr(31 downto 4) = C_SCR_REGS_BASE else
                '0';
   clr_start <= link_clear and not clr_done and not clearing and not dev_busy;

   i_scr_regs : entity work.scr_regs
      generic map (
         G_SCR_ADDR_BITS => C_SCR_BITS
      )
      port map (
         clk_i      => clk_i,
         rst_i      => rst_i,
         clear_i    => clr_start,
         stb_i      => sreg_stb,
         we_i       => bus_we,
         addr_i     => bus_addr(3 downto 0),
         wdata_i    => bus_wdata,
         rdata_o    => sreg_rdata,
         ctl_we_o   => scr_ctl_we_o,
         cur_x_o    => scr_cur_x_o,
         cur_y_o    => scr_cur_y_o,
         cur_mode_o => scr_cur_mode_o,
         offs_o     => scr_offs_o
      ); -- i_scr_regs


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

   -- The link's bytes go to the UART, or to the TCP connection while there
   -- is one; the other's are dropped.
   lnk_rx_valid   <= net_rx_valid_i when net_on_i = '1' else
                     ser_rx_valid;
   lnk_rx_data    <= net_rx_data_i when net_on_i = '1' else
                     ser_rx_data;
   lnk_rx_break   <= net_rx_break_i when net_on_i = '1' else
                     ser_rx_break;
   ser_rx_ready   <= lnk_rx_ready or net_on_i;
   net_rx_ready_o <= lnk_rx_ready or not net_on_i;
   ser_tx_data    <= lnk_tx_data;
   net_tx_data_o  <= lnk_tx_data;
   ser_tx_valid   <= lnk_tx_valid and not net_on_i;
   net_tx_valid_o <= lnk_tx_valid and net_on_i;
   lnk_tx_ready   <= net_tx_ready_i when net_on_i = '1' else
                     ser_tx_ready;

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
         rx_valid_i     => lnk_rx_valid,
         rx_ready_o     => lnk_rx_ready,
         rx_data_i      => lnk_rx_data,
         rx_break_i     => lnk_rx_break,
         tx_valid_o     => lnk_tx_valid,
         tx_ready_i     => lnk_tx_ready,
         tx_data_o      => lnk_tx_data,
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
   -- A read of memory, 0xFFFFFF80-8F, or 0xFFFFFF90-9F returns the word of
   -- src/mem.vhd, src/scr_regs.vhd, or src/board_io.vhd, whose own checks,
   -- in formal/mem.sby, formal/scr_regs.sby, and formal/board_io.sby,
   -- prove those words right.
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
      -- A link access of the console or the read counter
      signal f_link_con : std_logic;
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
         end if;
      end process p_wait;

      -- A read of the console by the core takes a byte, or finds the FIFO
      -- empty after the end of the input
      f_rx_byte <= rx_take and not rx_empty;
      f_rx_end  <= rx_take and rx_empty and rx_eof;

      f_link_con <= '1' when link_take = '1' and
                             (link_addr = C_UART_DATA or link_addr = C_READ_COUNT) else
                    '0';

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

      -- The request served is that of the master that owns port B, whose
      -- address bus_addr and the memory take.
      -- psl f_bus_owner : assert always
      --    bus_take = '1' -> (link_take = '1') = (link_owns = '1');

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

      -- The core gets one acknowledge at a time, from here or from a
      -- device, whose own checks, in formal/devices.sby, prove that each
      -- answers a request.
      -- psl f_one_ack : assert always
      --    rst_i = '0' -> not (srv_ack = '1' and dev_core_ack = '1');

      -- The clear: the link hears that it is done only while it asks.
      -- psl f_clr_done : assert always rst_i = '0' and clr_done = '1' -> link_clear = '1';
      -- psl f_clr_alone : assert always clr_start = '1' -> bus_take = '0';

      -- The console's answer: a byte with bit 8, 0x200 at the end, or 0
      -- psl f_console : assert always
      --    {rx_take and not rst_i} |=>
      --    {rst_i = '1' or cpu_rst = '1' or
      --     (dbus_ack = '1' and dbus_rdata(31 downto 10) = 0 and
      --      dbus_rdata(8) = prev(f_rx_byte) and dbus_rdata(9) = prev(f_rx_end))};

      -- A read of memory, 0xFFFFFF80-8F, or 0xFFFFFF90-9F returns the word
      -- of the memory, the screen's registers, or the board's, which
      -- formal/mem.sby, formal/scr_regs.sby, and formal/board_io.sby prove
      -- right. The memory's word comes in the cycle after the request.
      -- psl f_mem_read : assert always
      --    {mem_stb and not bus_we and not rst_i} |=>
      --    {rst_i = '1' or ((link_ack or srv_ack) = '1' and dbus_rdata = mem_rdata)};
      -- psl f_sreg_read : assert always
      --    {sreg_stb and not bus_we and not rst_i} |=>
      --    {rst_i = '1' or ((link_ack or srv_ack) = '1' and dbus_rdata = prev(sreg_rdata))};
      -- psl f_brd_read : assert always
      --    {brd_stb and not bus_we and not rst_i} |=>
      --    {rst_i = '1' or ((link_ack or srv_ack) = '1' and dbus_rdata = prev(brd_rdata))};

      -- psl c_console : cover {f_rx_byte and not rst_i};
      -- psl c_console_end : cover {f_rx_end and not rst_i};
      -- psl c_tx_wait : cover {tx_wait and not rst_i};
      -- psl c_dev_core : cover {core_dev and not rst_i and not cpu_rst; dbus_ack};
      -- psl c_dev_link : cover {dev_busy and not rst_i; link_ack};
      -- psl c_core_mem : cover {mem_stb and core_take and not bus_we and not rst_i; srv_ack};
      -- psl c_link_mem : cover {link_take and not link_we and not rst_i; link_ack};
      -- psl c_link_con : cover {f_link_con and not rst_i};
      -- psl c_link_paused : cover
      --    {link_take and cpu_paused and not cpu_hold and not cpu_halted and not rst_i; link_ack};
      -- psl c_clear : cover {clearing and not rst_i};

      gen_formal_rom : if G_ROM_FILE /= "" generate
      begin
         -- The link shows the ROM. The covers here and in gen_formal_brd
         -- are unreachable without the ROM or the registers.
         -- psl c_rom_show : cover {rom_hidden and not rst_i; not rom_hidden and not rst_i};
      end generate gen_formal_rom;

      gen_formal_brd : if G_BOARD_IO generate
      begin
         -- psl c_brd_core : cover {brd_stb and core_take and bus_we and not rst_i};
         -- psl c_brd_link : cover {brd_stb and link_take and not bus_we and not rst_i; link_ack};
         -- psl c_brd_btn : cover {brd_stb = '1' and bus_we = '0' and bus_addr(3 downto 0) = X"5" and
         --                        brd_rdata /= 0 and rst_i = '0'};
         -- psl c_brd_none : cover {brd_stb = '1' and bus_addr(3 downto 0) = X"F" and rst_i = '0'};
      end generate gen_formal_brd;

   end generate gen_formal;

end architecture synthesis;
