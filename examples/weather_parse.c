// The text of the weather display: the settings, the request, and the
// parse of the answer (weather_parse.h).
#include <string.h>
#include "weather_parse.h"

// The format of wttr.in (github.com/chubin/wttr.in): the place, the
// condition, the temperature, the wind, and the humidity, separated by |.
#define FORMAT "%l|%C|%t|%w|%h"

static int is_blank(char c)
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

static char lower(char c)
{
    return c >= 'A' && c <= 'Z' ? (char)(c - 'A' + 'a') : c;
}

// Whether the n bytes at s are the key k, in either case.
static int is_key(const char *s, unsigned n, const char *k)
{
    unsigned i;
    for (i = 0; i < n && k[i]; i++)
        if (lower(s[i]) != k[i])
            return 0;
    return i == n && !k[i];
}

// The n bytes at s, with a 0, to out of size bytes. 0 when they do not fit.
static int copy(char *out, unsigned size, const char *s, unsigned n)
{
    if (n >= size)
        return 0;
    memcpy(out, s, n);
    out[n] = 0;
    return 1;
}

// One line of the settings, without its end. 1 when it is understood.
static int cfg_line(struct cfg *cfg, const char *s, unsigned n)
{
    unsigned i = 0, k, v, e;
    for (e = 0; e < n && s[e] != '#'; e++)
        ;
    while (e > 0 && is_blank(s[e - 1]))
        e--;
    while (i < e && is_blank(s[i]))
        i++;
    if (i == e)
        return 1;                       // a blank line, or a comment
    for (k = i; k < e && !is_blank(s[k]); k++)
        ;
    for (v = k; v < e && is_blank(s[v]); v++)
        ;
    if (is_key(s + i, k - i, "place"))
        return copy(cfg->place, CFG_PLACE, s + v, e - v);
    if (is_key(s + i, k - i, "units")) {
        if (e - v != 1 || (lower(s[v]) != 'm' && lower(s[v]) != 'u'))
            return 0;
        cfg->units = lower(s[v]);
        return 1;
    }
    if (is_key(s + i, k - i, "server")) {
        unsigned c, port = 0;
        for (c = v; c < e && s[c] != ':'; c++)
            ;
        if (c == v)
            return 0;
        if (c < e) {
            if (c + 1 == e)
                return 0;
            for (unsigned d = c + 1; d < e; d++) {
                if (s[d] < '0' || s[d] > '9')
                    return 0;
                port = port * 10 + (unsigned)(s[d] - '0');
                if (port > 65535)
                    return 0;
            }
            if (port == 0)
                return 0;
        }
        if (!copy(cfg->host, CFG_HOST, s + v, c - v))
            return 0;
        cfg->port = port ? port : 80;
        return 1;
    }
    return 0;
}

int cfg_parse(struct cfg *cfg, const char *text, unsigned n)
{
    int bad = 0, line = 1;
    memset(cfg, 0, sizeof *cfg);
    strcpy(cfg->host, "wttr.in");
    cfg->port = 80;
    for (unsigned i = 0; i < n; line++) {
        unsigned e = i;
        while (e < n && text[e] != '\n')
            e++;
        if (!cfg_line(cfg, text + i, e - i) && !bad)
            bad = line;
        i = e + 1;
    }
    return bad;
}

// Appends s to buf at *n, keeping room for the 0. 0 when it does not fit.
static int put(char *buf, unsigned size, unsigned *n, const char *s)
{
    unsigned k = (unsigned)strlen(s);
    if (*n + k >= size)
        return 0;
    memcpy(buf + *n, s, k);
    *n += k;
    buf[*n] = 0;
    return 1;
}

unsigned weather_request(const struct cfg *cfg, char *buf, unsigned size)
{
    static const char hex[] = "0123456789ABCDEF";
    unsigned n = 0;
    if (size == 0)
        return 0;
    buf[0] = 0;
    if (!put(buf, size, &n, "GET /"))
        return 0;
    // The place in the path: a blank as +, and every byte but a letter, a
    // digit, and -._~ as %XX, so that UTF-8 goes as it is.
    for (const char *p = cfg->place; *p; p++) {
        unsigned char c = (unsigned char)*p;
        char e[4] = {(char)c, 0, 0, 0};
        if (c == ' ')
            e[0] = '+';
        else if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                   (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~')) {
            e[0] = '%';
            e[1] = hex[c >> 4];
            e[2] = hex[c & 15];
        }
        if (!put(buf, size, &n, e))
            return 0;
    }
    if (!put(buf, size, &n, "?format=" FORMAT))
        return 0;
    if (cfg->units && !put(buf, size, &n, cfg->units == 'm' ? "&m" : "&u"))
        return 0;
    if (!put(buf, size, &n, " HTTP/1.0\r\nHost: ") || !put(buf, size, &n, cfg->host))
        return 0;
    // curl's user agent, without which wttr.in answers with its page of
    // HTML; and the close, which ends the answer at the end of its body.
    if (!put(buf, size, &n, "\r\nUser-Agent: curl/8\r\nConnection: close\r\n\r\n"))
        return 0;
    return n;
}

