# The nice_cpu sources of the core that NICE selects, for sim/Makefile and
# synth/Makefile.inc, which set NICE_HDL to nice_cpu/hdl/src and REPO to
# this directory, both as seen from where they run.
#
#   NICE=pipeline   nice_cpu's pipelined core (the default)
#   NICE=multi      nice_cpu's multi-cycle core
#
# NICE_SOURCES lists what to analyze, in order: the core, nice_cpu's devices
# and its debug link, src/nice_core.vhd, and the architecture of it that
# picks the core.

NICE ?= pipeline

ifeq ($(wildcard $(NICE_HDL)/nice_pkg.vhd),)
ifneq ($(filter-out clean,$(or $(MAKECMDGOALS),all)),)
$(error $(NICE_HDL) is missing; run "git submodule update --init")
endif
endif

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
               $(addprefix $(NICE_HDL)/,mpu.vhd perf.vhd timer.vhd fetch_stats.vhd debug_link.vhd) \
               $(REPO)/src/nice_core.vhd $(REPO)/src/core/nice_core_$(NICE).vhd
