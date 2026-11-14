// A weather display (issue #128): the weather of a place from wttr.in over
// plain HTTP, fetched again every 10 minutes, and the date and the time,
// large, from the clock of the time of day. It runs under the monitor,
// at 0x8000, and uses the network of the ROM from C: DNS, a TCP
// connection, and the poll (monitor/README.md, "TCP and DNS"). R fetches
// at once, and Q returns to the monitor.
//
// The settings are in WEATHER.CFG of the card's folder NICE, lines such as
// "place Copenhagen" (weather_parse.h, cfg_parse). With no file, the
// program asks for the place.
//
// Built with nicebuild.py --monitor --asm mon.nasm --asm mon_c.nasm
// (Makefile), as the entries of the network take C pointers.
#include <nice.h>
#include <stdarg.h>
#include <string.h>
#include "mon.h"
#include "weather_parse.h"

#define FETCH_EVERY 600     // seconds between two fetches
#define RETRY_AFTER 60      // seconds after an error
#define FETCH_TIMEOUT 20    // seconds for the answer

#define RX 512
#define TX 256

// The colors, bits 31..8 of a screen word: the background in 23..12 and
// the foreground in 11..0 here.
#define C_TEXT 0x000FFFu
#define C_DIM 0x000888u
#define C_BAR 0x036FFFu
#define C_CLOCK 0x0000DFu
#define C_PLACE 0x000FE0u
#define C_OK 0x0008E8u
#define C_ERR 0x000F66u

#define COLS NICE_SCREEN_COLS
#define ROW_CLOCK 3             // 4 rows
#define ROW_DATE 8
#define ROW_PLACE 11
#define ROW_COND 13
#define ROW_VALUES 15
#define ROW_STATUS 18
#define ROW_ERROR 19
#define ROW_CFG 21
#define ROW_KEYS 24

#define FONT_RAM 0xFFFE0000u
#define FONT_ROM 0xFFFE2000u
#define FONT_BASE 0xFFFFFF86u
#define SCR_STATE 0xFFFFFF80u

static unsigned cb[TCP_CB_WORDS(RX, TX)];
static struct cfg cfg;
static struct weather weather;      // the last one fetched
static int have_weather;
static unsigned long long weather_at;   // micros of the fetch

// The fetch, a step at each turn of the main loop.
enum { F_IDLE, F_RECV };
static int fstate = F_IDLE;
static int handle;
static unsigned long long fetch_start, next_fetch;
static char req[256];
static unsigned req_n, req_sent;
static char ans[2048];
static unsigned ans_n;
static int last_error;              // of the last fetch, 0 when it worked
static char error_text[96];

static unsigned long long micros(void)
{
    return nice_micros();
}

// ---- Text

// The format f to buf of size bytes, cut to fit, with %s, %d, and %u
// alone: snprintf would bring in the float formatting of the C library,
// 5K words, and the program must fit below the monitor's variables in
// the 28K words of the Nexys4DDR.
static void fmt(char *buf, unsigned size, const char *f, ...)
{
    va_list ap;
    unsigned n = 0;
    va_start(ap, f);
    for (; *f; f++) {
        char num[12];
        const char *s = num;
        if (*f != '%' || (f[1] != 's' && f[1] != 'd' && f[1] != 'u')) {
            num[0] = *f;
            num[1] = 0;
        } else if (*++f == 's') {
            s = va_arg(ap, const char *);
        } else {
            int neg = 0, i = sizeof num - 1;
            unsigned u;
            if (*f == 'd') {
                int v = va_arg(ap, int);
                neg = v < 0;
                u = neg ? 0u - (unsigned)v : (unsigned)v;
            } else
                u = va_arg(ap, unsigned);
            num[i] = 0;
            do
                num[--i] = (char)('0' + u % 10);
            while (u /= 10);
            if (neg)
                num[--i] = '-';
            s = num + i;
        }
        while (*s && n + 1 < size)
            buf[n++] = *s++;
    }
    va_end(ap);
    if (size)
        buf[n] = 0;
}

// ---- The screen

static void put(int col, int row, unsigned color, int c)
{
    if (col >= 0 && col < COLS)
        nice_screen_put(col, row, (int)(color << 8 | (unsigned char)c));
}

