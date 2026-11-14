# The examples

Programs in C for the NICE CPU. `make examples` at the top builds them to
`examples/build/`. It needs clang with the wasm32 target, `wasm-ld`, and
`llvm-ar` (on Debian and Ubuntu, the `clang`, `lld`, and `llvm`
packages). [doc/PROGRAMMING.md](../doc/PROGRAMMING.md) says how C
reaches the board.

| Program | What it does |
|---|---|
| `primes.bin` | Asks for a limit, counts the primes up to it, and prints how many cycles and instructions that took, until it reads 0. It runs on its own, from address 0, loaded by `tools/load.py`. |
| `bench.bin`, `bench_win.bin` | nice_cpu's benchmark, which `make hwtest` runs (CONTRIBUTING.md, "The examples"). |
| `weather.bin` | A weather display on the screen, below. It runs under the monitor. |

## The weather display

`weather.bin` shows the weather of a place, the date, and the time on the
screen, and fetches the weather again every 10 minutes. It can stay on
for days, as a display on a desk.

The weather comes from [wttr.in](https://wttr.in), a free weather service,
over plain HTTP, on the board's Ethernet port. The date and the time come
from the board's clock, which the monitor's `time ntp` sets. The clock
keeps local time, so `time ntp +01:00` sets it to Central European Time.
On the MEGA65 the clock keeps running when the power is off. On the
Nexys4DDR, set it after each reset. Without it, the screen shows
`--:--:--` and says so.

### Running it

1. Copy `examples/build/weather.bin` to the folder `NICE` of the SD card.
2. Write the settings file `WEATHER.CFG` (below) into the same folder,
   or leave it out and type the place at the start.
3. On the board, at the monitor's prompt, type `load weather.bin` and
   then `r`.

The board needs a network with a DHCP server, the service that hands out
IP addresses, as most home routers have. When the board has no IP
address yet, the program asks for one by itself, as the monitor's `i
dhcp` does.

| Key | What it does |
|---|---|
| R | Fetches the weather now |
| Q | Returns to the monitor |

### The settings file

`WEATHER.CFG` is a text file with one setting a line. A `#` starts a
comment. For example:

    # The weather of Copenhagen, in degrees Celsius
    place Copenhagen
    units m

| Setting | What it is |
|---|---|
| `place NAME` | The place, such as `Copenhagen`, `New York`, or an airport's code, such as `CPH`. Without it, wttr.in guesses the place from the address that the request comes from. |
| `units m` or `units u` | Metric units (°C and km/h), or those of the USA (°F and mph). Without it, wttr.in chooses by the place. |
| `server NAME[:PORT]` | Another server than `wttr.in`, with port 80 unless one is given. It must answer as wttr.in does (below). |

A line that the program does not understand is shown in red at the
start, and the other lines still count.

### What the screen shows

The top row shows the server and the board's IP address. Under the large
clock and the date are the place, the weather, the temperature, the
wind, and the humidity. The arrow of the wind points the way the wind
blows. The green line says how old the weather is.

When a fetch fails, a red line says why, such as `Error -47, no answer
from the DNS server`, and when the next try is, a minute later. The
last weather stays on the screen until then. The numbers are the
monitor's error codes ([doc/PROGRAMMING.md](../doc/PROGRAMMING.md#the-monitors-error-codes)).
An answer of the server that is not the weather is shown too, such as
`HTTP status 500 location not found` for a place that wttr.in does not
know.

### When wttr.in changes

wttr.in is a service run by one person, and it may be slow or down at
times. The program needs plain HTTP, as the board has no encryption
(HTTPS). If wttr.in ever sends the program to HTTPS, the red line
shows `HTTP status 301` and the new address. Then a small proxy on a
computer of the local network can fetch the weather over HTTPS, and
answer the board over plain HTTP, with the `server` setting pointing to
it. The proxy gets the request

    GET /PLACE?format=%l|%C|%t|%w|%h HTTP/1.0

and answers with one line of five fields, separated by `|`, as wttr.in
does:

    Copenhagen|Partly cloudy|+7°C|↙13km/h|87%

### Building and testing it

`weather.c` is the program: the screen, the keys, the fetch, and the
settings. `weather_parse.c` is the text: the settings, the request, and
the answer, which `make -C examples test` checks on the host with the
answers in `test/`. `make weathertest` at the top runs that, and then
the whole program in the emulator against a server of the test
(CONTRIBUTING.md, "The examples").
