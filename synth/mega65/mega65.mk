# What the MEGA65 boards share, for the Makefiles of r3/ and r6/: the part,
# the keyboard, the HDMI output, mega65.vhd, and mega65.xdc. A board's
# Makefile includes this file, adds its own sources and pins, and includes
# ../Makefile.inc.

PART = xc7a200tfbg484-2

MEGA65_SRC  = ../../src/kbd_m65.vhd
MEGA65_SRC += ../../src/kbd_m65_ascii.vhd
MEGA65_SRC += ../mega65/hdmi/types_pkg.vhd
MEGA65_SRC += ../mega65/hdmi/sync_reg.vhd
MEGA65_SRC += ../mega65/hdmi/hdmi_tx_encoder.vhd
MEGA65_SRC += ../mega65/hdmi/vga_to_hdmi.vhd
MEGA65_SRC += ../mega65/hdmi/serialiser_10to1_selectio.vhd
MEGA65_SRC += ../mega65/mega65.vhd

MEGA65_XDC = ../mega65/mega65.xdc