static void clear_row(int row, unsigned color)
{
    for (int c = 0; c < COLS; c++)
        put(c, row, color, ' ');
}

static void text(int col, int row, unsigned color, const char *s)
{
    while (*s)
        put(col++, row, color, *s++);
}

// A row cleared, with s in its middle.
static void center(int row, unsigned color, const char *s)
{
    clear_row(row, C_TEXT);
    text((COLS - (int)strlen(s)) / 2, row, color, s);
}

// ---- The font

static unsigned glyph[32];

static void dot(int x, int y)
{
    for (int dy = 0; dy < 2; dy++)
        for (int dx = 0; dx < 2; dx++)
            if (x + dx >= 0 && x + dx < 16 && y + dy >= 0 && y + dy < 32)
                glyph[y + dy] |= 0x8000u >> (x + dx);
}

static void line(int x, int y, int dx, int dy, int n)
{
    for (int i = 0; i <= n; i++)
        dot(x + i * dx, y + i * dy);
}

static int sgn(int v)
{
    return (v > 0) - (v < 0);
}

// The arrow to (dx, dy), y down, as the glyph of code c.
static void arrow(int c, int dx, int dy)
{
    int n = dx && dy ? 5 : 6;           // a diagonal is longer per step
    int tx = 7 + n * dx, ty = 15 + n * dy;
    memset(glyph, 0, sizeof glyph);
    line(7 - n * dx, 15 - n * dy, dx, dy, 2 * n);
    int a = -dx, b = -dy;               // the head: back, turned by 45 degrees
    line(tx, ty, sgn(a - b), sgn(a + b), 4);
    line(tx, ty, sgn(a + b), sgn(b - a), 4);
    for (int r = 0; r < 32; r++)
        nice_poke(FONT_RAM + 32 * (unsigned)c + (unsigned)r, glyph[r]);
}

// Spleen copied to the font RAM, with the glyphs of weather_parse.h.
static void font_init(void)
{
    for (unsigned i = 0; i < 8192; i++)
        nice_poke(FONT_RAM + i, nice_peek(FONT_ROM + i));
    for (unsigned r = 0; r < 32; r++) {
        nice_poke(FONT_RAM + 32 * G_UPPER + r, r < 16 ? 0xFFFF : 0);
        nice_poke(FONT_RAM + 32 * G_LOWER + r, r < 16 ? 0 : 0xFFFF);
        nice_poke(FONT_RAM + 32 * G_FULL + r, 0xFFFF);
    }
    static const signed char dir[8][2] = {
        {-1, 0}, {0, -1}, {1, 0}, {0, 1}, {-1, -1}, {1, -1}, {1, 1}, {-1, 1},
    };
    for (int k = 0; k < 8; k++)
        arrow(G_ARROW + k, dir[k][0], dir[k][1]);
    nice_poke(FONT_BASE, FONT_RAM);
}

// ---- The large clock: digits of 5 by 7 dots, two dots to a cell

static const unsigned char digits[11][7] = {
    {0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E}, {0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E},
    {0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F}, {0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E},
    {0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02}, {0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E},
    {0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E}, {0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08},
    {0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E}, {0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C},
    {0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00},     // -
};
static const unsigned char colon[7] = {0, 0, 1, 0, 1, 0, 0};

static void big(int col, const unsigned char *rows, int width)
{
    for (int r = 0; r < 4; r++)
        for (int x = 0; x < width; x++) {
            int sh = width - 1 - x;
            int top = rows[2 * r] >> sh & 1;
            int bot = 2 * r + 1 < 7 ? rows[2 * r + 1] >> sh & 1 : 0;
            int c = top ? (bot ? G_FULL : G_UPPER) : (bot ? G_LOWER : ' ');
            put(col + x, ROW_CLOCK + r, C_CLOCK, c);
        }
}

