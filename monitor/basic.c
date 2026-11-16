// BASIC in the ROM (issue #54, doc/BASIC.md), stage 1 (issue #112): the
// shell. It is part of the ROM's C code (INTERNALS.md, "C in the ROM"),
// with fat32.c and clock.c. The main loop of basic.nasm reads a line, and
// basic_line runs it: a keyword, in either case, and its arguments, each
// a number in decimal, or in hex after 0x, or a string in quotes, with
// commas between them. The statements are the monitor's commands
// (doc/BASIC.md, "The main loop"), each on the routine that the command
// had, which basic_line calls through its stub in basic.nasm. There are
// no expressions, no variables, and no stored program yet.
//
// The line is words of the RAM, one character each, so the code reads it
// with nice_peek, and ends a string in it with a 0 in place of its
// closing quote, which the routines take as they took the monitor's
// names. The keywords, the messages, and the lines of HELP are packed
// texts of basic.nasm, which it reads through the byte window, so that
// they take no RAM.
//
// A line that is no statement gives "Syntax error", and the lines of
// HELP of its statement, or "Syntax error; HELP lists the statements"
// when its first word is no keyword, and a number that does not fit a
// word gives "Illegal quantity". A keyword is a whole word: LOADX is no
// LOAD. The errors of the routines are theirs, such as "Not an IP
// address".

#include <nice.h>

#define TEXT_B 0x20000000u  // the byte window: byte A of the memory at TEXT_B+A

// The routines of the statements, through their stubs in basic.nasm.
// A string is the word address of its first character, and ends with a
// 0.
void st_sys(unsigned addr);
void st_lines(void);
void st_load(unsigned name);
void st_tftp(unsigned ip, unsigned name, unsigned list);
void st_save(unsigned name, unsigned addr, unsigned n);
void st_delete(unsigned name);
void st_dir(unsigned slot);
void st_ip(unsigned s);
void st_dhcp(void);
void st_mac(unsigned s);
void st_ntp(unsigned server, unsigned zone);
void st_baud(unsigned rate, unsigned given);
void st_dump(unsigned addr, unsigned n, unsigned given);
void st_dis(unsigned addr, unsigned n, unsigned given);
void st_cls(void);
void st_ver(void);
void st_help(void);
void st_halt(void);
void bas_msg(unsigned m);
void bas_puts(unsigned text);
unsigned bas_words(void);
unsigned bas_help(void);
void clock_cmd(unsigned p);

// The keywords, in the order of KEYWORDS in basic.nasm
enum { K_SYS, K_LOAD, K_SAVE, K_DELETE, K_DIR, K_IP, K_DHCP, K_MAC, K_TIME, K_NTP, K_BAUD,
       K_DUMP, K_DIS, K_CLS, K_VER, K_HELP, K_HALT };
// The messages, in the order of BAS_MSGS in basic.nasm
enum { M_SYNTAX, M_UNKNOWN, M_QUANT, M_NOTBIN, M_TFTPSAVE };

static unsigned p;      // the next character of the line
static int quant;       // a number did not fit a word

static unsigned peek(unsigned a)
{
    return nice_peek(a);
}

static unsigned up(unsigned c)
{
    return c - 'a' < 26 ? c - 32 : c;
}

static int alnum(unsigned c)
{
    return up(c) - 'A' < 26 || c - '0' < 10;
}

static void blanks(void)
{
    while (peek(p) == ' ')
        p++;
}

// 1 when only blanks are left
static int end(void)
{
    blanks();
    return !peek(p);
}

// 1, with p after it, when a comma follows
static int comma(void)
{
    blanks();
    if (peek(p) != ',')
        return 0;
    p++;
    return 1;
}

// The keyword at p: its K_ number, with p after it, or -1
static int keyword(void)
{
    unsigned w = bas_words();
    for (int k = 0; peek(w); k++) {
        unsigned i = p, c;
        while ((c = peek(w)) > ' ' && up(peek(i)) == c) {
            w++;
            i++;
        }
        if (c <= ' ' && !alnum(peek(i))) {
            p = i;
            return k;
        }
        while (peek(w) > ' ')
            w++;
        if (peek(w))
            w++;
    }
    return -1;
}

// A number at p, in decimal, or in hex after 0x: 1 and *v, with p after
// it, or 0 when there is none, or when it does not fit a word, which
// sets quant
static int number(unsigned *v)
{
    unsigned base = 10, n = 0, digits = 0;
    blanks();
    if (peek(p) - '0' >= 10)
        return 0;
    if (peek(p) == '0' && up(peek(p + 1)) == 'X') {
        base = 16;
        p += 2;
    }
    for (;; p++, digits++) {
        unsigned c = up(peek(p));
        unsigned d = c - '0' < 10 ? c - '0' : c - 'A' < 6 ? c - 'A' + 10 : 16;
        if (d >= base)
            break;
        if (n > (0xFFFFFFFFu - d) / base)
            quant = 1;
        n = n * base + d;
    }
    if (!digits || alnum(peek(p)) || quant)
        return 0;
    *v = n;
    return 1;
}

