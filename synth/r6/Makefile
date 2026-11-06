include ../mega65/mega65.mk

BOARD_SRC = $(MEGA65_SRC) top.vhd
BOARD_XDC = $(MEGA65_XDC) r6.xdc
COR_TARGET = mega65r6

# With FLOW=timing, ExtraTimingOpt missed 100 MHz by 0.198 ns in the core's
# path from the RAM to its WRITE stage after issue #75; AltSpreadLogic_high
# met it by 0.015 ns, where ExtraNetDelay_high and ExtraPostPlacementOpt
# missed.
PLACE_TIMING = AltSpreadLogic_high

include ../Makefile.inc