// HH:MM:SS, or --:--:-- for a negative s.
static void big_time(long long s)
{
    int d[6];
    for (int i = 0; i < 6; i++)
        d[i] = 10;
    if (s >= 0) {
        long long t = s % 86400;
        d[0] = (int)(t / 36000), d[1] = (int)(t / 3600 % 10);
        d[2] = (int)(t % 3600 / 600), d[3] = (int)(t % 600 / 60);
        d[4] = (int)(t % 60 / 10), d[5] = (int)(t % 10);
    }
    int col = (COLS - 39) / 2;
    for (int i = 0; i < 6; i++) {
        big(col, digits[d[i]], 5);
        col += 6;
        if (i == 1 || i == 3) {
            big(col, colon, 1);
            col += 2;
        }
    }
}

// ---- The date

static const char *const wdays[7] = {
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
};
static const char *const months[12] = {
    "January", "February", "March", "April", "May", "June", "July", "August",
    "September", "October", "November", "December",
};

// The day, the month, 1 to 12, and the year of the days since 1970-01-01
// (H. Hinnant's civil_from_days).
static void civil(long long days, int *d, int *m, long long *y)
{
    long long z = days + 719468;
    long long era = (z >= 0 ? z : z - 146096) / 146097;
    long long doe = z - era * 146097;
    long long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    long long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    long long mp = (5 * doy + 2) / 153;
    *d = (int)(doy - (153 * mp + 2) / 5 + 1);
    *m = (int)(mp < 10 ? mp + 3 : mp - 9);
    *y = yoe + era * 400 + (*m <= 2);
}

// The clock of the time of day in seconds, local time, or -1 when it holds
// no time.
static long long now_s(void)
{
    if (!nice_clock_isset())
        return -1;
    return (long long)nice_clock(0);
}

static void draw_clock(long long s)
{
    char buf[64];
    big_time(s);
    if (s < 0) {
        center(ROW_DATE, C_DIM, "The clock is not set: the monitor's time ntp sets it");
        return;
    }
    int d, m;
    long long y, days = s / 86400;
    civil(days, &d, &m, &y);
    fmt(buf, sizeof buf, "%s %d %s %d", wdays[(days + 4) % 7], d, months[m - 1], (int)y);
    center(ROW_DATE, C_TEXT, buf);
}

// ---- The rest of the screen

static void draw_bar(void)
{
    unsigned c[4];
    char buf[96];
    net_config(c);
    clear_row(0, C_BAR);
    fmt(buf, sizeof buf, "Weather from %s", cfg.host);
    text(1, 0, C_BAR, buf);
    if (c[0])
        fmt(buf, sizeof buf, "IP %u.%u.%u.%u", c[0] >> 24, c[0] >> 16 & 255,
                 c[0] >> 8 & 255, c[0] & 255);
    else
        fmt(buf, sizeof buf, "No IP address");
    text(COLS - 1 - (int)strlen(buf), 0, C_BAR, buf);
    clear_row(ROW_KEYS, C_BAR);
    text(1, ROW_KEYS, C_BAR, "R fetch now    Q back to the monitor");
}

static void draw_weather(void)
{
    char buf[128];
    if (!have_weather) {
        for (int r = ROW_PLACE; r <= ROW_VALUES; r += 2)
            clear_row(r, C_TEXT);
        return;
    }
    center(ROW_PLACE, C_PLACE, weather.place);
    center(ROW_COND, C_TEXT, weather.cond);
    fmt(buf, sizeof buf, "Temperature %s    Wind %s    Humidity %s", weather.temp,
             weather.wind, weather.humid);
    center(ROW_VALUES, C_TEXT, buf);
}

static void status(unsigned color, const char *s)
{
    center(ROW_STATUS, color, s);
}

// The name of an error of the monitor or of weather_parse.
static const char *error_name(int e)
{
    switch (e) {
    case E_NOIP: return "no IP address";
    case E_NOROUTE: return "no answer to ARP from the host or the gateway";
    case E_NODHCP: return "no answer from a DHCP server";
    case E_NODNS: return "no DNS server";
    case E_DNSTIME: return "no answer from the DNS server";
    case E_DNSNAME: return "no such name";
    case E_DNSFAIL: return "the DNS server reported an error";
    case E_TFULL: return "every TCP handle is in use";
    case E_TREFUSED: return "the server refused the connection";
    case E_TRESET: return "the server reset the connection";
    case E_TTIMEOUT: return "no answer from the server";
    case W_SHORT: return "the answer was cut short";
    case W_NOHTTP: return "the answer is not HTTP";
    default: return "error";
    }
}

