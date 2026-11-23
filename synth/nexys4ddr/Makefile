# The Digilent Nexys4DDR (Nexys A7-100T)
PART = xc7a100tcsg324-1

BOARD_SRC  = ../../src/kbd_ps2.vhd
BOARD_SRC += ../../src/kbd_ps2_ascii.vhd
BOARD_SRC += ../../src/kbd_ps2_toggle.vhd
BOARD_SRC += ../../src/seg7.vhd
BOARD_SRC += ../../src/rgb_pwm.vhd
BOARD_SRC += top.vhd
BOARD_XDC = nexys4ddr.xdc
SYNTH_XDC = nexys4ddr_synth.xdc
FLOW      = timing

# With FLOW=timing, ExtraTimingOpt missed 90 MHz by 0.010 ns on the path
# from the core's DBUS to the timer after issues #25 and #165;
# AltSpreadLogic_high met it by 0.001 ns.
PLACE_TIMING = AltSpreadLogic_high

include ../Makefile.inc
