#!/usr/bin/env python3
"""Run BASIC's HTTP$ and URL$ (issue #170) in niceemu, against the HTTP
server of tools/lib/tcppeer.py.

Usage: test/web.py NICEEMU ROM.bin

niceemu runs the ROM of the tests with --eth-udp and --eth-peer, whose
frames go to tcppeer's peer, the host 10.0.0.2, which listens on port 80
and answers each request by its path, from ANSWERS, and refuses port 81.
BASIC's IP "10.0.0.9" gives the address, and PROGRAM, typed before its
RUN, fetches the paths: a body in UTF-8 with the arrows and the blocks,
Content-Length shorter than what the server sends, and one with no
digits, which counts as none, line ends inside the body and at its end,
the longest body and two too long, the statuses 404, 301 with a
Location, and 500 with a line of text, answers that are not HTTP or are
cut short, bytes that are no UTF-8, an empty body, a refused port, a
name with no DNS server, URL$, and a path and a port that are an Illegal
quantity. Its TRAP prints each error's ER, DS, and DS$, and goes on
after it. Its 18 connections, more than the 4 handles of TCP, show that
each frees its handle. The checks read what RUN prints, a line each, and
the requests that the peer got.

It prints a line for each check, and last how many passed, and exits with
status 1 when one fails. Only the Python standard library is used.
"""

import os
import socket
import subprocess
import sys
import tempfile
import threading
from typing import Dict, List

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
from lib.tcppeer import Conn, Peer, Script  # noqa: E402

STEPS = 400_000_000
OK = b"HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n"
ANSWERS: Dict[str, bytes] = {
    "/ok": OK + "Copenhagen: +8°C\n".encode(),
    "/glyphs": OK + "→↗█▀ ü".encode(),
    "/len": b"HTTP/1.1 200 OK\r\ncontent-LENGTH:  5\r\n\r\nHelloEXTRA",
    "/nolen": b"HTTP/1.0 200 OK\r\nContent-Length: abc\r\n\r\nWhole",
    "/crlf": OK + b"a\r\nb\r\n",
    "/255": OK + b"x" * 255 + b"\r\n",
    "/256": OK + b"x" * 256,
    "/long": OK + b"x" * 300,
    "/404": b"HTTP/1.0 404 Not Found\r\n\r\nNo such page\n",
    "/301": b"HTTP/1.1 301 Moved Permanently\r\nLocation: https://example.com/x\r\n\r\nMoved",
    "/500": b"HTTP/1.1 500 Internal Server Error\r\n\r\nUnknown location; please try again\n",
    "/nothttp": b"SSH-2.0-OpenSSH\r\n",
    "/short": b"HTTP/1.0 200 OK\r\nContent-Length: 10\r\n\r\nabc",
    "/headers": b"HTTP/1.0 200 OK\r\nX-A: b",
    "/utf8": OK + b"\xe2\x86x\xff\xc3\x80\xc2\x85!",
    "/empty": OK,
}
# The program, whose lines are typed before RUN, so that no key is typed
# while HTTP$ polls the console, which would take them into the ring of
# the keys typed ahead. Line 900 prints each error, and goes on after it.
PROGRAM = [
    '10 TRAP 900',
    '20 PRINT "["; HTTP$("10.0.0.2", "/ok"); "]"',
    '30 A$ = HTTP$("10.0.0.2:80", "/glyphs"): GOSUB 800',
    '40 PRINT "["; HTTP$("10.0.0.2", "/len"); "]"',
    '45 PRINT "["; HTTP$("10.0.0.2", "/nolen"); "]"',
    '50 A$ = HTTP$("10.0.0.2", "/crlf"): GOSUB 800',
    '60 PRINT LEN(HTTP$("10.0.0.2", "/255"))',
    '70 PRINT HTTP$("10.0.0.2", "/256")',
    '80 PRINT HTTP$("10.0.0.2", "/long")',
    '90 PRINT HTTP$("10.0.0.2", "/404")',
    '100 PRINT HTTP$("10.0.0.2", "/301")',
    '110 PRINT HTTP$("10.0.0.2", "/500")',
    '120 PRINT HTTP$("10.0.0.2", "/nothttp")',
    '130 PRINT HTTP$("10.0.0.2", "/short")',
    '140 PRINT HTTP$("10.0.0.2", "/headers")',
    '150 A$ = HTTP$("10.0.0.2", "/utf8"): GOSUB 800',
    '160 PRINT "["; HTTP$("10.0.0.2", "/empty"); "]"',
    '170 PRINT HTTP$("10.0.0.2:81", "/")',
    '180 PRINT HTTP$("example.com", "/")',
    '190 PRINT HTTP$("10.0.0.2", "/" + URL$("New York") + "?format=%l")',
    '200 PRINT HTTP$("10.0.0.2", "x")',
    '210 PRINT HTTP$("10.0.0.2:0", "/")',
    '220 PRINT "END"',
    '230 END',
    '800 FOR I = 1 TO LEN(A$): PRINT ASC(MID$(A$, I, 1)); " "; : NEXT I: PRINT: RETURN',
    '900 PRINT "E "; ER; " "; DS; " "; DS$: RESUME NEXT',
]
INPUT = "\r".join(['IP "10.0.0.9"'] + PROGRAM + ["RUN", "HALT", ""])
# What RUN prints, a line each
WANT = [
    "[Copenhagen: +8\xb0C]",
    "146 151 136 128 32 252 ",
    "[Hello]",
    "[Whole]",
    "97 13 10 98 ",
    "255",
    "E 23 0 ",
    "E 23 0 ",
    "E 4 69 HTTP status 404, No such page",
    "E 113 69 HTTP status 301, https://example.com/x",
    "E 113 69 HTTP status 500, Unknown location; please try again",
    "E 113 67 Not an HTTP server",
    "E 113 68 The answer of the server was cut short",
    "E 113 68 The answer of the server was cut short",
    "63 120 63 192 63 33 ",
    "[]",
    "E 113 53 The server refused the connection",
    "E 5 46 No DNS server; DHCP gets one",
    "/New%20York?format=%l",
    "E 14 46 No DNS server; DHCP gets one",
    "E 14 46 No DNS server; DHCP gets one",
    "END",
]

