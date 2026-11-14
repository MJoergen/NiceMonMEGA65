#!/usr/bin/env python3
"""Check the weather display, examples/weather.c, without a board (issue
#128).

It runs the monitor of the tests with examples/build/weather.bin in
niceemu, with --eth-udp and --eth-peer, whose frames go to
tools/tcppeer.py, the host 10.0.0.2, which serves HTTP on port 80 with
an answer of examples/test/ (the answers of the host's test,
weather_test.c). The card in slot 0 has NICE/WEATHER.CFG with the server
10.0.0.2, so no DNS server is needed, and the monitor's i 10.0.0.9 gives
the address. Each case runs to a step limit, then reads the screen's
words with --dump, as --screen shows no code above 0x7E, and checks its
rows, and the request that the peer got. It checks first that the program fits
in the Nexys4DDR's memory.

It prints a line for each check, and last how many passed, and exits with
status 1 when one fails. niceemu must be built, with make -C
nice_cpu/emulator build, and so must the program, with make -C examples,
and the monitor of the tests, with make -C monitor build/monitor_test.bin.
mkfs.fat and mtools make the card. Only the Python standard library is
used.
"""

import os
import re
import subprocess
import sys
import tempfile
import threading
from typing import Dict, List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tcppeer import Conn, Peer, Script  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NICEEMU = os.path.join(REPO, "nice_cpu", "emulator", "zig-out", "bin", "niceemu")
MONITOR = os.path.join(REPO, "monitor", "build", "monitor_test.bin")
PROGRAM = os.path.join(REPO, "examples", "build", "weather.bin")
ANSWERS = os.path.join(REPO, "examples", "test")
SCREEN = 0xFFFF0000
# The steps of a case: about 3 seconds of the host, far more than a fetch
# from the peer takes, and less than the 60 s before a fetch again.
STEPS = 100_000_000
# The codes of weather_parse.h's glyphs, and how the checks write them
G_UPPER, G_LOWER, G_FULL, G_ARROW = 0x80, 0x81, 0x82, 0x83
ARROWS = "←↑→↓↖↗↘↙"

REQUEST = ("GET /Copenhagen?format=%l|%C|%t|%w|%h&m HTTP/1.0\r\nHost: 10.0.0.2\r\n"
           "User-Agent: curl/8\r\nConnection: close\r\n\r\n").encode()

passed = 0
failed = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global passed, failed
    print(f"[{'PASS' if ok else 'FAIL'}] {name}" + ("" if ok or not detail else f": {detail}"))
    if ok:
        passed += 1
    else:
        failed += 1


class Http(Script):
    """A server of HTTP/1.0: the answer once the request's headers are in,
    then its FIN."""

    def __init__(self, answer: bytes) -> None:
        self.answer = answer
        self.request = b""

    def on_data(self, c: Conn, data: bytes) -> None:
        self.request += data
        if b"\r\n\r\n" in self.request and not c.fin_queued:
            c.send(self.answer)
            c.close()


def card(tmp: str, cfg: Optional[str]) -> str:
    """A card of FAT32 with the folder NICE, and WEATHER.CFG in it when cfg
    is not None."""
    img = os.path.join(tmp, "card.img")
    if os.path.exists(img):
        os.remove(img)
    with open(img, "wb") as f:
        f.truncate(64 * 1024 * 1024)
    quiet = {"check": True, "stdout": subprocess.DEVNULL, "stderr": subprocess.PIPE}
    subprocess.run(["mkfs.fat", "-F", "32", "-s", "1", img], **quiet)  # type: ignore[call-overload]
    subprocess.run(["mmd", "-i", img, "::NICE"], **quiet)  # type: ignore[call-overload]
    if cfg is not None:
        src = os.path.join(tmp, "weather.cfg")
        with open(src, "w") as f:
            f.write(cfg)
        subprocess.run(["mcopy", "-i", img, src, "::NICE/WEATHER.CFG"],
                       **quiet)  # type: ignore[call-overload]
    return img