static void draw_status(unsigned long long now)
{
    char buf[128];
    if (fstate != F_IDLE)
        return;                         // the fetch shows its own
    if (have_weather) {
        unsigned min = (unsigned)((now - weather_at) / 60000000u);
        if (min == 0)
            fmt(buf, sizeof buf, "Fetched less than a minute ago");
        else
            fmt(buf, sizeof buf, "Fetched %u minute%s ago", min, min == 1 ? "" : "s");
        status(C_OK, buf);
    } else
        status(C_DIM, "No weather yet");
    if (last_error) {
        unsigned s = now < next_fetch ? (unsigned)((next_fetch - now + 999999) / 1000000) : 0;
        fmt(buf, sizeof buf, "%s, again in %u s", error_text, s);
        center(ROW_ERROR, C_ERR, buf);
    } else
        clear_row(ROW_ERROR, C_TEXT);
}

// ---- The settings

static unsigned words[256];

// WEATHER.CFG read into cfg, or else the place asked for. 0, or Q pressed.
static int settings(void)
{
    static const char name[] = "WEATHER.CFG";
    static char buf[1024];
    unsigned n = 0;
    for (unsigned i = 0; i < sizeof name; i++)
        words[i] = (unsigned char)name[i];
    int h = fs_open(mon_words(words), 0);
    if (h >= 0) {
        int r;
        while (n < sizeof buf && (r = fs_read(h, mon_words(words), 256)) > 0)
            for (int i = 0; i < r && n < sizeof buf; i++)
                buf[n++] = (char)words[i];
        fs_close(h);
        int bad = cfg_parse(&cfg, buf, n);
        if (bad) {
            char msg[64];
            fmt(msg, sizeof msg, "WEATHER.CFG: line %d is not understood", bad);
            center(ROW_CFG, C_ERR, msg);
        }
        return 0;
    }
    cfg_parse(&cfg, "", 0);
    // No file: the place typed, Enter alone for wttr.in's guess.
    center(ROW_PLACE - 2, C_TEXT, "No WEATHER.CFG in the card's folder NICE.");
    center(ROW_PLACE - 1, C_TEXT, "Type the place, or Enter alone for the one wttr.in guesses:");
    for (;;) {
        clear_row(ROW_PLACE + 1, C_TEXT);
        text(20, ROW_PLACE + 1, C_PLACE, cfg.place);
        put(20 + (int)strlen(cfg.place), ROW_PLACE + 1, C_PLACE, '_');
        int c;
        while ((c = nice_pollc()) < 0)
            net_poll();
        unsigned len = (unsigned)strlen(cfg.place);
        if (c == '\r' || c == '\n')
            break;
        if ((c == 8 || c == 127) && len > 0)
            cfg.place[len - 1] = 0;
        else if (c == 3 || c == 27)
            return 1;
        else if (c >= 32 && c < 127 && len + 1 < sizeof cfg.place) {
            cfg.place[len] = (char)c;
            cfg.place[len + 1] = 0;
        }
    }
    for (int r = ROW_PLACE - 2; r <= ROW_PLACE + 1; r++)
        clear_row(r, C_TEXT);
    return 0;
}

// ---- The fetch

// The fetch ended in error e, which error_text says, unless e is one of
// the monitor's, and is tried again after RETRY_AFTER.
static void fail(int e, unsigned long long now)
{
    if (e != W_STATUS && e != W_FIELDS)
        fmt(error_text, sizeof error_text, "Error %d, %s", e, error_name(e));
    last_error = e;
    next_fetch = now + RETRY_AFTER * 1000000ull;
    fstate = F_IDLE;
}

