"""The messages and exit codes that the subcommands of nicemon.py share.

Every subcommand writes its errors, its warnings, and its progress to
stderr, each line after "nicemon.py SUBCOMMAND: ", so that stdout carries
only the console and the data that a subcommand prints: run's output,
sd ls, and sd get -, which can be piped (issue #156). An error starts in
lower case, unless it quotes the monitor, as "File error N, ..." does.

The exit codes:

- 0 for success.
- 1 for an error of the board, the link, or a file (fail()).
- 2 for an error of the command line, argparse's own.
- 130 after Ctrl-C, with the core left as the subcommand documents.
- 141 when stdout closes early, as with "nicemon.py sd ls | head".

run keeps the program's status in place of 0 and 2, and exits 1 on an
error of the command line, as niceemu does (tools/README.md). nbd
exits 0 on SIGTERM, the stop of a service, and 130 on Ctrl-C, after the
same cleanup.

start() names the subcommand. It also sets sys.argv[0], so that the
messages of nice_cpu's debugger/nicelink.py and the usage of its
nicedbg.py, which take the name from there, start the same way.
"""

import argparse
import os
import sys
from typing import Callable, NoReturn, Tuple

PROG = "nicemon.py"

EXIT_ERROR = 1
EXIT_USAGE = 2
EXIT_INTERRUPT = 130
EXIT_PIPE = 141

# What the messages start with: "nicemon.py load" once start() has named
# the subcommand, or the script's name, as for hwtest.py, which uses the
# modules of the subcommands
command = os.path.basename(sys.argv[0])


def start(name: str) -> None:
    """Names the running subcommand in the messages from here on."""
    global command
    command = f"{PROG} {name}"
    sys.argv[0] = command


def fail(message: str) -> NoReturn:
    """Exits with status 1, after the message on stderr."""
    sys.stdout.flush()
    raise SystemExit(f"{command}: {message}")


def note(message: str, end: str = "\n") -> None:
    """A line of progress, or a question, on stderr."""
    print(f"{command}: {message}", end=end, file=sys.stderr, flush=True)


def warn(message: str) -> None:
    """A warning on stderr; the subcommand goes on."""
    note(f"warning: {message}")


def listen_type(default_host: str) -> Callable[[str], Tuple[str, int]]:
    """The type of a --listen [HOST:]PORT option, which nbd and tftpd
    share: the host, default_host when none is given, and the port."""
    def listen(spec: str) -> Tuple[str, int]:
        host, _, port = spec.rpartition(":")
        if not port.isdigit() or int(port) > 65535:
            raise argparse.ArgumentTypeError(f"{spec} is not [HOST:]PORT")
        return host or default_host, int(port)
    return listen
