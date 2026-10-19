# The nice_cpu sources of the core that NICE selects, for sim/Makefile and
# synth/Makefile.inc, which set NICE_HDL to nice_cpu/hdl/src and REPO to
# this directory, both as seen from where they run.
#
#   NICE=pipeline   nice_cpu's pipelined core (the default)
#   NICE=multi      nice_cpu's multi-cycle core
#
# NICE_SOURCES lists what to analyse, in order, including src/nice_core.vhd
# and the architecture of it that picks the core.

NICE ?= pipeline

NICE_COMMON = $(NICE_HDL)/nice_pkg.vhd $(NICE_HDL)/trace_pkg.vhd $(NICE_HDL)/pipe_pkg.vhd

ifeq ($(NICE),pipeline)
NICE_CORE = $(addprefix $(NICE_HDL)/,pipe_fetch.vhd pipe_decode.vhd pipe_prepare.vhd \
                                     pipe_dbus.vhd pipe_write.vhd pipeline.vhd)
else ifeq ($(NICE),multi)
NICE_CORE = $(NICE_HDL)/multicycle.vhd
else
$(error NICE must be pipeline or multi, not "$(NICE)")
endif

NICE_SOURCES = $(NICE_COMMON) $(NICE_CORE) \
               $(addprefix $(NICE_HDL)/,mpu.vhd perf.vhd timer.vhd wb_dmux.vhd) \
               $(REPO)/src/nice_core.vhd $(REPO)/src/core/nice_core_$(NICE).vhd
