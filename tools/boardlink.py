#!/usr/bin/env python3
"""The debug link of nice_cpu/doc/DEBUG.md, with the board's transports.

nice_cpu's debugger/nicelink.py is the link: the packets, the debug
registers, the requests, the notices, and the transports to niceemu
--link over TCP (Tcp) and to a UART (Serial). This module passes on what the
tools use of it, and adds what is the board's own: its debug link over TCP on its
Ethernet port (Eth), the simulated system of make -C sim cosim (Cosim),
the registers of the board's baud rate and network station, and the
options --eth and --cosim. The tools import the link from here, which
puts nice_cpu's debugger/ on the path, so that nicebin.py and nicedbg.py
find nicelink.py there too.

The simulation runs far slower than real time, so a request there waits
COSIM_WAIT for its answer, and COSIM_BYTE more for each byte that it
sends. Over Ethernet and in the simulation, a half-close of the TCP
connection is the break that ends the program's input.

Only the Python standard library is used, so this runs on Linux and macOS.
"""

import argparse
import os
import socket
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), "nice_cpu", "debugger"))
import nicelink  # noqa: E402
from nicelink import (BRK_ADDR, BRK_COUNT, BRK_EN, CLEAR,  # noqa: E402
                      CONTROL, DEFAULT_BAUD, FREE, FULL_WAIT, HALT_REASON,
                      HALTED, HOLD, PAUSE, RAM, REASONS, REGS, STEP, STOP,
                      VERSION, WCH_ADDR, WCH_COUNT, WCH_EN, WCH_PC,
                      WCH_READ, WCH_WRITE, Link, LinkError, Serial, Tcp,
                      check_version, fail, packet, parse_tcp, read_words)

# What the tools import from here: nice_cpu's link, and the board's own
__all__ = [
    "BRK_ADDR", "BRK_COUNT", "BRK_EN", "CLEAR", "CONTROL", "DEFAULT_BAUD",
    "FREE", "FULL_WAIT", "HALT_REASON", "HALTED", "HOLD", "PAUSE", "RAM", "REASONS",
    "REGS", "STEP", "STOP", "VERSION", "WCH_ADDR", "WCH_COUNT", "WCH_EN",
    "WCH_PC", "WCH_READ", "WCH_WRITE", "Link", "LinkError", "Serial", "Tcp",
    "check_version", "fail", "packet", "parse_tcp", "read_words",
    "BAUD", "BAUDS", "COSIM_BYTE", "COSIM_WAIT", "Cosim",
    "DEBUG_FIRST", "ETH_PORT", "Eth", "NET_IP", "NET_RX_GOOD", "NET_STATUS",
    "NET_TX", "add_arguments", "open_link",
]

# The first of the debug registers, which only the link reaches (link
# version 7; 0xFFFFFFE0 before it)
DEBUG_FIRST = 0xFFFFFFD0
# The board's UART baud rate in bit/s, 230400 after reset, nice_cpu's
# DEFAULT_BAUD, and the rates it takes (doc/SYSTEM.md); niceemu has plain
# memory there
BAUD = 0xFFFFFF9F
BAUDS = (115200, 230400, 460800, 921600, 1000000, 1500000, 2000000)
# The network station of nice_cpu's SYSTEM.md §6: the IP address, the
# counts of the good frames received and of those sent, and NET_STATUS,
# bit 31 for a host connected over TCP and the link's port in bits 15..0
NET_IP = 0xFFFFFFB0
NET_RX_GOOD = 0xFFFFFFB3
NET_TX = 0xFFFFFFB5
NET_STATUS = 0xFFFFFFB6

# The simulation takes about 4 ms of real time for each byte on its UART,
# and clears the memory, its 64K words of RAM and the screen's 32K side by
# side, a word of each a cycle, in a few seconds. These leave room for a
# slower computer.
COSIM_WAIT = 20.0
COSIM_BYTE = 0.02
# The TCP port of the board's debug link on Ethernet (src/eth/eth_tcp.vhd)
ETH_PORT = 4510


class Cosim(Tcp):
    """The simulated system of make -C sim cosim, its UART on a port of
    127.0.0.1 (sim/cosim/cosim.c). The connection is the line, as a USB
    serial adapter is: it sends no b notice, and resets nothing. A
    half-close is a break. The simulation takes a new connection once the
    old one has half-closed, and then closes the old one, so the new one is
    taken as it is."""

    board = True
    peer = "the simulation"

    def hint(self, e: OSError) -> str:
        return f"is make cosim running on port {self.port}?"

    def _reconnect(self) -> socket.socket:
        return self._connect()

    def answer_wait(self, sent: int) -> float:
        return COSIM_WAIT + sent * COSIM_BYTE


class Eth(Tcp):
    """The board's debug link on its Ethernet port, a TCP port of the IP
    address that a program or the link gave it (doc/SYSTEM.md). The
    connection is the line, as for Cosim: no b notice, nothing reset, and a
    half-close is a break. The board takes a new connection from the same
    host once it has closed the old one, after the output that came before,
    so the new one is taken as it is, and the old one is read to its end
    first."""

    board = True
    peer = "the board"

    def hint(self, e: OSError) -> str:
        # The board refuses a connection only while another host has one.
        if isinstance(e, ConnectionRefusedError):
            return "another host has a connection to the board"
        return f"has the board this IP address (0x{NET_IP:08X})?"

    def _connect(self) -> socket.socket:
        sock = super()._connect()
        # A close sends a reset, not a FIN, also when the tool exits or is
        # killed, as the board takes a FIN for a half-close, the end of the
        # input, and keeps the connection, and the UART has no link while
        # it does.
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                        struct.pack("ii", 1, 0))
        return sock

    def _reconnect(self) -> socket.socket:
        return self._connect()


def add_arguments(parser: argparse.ArgumentParser
                  ) -> argparse._MutuallyExclusiveGroup:
    """The options that pick the link: nice_cpu's --tcp for niceemu --link,
    and --port and --baud for the board's debug UART, with --eth for its
    Ethernet port, and --cosim for make -C sim cosim. One of --eth, --port,
    --tcp, and --cosim must be given. --baud is 230400 by default, the
    board's rate after reset."""
    line = nicelink.add_arguments(parser)
    line.add_argument("--eth", metavar="HOST[:PORT]",
                      help="talk to the board over TCP on its Ethernet "
                      "port, at HOST, a name or an IPv4 address (default "
                      f"port {ETH_PORT}), not on its UART")
    line.add_argument("--cosim", type=int, metavar="PORT",
                      help="talk to the simulated system of make -C sim "
                      "cosim on port PORT of 127.0.0.1, not to the board; "
                      "slow, about 250 UART bytes a second")
    return line


def open_link(args: argparse.Namespace) -> Link:
    """The link that the options of add_arguments pick, after a check of
    its version."""
    if getattr(args, "cosim", None) is not None:
        link = Link(Cosim(args.cosim))
    elif getattr(args, "eth", None) is not None:
        host, _, port = args.eth.partition(":")
        if not host or (port and not port.isdigit()):
            fail(f"{args.eth} is not HOST or HOST:PORT")
        link = Link(Eth(int(port) if port else ETH_PORT, host))
    else:
        return nicelink.open_link(args)
    try:
        check_version(link)
    except LinkError as e:
        link.close()
        fail(str(e))
    return link
