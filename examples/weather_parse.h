// The text of the weather display (weather.c): its settings file, the
// request to wttr.in, and the parse of the answer. It calls nothing of
// the board, so that test/weather_test.c checks it on the host
// (Makefile, make test).
#ifndef WEATHER_PARSE_H
#define WEATHER_PARSE_H

// The codes of the glyphs that weather.c draws in the font RAM, which are
// blank in Spleen: the halves of a block and the whole block for the
// large clock, and the arrows of the wind.
enum {
    G_UPPER = 0x80, // the upper half of a cell
    G_LOWER = 0x81, // the lower half
    G_FULL = 0x82,  // the whole cell
    G_ARROW = 0x83, // 8 arrows: to the west, north, east, south, then
                    // north-west, north-east, south-east, south-west,
                    // as U+2190 to U+2193 and U+2196 to U+2199
};

#define CFG_PLACE 64  // the bytes of a place's name, with its 0
#define CFG_HOST 64   // of the server's name

// The settings, from WEATHER.CFG of the card's folder NICE.
struct cfg {
    char place[CFG_PLACE]; // empty: wttr.in guesses from the address
    char host[CFG_HOST];   // wttr.in, or another server
    unsigned port;         // 80
    char units;            // 0 the server's choice, 'm' metric, 'u' USCS
};

// The settings of a file of lines "key value", with the keys place,
// server (a name or an address, with :port or without), and units (m or
// u); # starts a comment, and blanks around a value are dropped. cfg
// first gets the defaults. Returns 0, or the number of the first line
// that is not understood, whose setting is left out.
int cfg_parse(struct cfg *cfg, const char *text, unsigned n);

// The HTTP request for the weather, with a 0 at its end, in buf of size
// bytes. Returns its length, or 0 when it does not fit.
unsigned weather_request(const struct cfg *cfg, char *buf, unsigned size);

#define W_TEXT 40     // the bytes of each field, with its 0

// The weather of an answer, each field in the codes of the screen.
struct weather {
    char place[W_TEXT];
    char cond[W_TEXT];
    char temp[W_TEXT];
    char wind[W_TEXT];
    char humid[W_TEXT];
};

// The errors of weather_parse, below 0 and below the monitor's.
enum {
    W_OK = 0,
    W_SHORT = -100,     // no end of the headers, or a body cut short
    W_NOHTTP = -101,    // no status line of HTTP
    W_STATUS = -102,    // a status other than 200; see status and text
    W_FIELDS = -103,    // a body that is not 5 fields; see text
};

// The result of the parse of an answer.
struct answer {
    int status;            // the status of HTTP, such as 200
    char text[W_TEXT];     // with W_STATUS the Location of a redirect,
                           // or else the start of the body; with
                           // W_FIELDS the start of the body
};

// The whole answer of the server, n bytes: the status line, the headers,
// and the body, which is the 5 fields of the request separated by |.
// Returns W_OK with w filled, or an error with a filled.
int weather_parse(const char *buf, unsigned n, struct weather *w, struct answer *a);

// Bytes of UTF-8 to the codes of the screen, ISO 8859-1, and the arrows
// to G_ARROW + k, up to size - 1 codes and a 0. Blanks at both ends are
// dropped, control codes and anything else outside ISO 8859-1 become ?.
void utf8_to_screen(const char *s, unsigned n, char *out, unsigned size);

#endif