passed = 0
failed = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global passed, failed
    print(f"[{'PASS' if ok else 'FAIL'}] {name}" + ("" if ok or not detail else f": {detail!r}"))
    if ok:
        passed += 1
    else:
        failed += 1


class Http(Script):
    """A server of HTTP/1.0: the answer of the request's path once its
    headers are in, then its FIN."""

    def __init__(self, requests: List[bytes]) -> None:
        self.request = b""
        self.requests = requests

    def on_data(self, c: Conn, data: bytes) -> None:
        self.request += data
        if b"\r\n\r\n" in self.request and not c.fin_queued:
            self.requests.append(self.request)
            path = self.request.split(b" ")[1].decode()
            c.send(ANSWERS.get(path, OK + path.encode()))
            c.close()


def free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    port: int = s.getsockname()[1]
    s.close()
    return port


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    emu, rom = sys.argv[1:]
    requests: List[bytes] = []
    peer = Peer()
    peer.listen(80, lambda: Http(requests))
    peer.emu_port = free_port()
    thread = threading.Thread(target=peer.run, daemon=True)
    thread.start()
    with tempfile.TemporaryDirectory() as tmp:
        inp = os.path.join(tmp, "input")
        with open(inp, "w") as f:
            f.write(INPUT)
        cmd = [emu, "-i", inp, "-n", str(STEPS), "--eth-udp", f"127.0.0.1:{peer.emu_port}",
               "--eth-peer", f"127.0.0.1:{peer.port}", rom]
        res = subprocess.run(cmd, capture_output=True, timeout=300)
    peer.stop = True
    thread.join()
    out = res.stdout.decode("latin-1").replace("\r", "")
    lines = out.split("\n")

    check("the run halts", "Halted (HALT)" in out, out[-300:])
    got: List[str] = []
    if "RUN" in lines:
        got = lines[lines.index("RUN") + 1:]
    for k, want in enumerate(WANT):
        line = got[k] if k < len(got) else "(none)"
        check(f"line {k + 1} of RUN: {want!r}", line == want, line)
    ok = [r for r in requests if r.startswith(b"GET /ok ")]
    request = (b"GET /ok HTTP/1.0\r\nHost: 10.0.0.2\r\nUser-Agent: NiceMon-BASIC/V9.9\r\n"
            b"Connection: close\r\n\r\n")
    check("the request of /ok", ok == [request], repr(ok))
    glyphs = [r for r in requests if r.startswith(b"GET /glyphs ")]
    check("the Host of /glyphs has the port", len(glyphs) == 1
          and b"\r\nHost: 10.0.0.2:80\r\n" in glyphs[0], repr(glyphs))
    print(f"{passed} of {passed + failed} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