// The lookup and the connection, which wait, then the rest in fetch_step.
static void fetch_start_now(void)
{
    char buf[96];
    unsigned c[4], ip;
    int r;
    net_config(c);
    if (c[0] == 0) {
        status(C_DIM, "Asking for an IP address (DHCP)...");
        r = net_dhcp();
        draw_bar();
        if (r < 0) {
            fail(r, micros());
            return;
        }
    }
    fmt(buf, sizeof buf, "Looking up %s...", cfg.host);
    status(C_DIM, buf);
    r = dns_lookup(cfg.host, &ip);
    if (r == E_NODNS) {
        status(C_DIM, "Asking for a DNS server (DHCP)...");
        r = net_dhcp();
        draw_bar();
        if (r >= 0)
            r = dns_lookup(cfg.host, &ip);
    }
    if (r < 0) {
        fail(r, micros());
        return;
    }
    fmt(buf, sizeof buf, "Fetching from %s...", cfg.host);
    status(C_DIM, buf);
    r = tcp_open(cb, ip, cfg.port, TCP_SIZES(RX, TX));
    if (r < 0) {
        fail(r, micros());
        return;
    }
    handle = r;
    req_sent = 0;
    ans_n = 0;
    fetch_start = micros();
    fstate = F_RECV;
}

static void fetch_done(unsigned long long now)
{
    struct weather w;
    struct answer a;
    int r = weather_parse(ans, ans_n, &w, &a);
    if (r != W_OK) {
        if (r == W_STATUS)
            fmt(error_text, sizeof error_text, "HTTP status %d %s", a.status, a.text);
        else if (r == W_FIELDS)
            fmt(error_text, sizeof error_text, "Not the weather: %s", a.text);
        fail(r, now);
        return;
    }
    weather = w;
    have_weather = 1;
    weather_at = now;
    last_error = 0;
    next_fetch = now + FETCH_EVERY * 1000000ull;
    fstate = F_IDLE;
    draw_weather();
}

static void fetch_step(unsigned long long now)
{
    int r;
    if (req_sent < req_n) {
        r = tcp_send(handle, req + req_sent, req_n - req_sent);
        if (r < 0) {
            tcp_close(handle, 1);
            fail(r, now);
            return;
        }
        req_sent += (unsigned)r;
    }
    r = 0;
    if (ans_n < sizeof ans)
        r = tcp_recv(handle, ans + ans_n, sizeof ans - ans_n);
    if (r > 0)
        ans_n += (unsigned)r;
    if (r == E_TEOF || ans_n == sizeof ans) {
        tcp_close(handle, r == E_TEOF ? 0 : 1);
        fetch_done(now);
    } else if (r < 0) {
        tcp_close(handle, 1);
        fail(r, now);
    } else if (now - fetch_start > FETCH_TIMEOUT * 1000000ull) {
        tcp_close(handle, 1);
        fail(E_TTIMEOUT, now);
    }
}

int main(void)
{
    if (mon_version() < 0x00010005) {
        nice_print("The weather needs the monitor's dispatch table 1.5 or later\n");
        return 1;
    }
    scr_cls();
    nice_poke(SCR_STATE, nice_peek(SCR_STATE) & ~0x40u);    // no cursor
    font_init();
    cfg_parse(&cfg, "", 0);
    draw_bar();
    int quit = settings();
    req_n = weather_request(&cfg, req, sizeof req);
    long long shown = -2;
    int was = -1;
    unsigned long long tick = 0;
    next_fetch = micros();
    while (!quit) {
        unsigned long long now = micros();
        int c = nice_pollc();
        if (c == 'q' || c == 'Q')
            break;
        if ((c == 'r' || c == 'R') && fstate == F_IDLE)
            next_fetch = now;
        net_poll();
        // The screen once a second, and when the clock or the fetch moved.
        long long s = now_s();
        if (s != shown || now - tick >= 1000000u || fstate != was) {
            draw_clock(s);
            draw_bar();
            draw_status(now);
            shown = s;
            tick = now;
            was = fstate;
        }
        if (fstate == F_IDLE && now >= next_fetch) {
            clear_row(ROW_ERROR, C_TEXT);
            fetch_start_now();
        } else if (fstate == F_RECV)
            fetch_step(now);
        if (fstate == F_IDLE && was != F_IDLE)
            was = -1;                   // a fetch ended: drawn at once
    }
    if (fstate == F_RECV)
        tcp_close(handle, 1);
    scr_cls();
    return 0;
}
