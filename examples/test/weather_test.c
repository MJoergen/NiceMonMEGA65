// The test of weather_parse.c on the host (Makefile, make test): the
// answers of the files in the directory given, two of which wttr.in gave,
// the settings, the request, and the UTF-8. It prints a line for each
// check that fails, and the count, and exits with 1 when one does.
//
// Usage: weather_test DIR
#include <stdio.h>
#include <string.h>
#include "../weather_parse.h"

static int passed, failed;

static void check(const char *name, int ok)
{
    if (ok)
        passed++;
    else {
        failed++;
        printf("FAIL: %s\n", name);
    }
}

static void check_str(const char *name, const char *got, const char *want)
{
    check(name, strcmp(got, want) == 0);
    if (strcmp(got, want) != 0)
        printf("      got \"%s\", expected \"%s\"\n", got, want);
}

// The answer of a file, parsed.
static int parse_file(const char *dir, const char *name, struct weather *w, struct answer *a)
{
    char path[512], buf[2048];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "rb");
    if (!f) {
        printf("FAIL: cannot open %s\n", path);
        failed++;
        return 999;
    }
    unsigned n = (unsigned)fread(buf, 1, sizeof buf, f);
    fclose(f);
    return weather_parse(buf, n, w, a);
}

static void answers(const char *dir)
{
    struct weather w;
    struct answer a;
    check("ok.http: parsed", parse_file(dir, "ok.http", &w, &a) == W_OK);
    check_str("ok.http: place", w.place, "Copenhagen");
    check_str("ok.http: condition", w.cond, "Patchy rain nearby");
    check_str("ok.http: temperature, with the degree sign of ISO 8859-1", w.temp, "+8\xB0" "C");
    char wind[] = {(char)(G_ARROW + 2), '1', '9', 'k', 'm', '/', 'h', 0};
    check_str("ok.http: wind, with the arrow to the east", w.wind, wind);
    check_str("ok.http: humidity", w.humid, "77%");

    check("zurich.http: parsed", parse_file(dir, "zurich.http", &w, &a) == W_OK);
    check_str("zurich.http: the u with umlaut of ISO 8859-1", w.place, "Z\xFCrich");
    char wind2[] = {(char)(G_ARROW + 7), '5', 'k', 'm', '/', 'h', 0};
    check_str("zurich.http: the arrow to the south-west", w.wind, wind2);

    check("lf.http: lines that end in LF alone, no Content-Length",
          parse_file(dir, "lf.http", &w, &a) == W_OK);
    check_str("lf.http: blanks around a field dropped", w.cond, "Light snow");
    check_str("lf.http: place", w.place, "Oslo");
    char wind3[] = {(char)(G_ARROW + 4), ' ', '7', 'k', 'm', '/', 'h', 0};
    check_str("lf.http: the arrow to the north-west", w.wind, wind3);
    check_str("lf.http: the humidity before the newline", w.humid, "93%");

    check("unknown.http: status 500", parse_file(dir, "unknown.http", &w, &a) == W_STATUS &&
          a.status == 500);
    check_str("unknown.http: the body's first line", a.text,
              "location not found: location not found");

    check("redirect.http: status 301", parse_file(dir, "redirect.http", &w, &a) == W_STATUS &&
          a.status == 301);
    check_str("redirect.http: the Location, cut to W_TEXT", a.text,
              "https://wttr.in/Copenhagen?format=%l|%C");

    check("short.http: a body shorter than Content-Length",
          parse_file(dir, "short.http", &w, &a) == W_SHORT);
    check("cut.http: no end of the headers", parse_file(dir, "cut.http", &w, &a) == W_SHORT);
    check("fields.http: not 5 fields", parse_file(dir, "fields.http", &w, &a) == W_FIELDS);
    check_str("fields.http: the text", a.text, "Sorry, we are running out of queries");
    check("fields.http: no fields kept", w.place[0] == 0);
    check("nohttp.http: no status line", parse_file(dir, "nohttp.http", &w, &a) == W_NOHTTP);
    check("an empty answer", weather_parse("", 0, &w, &a) == W_NOHTTP);
    const char six[] = "HTTP/1.0 200 OK\r\n\r\na|b|c|d|e|f\n";
    check("six fields", weather_parse(six, sizeof six - 1, &w, &a) == W_FIELDS);
}

static void settings(void)
{
    struct cfg c;
    check("no file: the defaults", cfg_parse(&c, "", 0) == 0 && strcmp(c.host, "wttr.in") == 0 &&
          c.port == 80 && c.place[0] == 0 && c.units == 0);
    const char *t = "# The weather\r\nplace  San Francisco  \r\n\r\nUNITS M\r\n"
                    "server 10.0.0.2:8080 # the proxy\r\n";
    check("a file with comments, blanks, and CR LF", cfg_parse(&c, t, (unsigned)strlen(t)) == 0);
    check_str("place", c.place, "San Francisco");
    check_str("server", c.host, "10.0.0.2");
    check("port", c.port == 8080);
    check("units", c.units == 'm');
    t = "place Oslo\nwind strong\nserver x:0\nserver y:65536\nserver :80\nunits k\nserver h";
    check("the first bad line is 2", cfg_parse(&c, t, (unsigned)strlen(t)) == 2);
    check_str("the good lines kept", c.place, "Oslo");
    check_str("the last server", c.host, "h");
    check("its port 80", c.port == 80);
    char longp[200];
    memset(longp, 'a', sizeof longp);
    memcpy(longp, "place ", 6);
    check("a place too long", cfg_parse(&c, longp, sizeof longp) == 1 && c.place[0] == 0);
}

static void requests(void)
{
    struct cfg c;
    char buf[256];
    cfg_parse(&c, "", 0);
    weather_request(&c, buf, sizeof buf);
    check_str("the request with no place", buf,
              "GET /?format=%l|%C|%t|%w|%h HTTP/1.0\r\nHost: wttr.in\r\n"
              "User-Agent: curl/8\r\nConnection: close\r\n\r\n");
    const char *t = "place New York/\xC3\xBC\nunits u\nserver example.org:81\n";
    cfg_parse(&c, t, (unsigned)strlen(t));
    unsigned n = weather_request(&c, buf, sizeof buf);
    check_str("the request with a place, units, and a server", buf,
              "GET /New+York%2F%C3%BC?format=%l|%C|%t|%w|%h&u HTTP/1.0\r\nHost: example.org\r\n"
              "User-Agent: curl/8\r\nConnection: close\r\n\r\n");
    check("its length", n == strlen(buf));
    check("a buffer too small", weather_request(&c, buf, 40) == 0);
}

static void utf8(void)
{
    char out[8];
    utf8_to_screen("ab\x01\x7F" "c", 5, out, sizeof out);
    check_str("control codes as ?", out, "ab??c");
    utf8_to_screen("\xE2\x82\xAC\xF0\x9F\x8C\xA7\xEF\xB8\x8F", 10, out, sizeof out);
    check_str("the euro and an emoji as ?, its variation selector dropped", out, "??");
    utf8_to_screen("\xE2\x86", 2, out, sizeof out);
    check_str("a sequence cut short", out, "?");
    utf8_to_screen("\x80" "a", 2, out, sizeof out);
    check_str("a lone continuation byte", out, "?a");
    utf8_to_screen("abcdefghij", 10, out, sizeof out);
    check_str("cut to the size", out, "abcdefg");
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: weather_test DIR\n");
        return 2;
    }
    answers(argv[1]);
    settings();
    requests();
    utf8();
    printf("%d of %d checks passed\n", passed, passed + failed);
    return failed != 0;
}