class Run:
    """A run of the program: the screen's rows as text, where the glyphs of
    weather_parse.h are the characters of ARROWS and the blocks, the
    output of niceemu, and the peer."""

    def __init__(self, tmp: str, keys: str, cfg: Optional[str], answer: Optional[bytes],
                 steps: int = STEPS) -> None:
        self.peer = Peer()
        self.script: Optional[Http] = None
        if answer is not None:
            script = Http(answer)
            self.script = script
            self.peer.listen(80, lambda: script)
        self.peer.emu_port = free_port()
        thread = threading.Thread(target=self.peer.run, daemon=True)
        thread.start()
        image = os.path.join(tmp, "weather.full.bin")
        with open(image, "w") as f:
            f.write(open(MONITOR).read() + open(PROGRAM).read())
        inp = os.path.join(tmp, "input")
        with open(inp, "w") as f:
            f.write(keys)
        cmd = [NICEEMU, "-i", inp, "-n", str(steps), "-d", f"{SCREEN:#x}:2000",
               "--sd0", card(tmp, cfg), "--eth-udp", f"127.0.0.1:{self.peer.emu_port}",
               "--eth-peer", f"127.0.0.1:{self.peer.port}", image]
        try:
            res = subprocess.run(cmd, capture_output=True, timeout=120)
            self.out = res.stdout.decode("latin-1").replace("\r", "")
        except subprocess.TimeoutExpired as e:
            self.out = (e.stdout or b"").decode("latin-1").replace("\r", "")
        self.peer.stop = True
        thread.join()
        words: Dict[int, int] = {}
        for m in re.finditer(r"^([0-9A-Fa-f]{8}):((?: [0-9A-Fa-f]{8})+)", self.out, re.M):
            a = int(m[1], 16)
            for k, w in enumerate(m[2].split()):
                words[a + k] = int(w, 16)
        self.words = [words.get(SCREEN + i, 0) for i in range(2000)]
        self.rows = ["".join(char(w) for w in self.words[80 * r:80 * r + 80]).rstrip()
                     for r in range(25)]

    def row(self, r: int) -> str:
        return self.rows[r].strip()

    def color(self, r: int, text: str) -> int:
        """The color of the first character of text in row r, bits 31..8."""
        i = self.rows[r].find(text)
        return self.words[80 * r + i] >> 8 if i >= 0 else -1


def char(w: int) -> str:
    c = w & 0xFF
    if G_ARROW <= c < G_ARROW + 8:
        return ARROWS[c - G_ARROW]
    if c in (G_UPPER, G_LOWER, G_FULL):
        return "▀▄█"[c - G_UPPER]
    if c < 0x20 or 0x7F <= c < 0xA0:
        return " "
    return chr(c)


def free_port() -> int:
    import socket
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.bind(("127.0.0.1", 0))
        port: int = s.getsockname()[1]
        return port


def answer(name: str) -> bytes:
    with open(os.path.join(ANSWERS, name), "rb") as f:
        return f.read()


CFG = "# the peer of the test\nplace Copenhagen\nserver 10.0.0.2\nunits m\n"
KEYS = "i 10.0.0.9\rr\r"
ROW_CLOCK, ROW_DATE, ROW_PLACE, ROW_COND, ROW_VALUES = 3, 8, 11, 13, 15
ROW_STATUS, ROW_ERROR, ROW_CFG, ROW_KEYS = 18, 19, 21, 24
C_ERR = 0x000F66


def again(r: Run, text: str) -> bool:
    """Whether the error row is text and the seconds to the next fetch, which
    count down in the host's time."""
    return re.fullmatch(re.escape(text) + r", again in [1-6]?\d s", r.row(ROW_ERROR)) is not None


def size() -> None:
    """The program and its wasm memory must end below the monitor's
    variables of the Nexys4DDR, the top 4K words of its 64K, with room for
    the stack under them (doc/PROGRAMMING.md, "The memory")."""
    end = max(int(line.split()[0], 16) for line in open(PROGRAM) if line.strip())
    check(f"the program ends at {end:#06x}, 1K words below 0xF000 for the Nexys4DDR",
          end < 0xF000 - 1024)