void utf8_to_screen(const char *s, unsigned n, char *out, unsigned size)
{
    unsigned i = 0, o = 0;
    const unsigned char *u = (const unsigned char *)s;
    while (n > 0 && is_blank(s[n - 1]))
        n--;
    while (i < n && is_blank(s[i]))
        i++;
    while (i < n && o + 1 < size) {
        unsigned c = u[i], len = 1, cp = c;
        if (c >= 0xC0 && c < 0xE0) {
            len = 2;
            cp = c & 0x1F;
        } else if (c >= 0xE0 && c < 0xF0) {
            len = 3;
            cp = c & 0x0F;
        } else if (c >= 0xF0 && c < 0xF8) {
            len = 4;
            cp = c & 0x07;
        } else if (c >= 0x80) {
            cp = '?';                   // a byte that starts no sequence
        }
        unsigned k;
        for (k = 1; k < len && i + k < n && (u[i + k] & 0xC0) == 0x80; k++)
            cp = (cp << 6) | (u[i + k] & 0x3F);
        if (k < len) {
            cp = '?';                   // a sequence cut short
            len = k;
        }
        i += len;
        if (cp >= 0x2190 && cp <= 0x2193)
            cp = G_ARROW + (cp - 0x2190);
        else if (cp >= 0x2196 && cp <= 0x2199)
            cp = G_ARROW + 4 + (cp - 0x2196);
        else if (cp == 0xFE0F || cp == 0x200D)
            continue;                   // a variation selector, a joiner
        else if (cp == '\t')
            cp = ' ';
        else if (cp < 0x20 || (cp >= 0x7F && cp < 0xA0) || cp > 0xFF)
            cp = '?';
        out[o++] = (char)cp;
    }
    out[o] = 0;
}

// The value of the header name in the headers h of n bytes, which start
// after the status line, to *v and *vn. 1 when it is there.
static int header(const char *h, unsigned n, const char *name, const char **v, unsigned *vn)
{
    unsigned k = (unsigned)strlen(name);
    for (unsigned i = 0; i < n;) {
        unsigned e = i;
        while (e < n && h[e] != '\n')
            e++;
        if (e - i > k && h[i + k] == ':' && is_key(h + i, k, name)) {
            unsigned b = i + k + 1, t = e;
            while (b < t && is_blank(h[b]))
                b++;
            while (t > b && is_blank(h[t - 1]))
                t--;
            *v = h + b;
            *vn = t - b;
            return 1;
        }
        i = e + 1;
    }
    return 0;
}

// The first line of the body, to a->text.
static void first_line(const char *b, unsigned n, struct answer *a)
{
    unsigned e = 0;
    while (e < n && b[e] != '\n')
        e++;
    utf8_to_screen(b, e, a->text, sizeof a->text);
}

int weather_parse(const char *buf, unsigned n, struct weather *w, struct answer *a)
{
    unsigned i, hdr, body;
    memset(w, 0, sizeof *w);
    memset(a, 0, sizeof *a);
    // The status line: HTTP/1.x, a blank, and three digits.
    if (n < 12 || memcmp(buf, "HTTP/1.", 7) != 0 || buf[8] != ' ')
        return W_NOHTTP;
    for (i = 9; i < 12; i++) {
        if (buf[i] < '0' || buf[i] > '9')
            return W_NOHTTP;
        a->status = a->status * 10 + (buf[i] - '0');
    }
    for (hdr = 12; hdr < n && buf[hdr] != '\n'; hdr++)
        ;
    hdr++;
    // The headers end at an empty line, CR LF or LF alone.
    int ended = 0;
    for (body = hdr; body < n && !ended;) {
        unsigned e = body;
        while (e < n && buf[e] != '\n')
            e++;
        if (e == n)
            return W_SHORT;
        ended = e == body || (e == body + 1 && buf[body] == '\r');
        body = e + 1;
    }
    if (!ended)
        return W_SHORT;
    const char *v;
    unsigned vn, len = n - body;
    if (header(buf + hdr, body - hdr, "content-length", &v, &vn)) {
        unsigned cl = 0;
        for (i = 0; i < vn && v[i] >= '0' && v[i] <= '9'; i++)
            cl = cl * 10 + (unsigned)(v[i] - '0');
        if (i == 0 || i != vn)
            return W_NOHTTP;
        if (len < cl)
            return W_SHORT;
        len = cl;
    }
    const char *b = buf + body;
    if (a->status != 200) {
        if (a->status >= 300 && a->status < 400 &&
            header(buf + hdr, body - hdr, "location", &v, &vn))
            utf8_to_screen(v, vn, a->text, sizeof a->text);
        else
            first_line(b, len, a);
        return W_STATUS;
    }
    // The 5 fields, on the first line of the body.
    char *f[5] = {w->place, w->cond, w->temp, w->wind, w->humid};
    unsigned k = 0, s = 0, e;
    for (e = 0; e < len && b[e] != '\n'; e++)
        if (b[e] == '|') {
            if (k == 4)
                break;
            utf8_to_screen(b + s, e - s, f[k++], W_TEXT);
            s = e + 1;
        }
    if (k != 4 || (e < len && b[e] == '|')) {
        memset(w, 0, sizeof *w);
        first_line(b, len, a);
        return W_FIELDS;
    }
    utf8_to_screen(b + s, e - s, f[4], W_TEXT);
    return W_OK;
}
