-- The NiceMon system: the NICE core, its memory and I/O, and the debug link
-- on the UART (PROTOCOL.md). It is the same for every board. The board's
-- top level gives it a clock, a reset, the UART pins, and optionally a
-- keyboard: a stream of bytes that is input like the UART's.
--
-- THEORY OF OPERATION
-- The core (nice_cpu/hdl/src/pipeline.vhd) has an instruction bus and a
-- data bus, both pipelined Wishbone. The instruction bus is 64 bits wide: it
-- reads an aligned pair of words from port A of the memory, the word at the
-- lower address in bits 31..0. The data bus shares port B with the debug
-- link (src/link.vhd), a second Wishbone master, which serves the host's
-- reads and writes.
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
--                          core is held is ignored. A read by the link
--                          returns 0 and takes nothing.
--   0xFFFFFF01             The read counter of the emulator: a read by the
--                          core returns the number of its reads since the
--                          last write, and a write sets that number. A read
--                          by the link does not count. It is 0 when the core
--                          starts.
--   0xFFFFFF10-0xFFFFFF1F  The timer of SYSTEM.md §4
--                          (nice_cpu/hdl/src/timer.vhd). It counts clock
--                          cycles, and its request goes to the core's IRQ.
--   0xFFFFFF20-0xFFFFFF3F  The math unit of SYSTEM.md §2
--                          (nice_cpu/hdl/src/mpu.vhd).
--   0xFFFFFF40-0xFFFFFF4F  The performance counters of SYSTEM.md §3
--                          (nice_cpu/hdl/src/perf.vhd).
--   0xFFFFFF50-0xFFFFFF5F  The screen's registers, numbered as QNICE-FPGA's
--                          VGA registers at 0xFF30, for the display: 50 is
--                          the state, with bit 6 showing the cursor, bit 5
--                          making it blink, bit 4 making it small, and bit
--                          10 enabling the display offset; 51 and 52 are
--                          the cursor's column and row; and 55 is the
--                          display offset, in words: the display shows the
--                          2000 words from it, so adding 80 scrolls a line.
--                          Bits 11..4 of the state are kept and read back;
--                          the other bits, and the words 53, 54, and 56-5F,
--                          read 0 and take no write. The registers go out on
--                          scr_cur_*_o and scr_offs_o, with scr_ctl_we_o
--                          for a cycle when one is written.
--   0xFFFFFFE0-0xFFFFFFEF  For the link only: R0-R15 of the core, read only,
--                          so that they can be read after HALT, as the
--                          emulator prints them.
--   0xFFFFFFF0             Control, for the link only. Bit 0 holds the core
--                          in reset while it is 1. A read returns bit 0, the
--                          core's halted flag in bit 1, bit 3, and the
--                          paused flag in bit 4. A write with bit
--                          2 set first clears the RAM, the screen included,
--                          to 0, as the emulator's memory is at the start,
--                          with the core held. Its answer comes when the memory
--                          is clear, and then bits 0 and 3 take effect. Bit
--                          3 hides the ROM: while it is 1 the RAM is at 0,
--                          as in the emulator, and the ROM is not reachable.
--                          In a build without a ROM it reads 1 and cannot
--                          be cleared.
--   0xFFFFFFF1             For the link only, read only: why the core halted,
--                          as the emulator's "Halted (...)" line says. 0
--                          while it has not halted, 1 for HALT, 2 for a
--                          reserved control word, 3 for INT inside an
--                          interrupt routine, and 4 for RTI outside one.
--   0xFFFFFFF2-0xFFFFFFFF  For the link only: run control, the trace, and
--                          the breakpoints (src/run_ctl.vhd, PROTOCOL.md).
-- Instruction fetches from 0xFFFFFF00-0xFFFFFFFF read 0 (ISA.md §8.3).
--
-- The core runs when the control bit is 0. The link splits the UART's input
-- into the console bytes for the core, at 0xFFFFFF00, and the host's
-- requests, and merges the core's console bytes with its answers. So the
-- host can read and write memory while the program runs. The keyboard's
-- bytes join the console bytes: nothing after the merge tells them apart. A
-- console byte from the UART goes first. Unlike a UART byte, a keyboard byte
-- is not lost when the core's FIFO is full: it waits until there is room.
-- Console bytes that arrive while the core is held are dropped.
--
-- run_ctl.vhd pauses the core between two steps with the core's pause
-- input, and holds off the timer's interrupt request meanwhile.
-- When the core stops, by a pause or a halt, and its last console byte has
-- gone to the link, the link sends a stop notice, so the host knows that
-- the program's output is complete.
--
-- The core starts as the emulator does: the read counter, the math unit,
-- the performance counters, and the timer are reset each time the control
-- bit goes to 0. So, after a halt, the instruction counter holds the number
-- of steps that the emulator prints, unless the program starts the timer,
-- whose interrupts come after clock cycles here, not after steps.
--
-- The data bus of the core is stalled while a link request waits, and while a
-- write to the UART waits. The link pulses STB for one cycle and does not
-- wait for STALL, so its request is latched and served in the next free
-- cycle. Every request is acknowledged in the cycle after it is served,
-- except one for the MPU, the performance counters, or the timer. That one
-- is latched and passed to the device, which may stall it (the MPU does
-- while it computes), and it is acknowledged in the cycle after the
-- device's acknowledge. The data bus is stalled meanwhile.
--
-- RESET
-- Synchronous. After reset the control bit is 1 when G_CPU_RUN_AT_RESET is
-- false, so the core waits for the link, and 0 otherwise, so the core boots
-- from the ROM, which reset shows. Memory and the screen's registers are not
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
      G_UART_BAUDRATE    : natural := 2_000_000;
      G_RAM_ADDR_BITS    : natural := 16;
      -- The screen has 2^G_SCR_ADDR_BITS words.
      G_SCR_ADDR_BITS    : natural := 15;
      -- The core's input FIFO has 2^G_RX_FIFO_BITS bytes.
      G_RX_FIFO_BITS     : natural := 11;
      -- The ROM: 2^G_ROM_ADDR_BITS words from the .bin file G_ROM_FILE, or
      -- none when the file name is empty
      G_ROM_FILE         : string  := "";
      G_ROM_ADDR_BITS    : natural := 15;
      -- The trace of run_ctl.vhd keeps 2^G_TRACE_BITS steps.
      G_TRACE_BITS       : natural := 10;
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
      -- '1' while the core runs: it is not held, halted, or paused
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
      scr_offs_o     : out std_logic_vector(G_SCR_ADDR_BITS - 1 downto 0)
   );