def cases(tmp: str) -> None:
    r = Run(tmp, KEYS, CFG, answer("ok.http"))
    script = r.script
    assert script is not None
    check("ok.http: the request, with the place, the units, and the server as Host",
          script.request == REQUEST, repr(script.request))
    check("ok.http: the bar shows the IP address", r.rows[0].endswith("IP 10.0.0.9"), r.rows[0])
    check("ok.http: the place", r.row(ROW_PLACE) == "Copenhagen", r.row(ROW_PLACE))
    check("ok.http: the condition", r.row(ROW_COND) == "Patchy rain nearby", r.row(ROW_COND))
    want = "Temperature +8°C    Wind →19km/h    Humidity 77%"
    check("ok.http: the values, with the degree sign and the arrow of the font RAM",
          r.row(ROW_VALUES) == want, r.row(ROW_VALUES))
    check("ok.http: the status", r.row(ROW_STATUS) == "Fetched less than a minute ago",
          r.row(ROW_STATUS))
    check("ok.http: no error", r.row(ROW_ERROR) == "", r.row(ROW_ERROR))
    check("ok.http: the keys", r.row(ROW_KEYS) == "R fetch now    Q back to the monitor",
          r.row(ROW_KEYS))
    clock = r.rows[ROW_CLOCK:ROW_CLOCK + 4]
    check("ok.http: the large clock is drawn in blocks",
          all(any(ch in row for ch in "▀▄█") for row in clock), "\n".join(clock))
    check("ok.http: a date under it", re.fullmatch(
        r"(Sun|Mon|Tues|Wednes|Thurs|Fri|Satur)day \d{1,2} [A-Z][a-z]+ \d{4}",
        r.row(ROW_DATE)) is not None, r.row(ROW_DATE))

    r = Run(tmp, KEYS, CFG, answer("redirect.http"))
    want = "HTTP status 301 https://wttr.in/Copenhagen?format=%l|%C"
    check("redirect.http: the status and the Location, in red",
          again(r, want) and r.color(ROW_ERROR, "HTTP") == C_ERR, r.row(ROW_ERROR))
    check("redirect.http: no weather", r.row(ROW_STATUS) == "No weather yet", r.row(ROW_STATUS))

    r = Run(tmp, KEYS, CFG, answer("unknown.http"))
    want = "HTTP status 500 location not found: location not found"
    check("unknown.http: the status and the body's first line", again(r, want),
          r.row(ROW_ERROR))

    r = Run(tmp, KEYS, CFG, answer("fields.http"))
    want = "Not the weather: Sorry, we are running out of queries"
    check("fields.http: an answer of another format", again(r, want),
          r.row(ROW_ERROR))

    r = Run(tmp, KEYS, CFG, None)
    want = "Error -53, the server refused the connection"
    check("no server on port 80: the refusal", again(r, want), r.row(ROW_ERROR))

    r = Run(tmp, KEYS, CFG + "wind strong\n", answer("ok.http"))
    check("a line not understood is shown, and the rest is kept",
          r.row(ROW_CFG) == "WEATHER.CFG: line 5 is not understood"
          and r.row(ROW_PLACE) == "Copenhagen", f"{r.row(ROW_CFG)!r} {r.row(ROW_PLACE)!r}")

    r = Run(tmp, "r\rOsx\x7flo", None, None, steps=20_000_000)
    check("no WEATHER.CFG: the place is asked for, and typed with a DEL",
          "Type the place" in r.row(ROW_PLACE - 1) and r.row(ROW_PLACE + 1) == "Oslo_",
          f"{r.row(ROW_PLACE - 1)!r} {r.row(ROW_PLACE + 1)!r}")

    r = Run(tmp, "r\r\x1bh\r", None, None)
    check("no WEATHER.CFG: ESC returns to the monitor", "Returned 00000000" in r.out,
          r.out[-400:])
    r = Run(tmp, KEYS + "qh\r", CFG, answer("ok.http"))
    check("Q returns to the monitor", "Returned 00000000" in r.out, r.out[-400:])


def main() -> None:
    for path, how in ((NICEEMU, "make -C nice_cpu/emulator build"),
                      (MONITOR, "make -C monitor build/monitor_test.bin"),
                      (PROGRAM, "make -C examples")):
        if not os.path.exists(path):
            sys.exit(f"weathertest.py: no {path}; {how} builds it")
    size()
    with tempfile.TemporaryDirectory() as tmp:
        cases(tmp)
    print(f"{passed} of {passed + failed} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