// A string at p in quotes: 1 and *s, its first character, with p after
// it, and a 0 at its closing quote, or 0 when there is none. A string
// that the line ends without a closing quote ends with the line.
static int string(unsigned *s)
{
    blanks();
    if (peek(p) != '"')
        return 0;
    *s = ++p;
    while (peek(p) && peek(p) != '"')
        p++;
    if (peek(p))
        nice_poke(p++, 0);
    return 1;
}

// The end of the string s: its 0
static unsigned send(unsigned s)
{
    while (peek(s))
        s++;
    return s;
}

// 1 when the name s ends with .BIN, in either case
static int isbin(unsigned s)
{
    unsigned e = send(s);
    if (e - s < 4)
        return 0;
    for (unsigned i = 0; i < 4; i++)
        if (up(peek(e - 4 + i)) != (unsigned)".BIN"[i])
            return 0;
    return 1;
}

// The statement k, with p after its keyword: 1 when it ran, or 0 when
// the rest of the line does not fit it
static int statement(int k)
{
    unsigned a = 0, n = 0, s, t = 0, given = 0;
    switch (k) {
    case K_SYS:
        if (!number(&a) || !end())
            return 0;
        st_sys(a);
        return 1;
    case K_LOAD:
        if (end()) {
            st_lines();
            return 1;
        }
        if (!string(&s) || (comma() && !string(&t)) || !end())
            return 0;
        if (!isbin(s))
            bas_msg(M_NOTBIN);
        else if (t)
            st_tftp(t, s, 0);
        else
            st_load(s);
        return 1;
    case K_SAVE:
        if (!string(&s) || !comma())
            return 0;
        if (string(&t)) {
            if (!end())
                return 0;
            bas_msg(M_TFTPSAVE);
            return 1;
        }
        if (!number(&a) || !comma() || !number(&n) || !end())
            return 0;
        // A name without an extension gets .BIN. The four characters
        // and the 0 go from the closing quote, over the address and the
        // count, which take four characters at least, so they stay in
        // the line.
        t = send(s);
        for (unsigned i = s; i < t; i++)
            if (peek(i) == '.')
                goto save;
        for (unsigned i = 0; i < 5; i++)
            nice_poke(t + i, (unsigned)".BIN"[i]);
    save:
        st_save(s, a, n);
        return 1;
    case K_DELETE:
        if (!string(&s) || !end())
            return 0;
        st_delete(s);
        return 1;
    case K_DIR:
        if (end()) {
            st_dir(0xFFFFFFFFu);
            return 1;
        }
        if (number(&a)) {
            if (!end())
                return 0;
            st_dir(a);
            return 1;
        }
        if (!string(&s) || (comma() && !string(&t)) || !end())
            return 0;
        st_tftp(s, t, 1);
        return 1;
    case K_IP:
    case K_MAC:
    case K_TIME:
        s = 0;
        if (!end() && (!string(&s) || !end()))
            return 0;
        if (k == K_IP)
            st_ip(s);
        else if (k == K_MAC)
            st_mac(s);
        else
            clock_cmd(s ? s : p);
        return 1;
    case K_NTP:
        s = 0;
        if (!end() && (!string(&s) || (comma() && !string(&t)) || !end()))
            return 0;
        st_ntp(s && peek(s) ? s : 0, t);
        return 1;
    case K_BAUD:
        if (number(&a))
            given = 1;
        if (quant || !end())
            return 0;
        st_baud(a, given);
        return 1;
    case K_DUMP:
    case K_DIS:
        if (number(&a))
            given = 1;
        if (quant)
            return 0;
        if (comma()) {
            if (!number(&n))
                return 0;
            given |= 2;
        }
        if (!end())
            return 0;
        if (k == K_DUMP)
            st_dump(a, n, given);
        else
            st_dis(a, n, given);
        return 1;
    default:
        if (!end())
            return 0;
        if (k == K_DHCP)
            st_dhcp();
        else if (k == K_CLS)
            st_cls();
        else if (k == K_VER)
            st_ver();
        else if (k == K_HELP)
            st_help();
        else
            st_halt();
        return 1;
    }
}

// "Syntax error", and the lines of HELP that start with keyword k and a
// blank
static void usage(int k)
{
    unsigned w = bas_words();
    bas_msg(M_SYNTAX);
    while (k--)
        while (peek(w++) != ' ')
            ;
    for (unsigned h = bas_help(), e; (e = peek(h)); h++) {
        unsigned t = TEXT_B + 4 * e, i = 0;
        while (peek(w + i) > ' ' && peek(t + i) == peek(w + i))
            i++;
        if (peek(w + i) <= ' ' && peek(t + i) == ' ')
            bas_puts(e);
    }
}

// basic_line: the line at line, run. 0 when it has only blanks, and
// else 1.
int basic_line(unsigned line)
{
    p = line;
    quant = 0;
    if (end())
        return 0;
    int k = keyword();
    if (k < 0)
        bas_msg(M_UNKNOWN);
    else if (!statement(k)) {
        if (quant)
            bas_msg(M_QUANT);
        else
            usage(k);
    }
    return 1;
}