end entity nicemon;

architecture synthesis of nicemon is

   -- The received bytes for the core. A power of two, so that the pointers
   -- wrap.
   constant C_RX_FIFO_BITS : natural := G_RX_FIFO_BITS;

   constant C_UART_DATA  : std_logic_vector(31 downto 0) := X"FFFFFF00";
   constant C_READ_COUNT : std_logic_vector(31 downto 0) := X"FFFFFF01";
   constant C_CONTROL    : std_logic_vector(31 downto 0) := X"FFFFFFF0";
   constant C_HALT_WHY   : std_logic_vector(31 downto 0) := X"FFFFFFF1";
   -- The core's registers, for the link: 0xFFFFFFE0-EF
   constant C_REGS_BASE : std_logic_vector(31 downto 4) := X"FFFFFFE";
   -- The registers of run_ctl.vhd, for the link: 0xFFFFFFF2-FF
   constant C_DBG_BASE : std_logic_vector(31 downto 4) := X"FFFFFFF";
   -- The screen: 0xFFFF0000 and the 2^G_SCR_ADDR_BITS words from it, of
   -- which the emulator's screen is the first 2000
   constant C_SCR_BITS : natural := G_SCR_ADDR_BITS;
   constant C_SCR_BASE : std_logic_vector(31 downto C_SCR_BITS) := (31 downto 16 => '1', others => '0');
   -- The screen's registers: 0xFFFFFF50-5F
   constant C_SCR_REGS_BASE : std_logic_vector(31 downto 4) := X"FFFFFF5";

   -- The devices of nice_cpu/hdl/src, by the address bits above their offset
   constant C_TIMER_BASE : std_logic_vector(31 downto 4) := X"FFFFFF1";        -- 0xFFFFFF10-1F
   constant C_MPU_BASE   : std_logic_vector(31 downto 5) := X"FFFFFF" & "001"; -- 0xFFFFFF20-3F
   constant C_PERF_BASE  : std_logic_vector(31 downto 4) := X"FFFFFF4";        -- 0xFFFFFF40-4F

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
   -- lnk, for the link. The words of 0xFFFFFF00-FF that are not registers
   -- are memory, as in the emulator. They land in the top 256 words of the
   -- RAM, which nothing else reaches.
   function is_io(addr : std_logic_vector(31 downto 0); lnk : boolean) return boolean is
   begin
      if and(addr(31 downto 8)) = '0' then
         return false;
      end if;
      return addr(7 downto 1) = "0000000" or                        -- console, read counter
             addr(7 downto 4) = X"1" or addr(7 downto 5) = "001" or -- perf, MPU
             addr(7 downto 4) = X"4" or addr(7 downto 4) = X"5" or  -- timer, screen registers
             (lnk and addr(7 downto 5) = "111");
   end function is_io;

   -- Whether a memory address is in the ROM's range, which repeats with the
   -- RAM's
   function in_rom(addr : std_logic_vector(31 downto 0)) return boolean is
   begin
      return or(addr(G_RAM_ADDR_BITS - 1 downto G_ROM_ADDR_BITS)) = '0';
   end function in_rom;

   -- The devices of nice_cpu/hdl/src behind the latch of the data bus
   type t_dev is (DEV_PERF, DEV_MPU, DEV_TIMER);

   -- Core
   signal cpu_rst     : std_logic;
   signal cpu_hold    : std_logic;
   signal cpu_halted  : std_logic;
   signal cpu_instret : std_logic;
   signal cpu_retire  : t_retire;
   -- The hold bit in the cycle before, for a pulse when the core starts,
   -- which resets the math unit, the performance counters, and the timer
   signal cpu_hold_d : std_logic := '1';
   signal dev_rst    : std_logic;
   -- A stop, a halt or a pause, waits in stop_wait until the core's last
   -- byte has gone, and then stop_note tells the link.
   signal stopped_d : std_logic := '0';
   signal stop_wait : std_logic := '0';
   signal stop_note : std_logic := '0';
   -- The pipelined core reports the reason in the cycle the step retires,
   -- so it is kept here until the core is reset.
   signal halt_why : t_halt := HALT_NONE;

   -- Run control
   signal stopped     : std_logic;
   signal paused      : std_logic;
   signal stop_reason : std_logic_vector(7 downto 0);
   signal cpu_pause   : std_logic;
   signal cpu_paused  : std_logic;
   signal irq_mask    : std_logic;
   signal dbg_we      : std_logic := '0';
   signal dbg_re      : std_logic := '0';
   signal dbg_addr    : std_logic_vector(3 downto 0);
   signal dbg_wdata   : std_logic_vector(31 downto 0);
   signal dbg_rdata   : std_logic_vector(31 downto 0);

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
   signal dbus_ack   : std_logic := '0';
   signal dbus_we    : std_logic;
   signal dbus_addr  : std_logic_vector(31 downto 0);
   signal dbus_wdata : std_logic_vector(31 downto 0);
   signal dbus_rdata : std_logic_vector(31 downto 0);

   -- The link's requests on the data bus
   signal lnk_addr  : std_logic_vector(31 downto 0);
   signal lnk_wdata : std_logic_vector(31 downto 0);
   signal lnk_we    : std_logic;
   signal lnk_cyc   : std_logic;
   signal lnk_stb   : std_logic;
   signal lnk_ack   : std_logic := '0';

   -- The link request, latched until it is served
   signal lnk_pend    : std_logic := '0';
   signal lnk_p_addr  : std_logic_vector(31 downto 0);
   signal lnk_p_wdata : std_logic_vector(31 downto 0);
   signal lnk_p_we    : std_logic;

   -- A core write to the UART that waits for the byte before it to go
   signal tx_wait      : std_logic := '0';
   signal tx_wait_data : std_logic_vector(7 downto 0);

   -- A request for the MPU, the performance counters, or the timer. It is
   -- latched, and the device's port is driven from the latch until the
   -- device acknowledges.
   signal dev_busy  : std_logic := '0';
   signal dev_stb   : std_logic := '0';
   signal dev_sel   : t_dev;               -- the device
   signal dev_lnk   : boolean;             -- the request is the link's
   signal dev_drop  : std_logic;           -- the core was reset meanwhile
   signal dev_addr  : std_logic_vector(4 downto 0);
   signal dev_we    : std_logic;
   signal dev_wdata : std_logic_vector(31 downto 0);
   signal dev_stall : std_logic;

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
   signal timer_cyc   : std_logic;
   signal timer_stb   : std_logic;
   signal timer_stall : std_logic;
   signal timer_ack   : std_logic;
   signal timer_data  : std_logic_vector(31 downto 0);

   -- The timer's interrupt request, on the core's IRQ port, where it is
   -- held off while the core pauses
   signal irq_valid  : std_logic;
   signal cpu_irq    : std_logic;
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
   signal rd_dbg      : std_logic := '0';

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

   -- The input, from the UART or the keyboard
   signal kbd_take : std_logic;
   signal in_valid : std_logic;
   signal in_data  : std_logic_vector(7 downto 0);
   signal rx_full  : std_logic;

   -- The console bytes for the core, from the link
   signal con_valid : std_logic;
   signal con_data  : std_logic_vector(7 downto 0);

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

begin

   assert C_SCR_BITS >= 11 and C_SCR_BITS <= 16
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
         irq_valid_i  => cpu_irq,
         irq_ready_o  => irq_ready,
         irq_vector_i => irq_vector,
         pause_i      => cpu_pause,
         paused_o     => cpu_paused,
         halted_o     => cpu_halted,
         instret_o    => cpu_instret,
         retire_o     => cpu_retire
      ); -- i_core

   running_o <= not cpu_hold and not stopped;
   cpu_irq   <= irq_valid and not irq_mask;

   i_run_ctl : entity work.run_ctl
      generic map (
         G_TRACE_BITS    => G_TRACE_BITS,
         G_RAM_ADDR_BITS => G_RAM_ADDR_BITS
      )
      port map (
         clk_i         => clk_i,
         rst_i         => rst_i,
         cpu_rst_i     => cpu_rst,
         halted_i      => cpu_halted,
         core_paused_i => cpu_paused,
         retire_i      => cpu_retire,
         ibus_cyc_i    => ibus_cyc,
         ibus_stb_i    => ibus_stb,
         ibus_addr_i   => ibus_addr,
         dbus_cyc_i    => dbus_cyc,
         dbus_stb_i    => dbus_stb,
         dbus_we_i     => dbus_we,
         dbus_addr_i   => dbus_addr,
         pause_o       => cpu_pause,
         irq_mask_o    => irq_mask,
         paused_o      => paused,
         stopped_o     => stopped,
         reason_o      => stop_reason,
         reg_addr_i    => dbg_addr,
         reg_we_i      => dbg_we,
         reg_re_i      => dbg_re,
         reg_wdata_i   => dbg_wdata,
         reg_rdata_o   => dbg_rdata
      ); -- i_run_ctl


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
   -- Data bus and link: memory port B and the I/O registers
   ---------------------------------------------------------------------------

   -- The core's request is taken in a cycle with no stall.
   dbus_stall <= lnk_pend or tx_wait or dev_busy or clearing;

   ram_b_addr  <= clr_addr(G_RAM_ADDR_BITS - 1 downto 0) when clearing = '1' else
                  lnk_p_addr(G_RAM_ADDR_BITS - 1 downto 0) when lnk_pend = '1' else
                  dbus_addr(G_RAM_ADDR_BITS - 1 downto 0);
   ram_b_wdata <= (others => '0') when clearing = '1' else
                  lnk_p_wdata when lnk_pend = '1' else
                  dbus_wdata;
   scr_b_addr  <= clr_addr(C_SCR_BITS - 1 downto 0) when clearing = '1' else
                  lnk_p_addr(C_SCR_BITS - 1 downto 0) when lnk_pend = '1' else
                  dbus_addr(C_SCR_BITS - 1 downto 0);

   -- A write to memory is served in the cycle that the link's or the core's
   -- request is taken. It goes to the screen or to the main memory, unless
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
      elsif dev_busy = '0' and lnk_pend = '1' then
         addr_v := lnk_p_addr;
         if not is_io(lnk_p_addr, true) then
            we_v := lnk_p_we;
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
                 dbg_rdata when rd_dbg = '1' else
                 rd_io;


   p_dbus : process (clk_i)

      -- Serve one request. lnk is true for the link's.
      procedure serve(lnk   : boolean;
                      addr  : std_logic_vector(31 downto 0);
                      we    : std_logic;
                      wdata : std_logic_vector(31 downto 0)) is
      begin
         rd_ram <= '0';
         rd_rom <= '0';
         rd_scr <= '0';
         rd_rx  <= '0';
         rd_dbg <= '0';
         rd_io  <= (others => '0');
         if not is_io(addr, lnk) then
            -- Memory: port B is driven combinationally above.
            if addr(31 downto C_SCR_BITS) = C_SCR_BASE then
               rd_scr <= '1';
            elsif rom_hidden = '0' and in_rom(addr) then
               rd_rom <= '1';
            else
               rd_ram <= '1';
            end if;
         elsif addr(31 downto 5) = C_MPU_BASE or addr(31 downto 4) = C_PERF_BASE or
               addr(31 downto 4) = C_TIMER_BASE then
            -- A device: its port is driven from the latch, and the request
            -- is acknowledged when the device acknowledges it.
            dev_busy  <= '1';
            dev_stb   <= '1';
            if addr(31 downto 5) = C_MPU_BASE then
               dev_sel <= DEV_MPU;
            elsif addr(31 downto 4) = C_PERF_BASE then
               dev_sel <= DEV_PERF;
            else
               dev_sel <= DEV_TIMER;
            end if;
            dev_lnk   <= lnk;
            dev_drop  <= '0';
            dev_addr  <= addr(4 downto 0);
            dev_we    <= we;
            dev_wdata <= wdata;
            return;
         elsif addr = C_UART_DATA and we = '1' and not lnk then
            if cpu_tx_valid = '1' and cpu_tx_ready = '0' then
               -- The byte before still waits. The core may drop its request
               -- once it is taken, so the byte is kept until it can go.
               tx_wait      <= '1';
               tx_wait_data <= wdata(7 downto 0);
               return;
            end if;
            cpu_tx_data  <= wdata(7 downto 0);
            cpu_tx_valid <= '1';
         elsif addr = C_UART_DATA and we = '1' and lnk then
            -- The UART belongs to the link then, so the byte is dropped.
            null;
         elsif addr = C_UART_DATA and we = '0' and not lnk then
            if rx_empty = '0' then
               -- rx_take takes the byte, and it comes from rx_q in the next
               -- cycle.
               rd_rx <= '1';
            elsif rx_eof = '1' then
               rd_io(9) <= '1';
            end if;
         elsif addr = C_READ_COUNT then
            -- As in the emulator: a write sets the count, and a read by the
            -- core returns it and counts. A read by the link only returns it,
            -- as the emulator's --dump does.
            if we = '1' then
               read_count <= wdata;
            else
               rd_io <= read_count;
               if not lnk then
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
         elsif addr(31 downto 4) = C_REGS_BASE and lnk then
            if we = '0' then
               rd_io <= cpu_retire.regs(to_integer(addr(3 downto 0)));
            end if;
         elsif addr = C_CONTROL and lnk then
            if we = '1' and wdata(2) = '1' then
               -- Clear the memory with the core held. The request is
               -- acknowledged when the memory is clear.
               clearing   <= '1';
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
               rd_io(4) <= paused;
            end if;
         elsif addr = C_HALT_WHY and lnk then
            -- The reason is kept until the core is reset.
            if we = '0' then
               rd_io(2 downto 0) <= std_logic_vector(to_unsigned(t_halt'pos(halt_why), 3));
            end if;
         elsif addr(31 downto 4) = C_DBG_BASE and lnk then
            -- run_ctl.vhd's registers, which it reads in this cycle
            dbg_addr  <= addr(3 downto 0);
            dbg_we    <= we;
            dbg_re    <= not we;
            dbg_wdata <= wdata;
            rd_dbg    <= not we;
         end if;
         if lnk then
            lnk_ack <= '1';
         else
            dbus_ack <= '1';
         end if;
      end procedure serve;

   begin
      if rising_edge(clk_i) then
         dbus_ack     <= '0';
         lnk_ack      <= '0';
         stop_note    <= '0';
         scr_ctl_we   <= '0';
         dbg_we       <= '0';
         dbg_re       <= '0';
         cpu_hold_d   <= cpu_hold;
         stopped_d    <= stopped;

         if cpu_rst = '1' then
            halt_why <= HALT_NONE;
         elsif cpu_retire.halt /= HALT_NONE then
            halt_why <= cpu_retire.halt;
         end if;

         if cpu_tx_valid = '1' and cpu_tx_ready = '1' then
            cpu_tx_valid <= '0';
         end if;

         -- The link is told of a stop once the core's last byte has gone to
         -- it.
         if stopped = '1' and stopped_d = '0' then
            stop_wait <= '1';
         end if;
         if stop_wait = '1' and tx_wait = '0' and
            (cpu_tx_valid = '0' or cpu_tx_ready = '1') then
            stop_wait <= '0';
            stop_note <= '1';
         end if;

         if dev_busy = '1' then
            if dev_stb = '1' and dev_stall = '0' then
               dev_stb <= '0';
            end if;
            if mpu_ack = '1' or perf_ack = '1' or timer_ack = '1' then
               rd_ram   <= '0';
               rd_rom   <= '0';
               rd_scr   <= '0';
               rd_rx    <= '0';
               rd_dbg   <= '0';
               if mpu_ack = '1' then
                  rd_io <= mpu_data;
               elsif perf_ack = '1' then
                  rd_io <= perf_data;
               else
                  rd_io <= timer_data;
               end if;
               dev_busy <= '0';
               if dev_lnk then
                  lnk_ack <= '1';
               elsif dev_drop = '0' then
                  dbus_ack <= '1';
               end if;
            end if;
         elsif clearing = '1' then
            clr_addr <= clr_addr + 1;
            if and(clr_addr) = '1' then
               clearing <= '0';
               cpu_hold <= clr_hold;
               lnk_ack  <= '1';
            end if;
         elsif lnk_pend = '1' then
            serve(true, lnk_p_addr, lnk_p_we, lnk_p_wdata);
            lnk_pend <= '0';
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

         if lnk_cyc = '1' and lnk_stb = '1' then
            lnk_pend    <= '1';
            lnk_p_addr  <= lnk_addr;
            lnk_p_wdata <= lnk_wdata;
            lnk_p_we    <= lnk_we;
         end if;

         -- A request of the core in reset is dropped, and so is a byte
         -- received before, so that a program starts with no input.
         if cpu_rst = '1' then
            dbus_ack     <= '0';
            tx_wait      <= '0';
            stop_wait    <= '0';
            read_count   <= (others => '0');
            if not dev_lnk then
               dev_drop <= '1';
            end if;
         end if;

         if rst_i = '1' then
            dev_busy     <= '0';
            dev_stb      <= '0';
            lnk_pend     <= '0';
            lnk_ack      <= '0';
            clearing     <= '0';
            cpu_tx_valid <= '0';
            rom_hidden   <= C_NO_ROM;
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
   -- received before, so that a program starts with no input: the FIFO is
   -- held in reset with the core.
   rx_wr_en <= in_valid and not cpu_rst;
   rx_end   <= ser_rx_break and not cpu_rst;
   rx_take  <= '1' when dbus_cyc = '1' and dbus_stb = '1' and dbus_stall = '0' and
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
   -- reset while the link holds the core, so that the link can read them after
   -- a halt. The timer counts clock cycles, and it is the only device that
   -- raises an interrupt, so its request goes straight to the core's IRQ.
   ---------------------------------------------------------------------------

   dev_rst <= rst_i or (cpu_hold_d and not cpu_hold);

   mpu_cyc   <= dev_busy when dev_sel = DEV_MPU else '0';
   mpu_stb   <= dev_stb when dev_sel = DEV_MPU else '0';
   perf_cyc  <= dev_busy when dev_sel = DEV_PERF else '0';
   perf_stb  <= dev_stb when dev_sel = DEV_PERF else '0';
   timer_cyc <= dev_busy when dev_sel = DEV_TIMER else '0';
   timer_stb <= dev_stb when dev_sel = DEV_TIMER else '0';
   dev_stall <= mpu_stall when dev_sel = DEV_MPU else
                perf_stall when dev_sel = DEV_PERF else
                timer_stall;

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


   i_timer : entity work.timer
      port map (
         clk_i        => clk_i,
         rst_i        => dev_rst,
         tick_i       => '1',
         wb_cyc_i     => timer_cyc,
         wb_stb_i     => timer_stb,
         wb_stall_o   => timer_stall,
         wb_ack_o     => timer_ack,
         wb_we_i      => dev_we,
         wb_addr_i    => dev_addr(3 downto 0),
         wb_data_i    => dev_wdata,
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
   -- the writes given out here, and shows it as the registers say.
   scr_we_o       <= scr_b_we;
   scr_addr_o     <= scr_b_addr;
   scr_data_o     <= ram_b_wdata;
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
   -- UART and the debug link (src/link.vhd), which splits its input into the
   -- core's console bytes and the host's requests, and merges the core's
   -- console bytes with the link's answers
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

   i_link : entity work.link
      generic map (
         G_CLOCK_HZ => G_CLOCK_HZ
      )
      port map (
         clk_i          => clk_i,
         rst_i          => rst_i,
         ser_rx_valid_i => ser_rx_valid,
         ser_rx_ready_o => ser_rx_ready,
         ser_rx_data_i  => ser_rx_data,
         ser_tx_valid_o => ser_tx_valid,
         ser_tx_ready_i => ser_tx_ready,
         ser_tx_data_o  => ser_tx_data,
         con_rx_valid_o => con_valid,
         con_rx_data_o  => con_data,
         con_tx_valid_i => cpu_tx_valid,
         con_tx_ready_o => cpu_tx_ready,
         con_tx_data_i  => cpu_tx_data,
         stop_i         => stop_note,
         stop_reason_i  => stop_reason,
         wb_cyc_o       => lnk_cyc,
         wb_stb_o       => lnk_stb,
         wb_we_o        => lnk_we,
         wb_addr_o      => lnk_addr,
         wb_data_o      => lnk_wdata,
         wb_data_i      => dbus_rdata,
         wb_ack_i       => lnk_ack
      ); -- i_link

   -- The input: a console byte from the link, or else a keyboard byte, which
   -- is taken only when it has room, or dropped while the core is held.
   kbd_take <= kbd_valid_i and not con_valid and (cpu_rst or not rx_full);
   in_valid <= con_valid or kbd_take;
   in_data  <= con_data when con_valid = '1' else kbd_data_i;

   kbd_ready_o <= kbd_take;


   ---------------------------------------------------------------------------
   -- The checks of formal/nicemon.sby. The core's two buses are pipelined
   -- Wishbone, and nice_cpu's formal checks prove either core right for
   -- any slave that sends ACK only while CYC is high, and only for a
   -- request that waits. These check that this system is such a slave, the
   -- devices' request latch included. A request of the link takes some 160
   -- cycles of UART bytes, far more than the depth that the job can reach,
   -- so the link is checked on its own, in formal/link.sby. A request
   -- of the core waits from the cycle that accepts it until its ACK, or
   -- until the core is reset, which drops it. The instruction bus never
   -- stalls. The pipelined core has several requests waiting on a bus, so
   -- f_ibus_wait and f_dbus_wait count them.
   ---------------------------------------------------------------------------

   gen_formal : if G_FORMAL generate
      signal f_ibus_wait : natural range 0 to 15 := 0;
      signal f_dbus_wait : natural range 0 to 15 := 0;
      signal f_rx_byte   : std_logic;
      signal f_rx_end    : std_logic;
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

            if cpu_rst = '1' then
               f_ibus_wait <= 0;
               f_dbus_wait <= 0;
            end if;
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

      -- The devices answer only the latched request
      -- psl f_dev_ack : assert always
      --    rst_i = '0' and (mpu_ack = '1' or perf_ack = '1' or timer_ack = '1') ->
      --    dev_busy = '1';

      -- The console's answer: a byte with bit 8, 0x200 at the end, or 0
      -- psl f_console : assert always
      --    {rx_take and not rst_i} |=>
      --    {rst_i = '1' or cpu_rst = '1' or
      --     (dbus_ack = '1' and dbus_rdata(31 downto 10) = 0 and
      --      dbus_rdata(8) = prev(f_rx_byte) and dbus_rdata(9) = prev(f_rx_end))};

      -- psl c_console : cover {f_rx_byte and not rst_i};
      -- psl c_console_end : cover {f_rx_end and not rst_i};
      -- psl c_tx_wait : cover {tx_wait and not rst_i};
      -- psl c_dev_core : cover {dev_busy and not rst_i and not cpu_rst; dbus_ack};
      -- psl c_stop : cover {stop_note and not rst_i};
   end generate gen_formal;

end architecture synthesis;
