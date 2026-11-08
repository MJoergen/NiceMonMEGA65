// FAT32 for the ROM: reading, in the folder FOLDER of the root directory
// (issues #58 and #91, doc/SDCARD.md, "The file system"). It is part of the ROM's C code
// (README.md, "C in the ROM"), and the dispatch table's entries fs_mount,
// fs_open, fs_read, fs_readdir, and fs_close jump to its functions
// fat_mount, fat_open, fat_read, fat_readdir, and fat_close, which take
// the arguments of the entries: addresses are NICE word addresses, not C
// pointers, read and written with nice_peek and nice_poke. fat_load reads
// a .bin file for the monitor's load command.
//
// The card is the one in the slot of the last fat_mount. A card is FAT32
// when its sector 0 is a FAT32 boot sector, or an MBR whose first
// partition of type 0x0B or 0x0C has one. A FAT12, FAT16, or exFAT
// boot sector, by the count of clusters of Microsoft's specification, or
// exFAT's name, gives an error of its own. The mount is dropped, and with
// it the open files, when the selected slot is no longer the mounted one,
// or its card is not ready or has changed. fat_open mounts again when it
// finds no mount: the slot of the last mount, or after reset slot 0, or
// slot 1 when slot 0 has no card and the board has a slot 1.
//
// The files are those of the folder FOLDER, NICE unless the build sets
// another (make FOLDER=NAME), as a card may be shared by several cores,
// each with a root folder of its own. A mount looks the folder up in the
// root directory, and fails without it, so nothing reaches the root's
// files or another core's.
//
// The caches are one sector of the FAT, and one sector for each of the
// two files that may be open at once. They are in the RAM of the C code,
// 128 words each, 4 bytes to a word, as sd_read and the SD controller have
// them. Errors are negative: those of the SD controller, -1 to -8, as
// sd_init and sd_read give them, and those below, from -16.

#include <nice.h>

// The monitor's sector routines, through its shims, which convert buf
// from a byte address of the C code's memory to a NICE word address
int fat_sd_init(unsigned slot);
int fat_sd_read(unsigned lba, unsigned *buf);

#define SD_CSR 0xFFFFFFA0u
#define SD_SELECT 0xFFFFFFA4u
#define SD_SLOTS 0xFFFFFFA6u
#define SD_READY 0x08u
#define SD_CHANGED 0x10u

#define E_NOCARD -1     // the SD controller's error 1
#define E_NOFS -16      // no FAT32 file system
#define E_FAT12 -17     // FAT12
#define E_FAT16 -18     // FAT16
#define E_EXFAT -19     // exFAT
#define E_NAME -20      // not an 8.3 name
#define E_NOFILE -21    // no file of that name
#define E_ISDIR -22     // a directory, opened as a file
#define E_TOOMANY -23   // two files open already
#define E_HANDLE -24    // not an open file, or not of the right kind
#define E_MODE -25      // a mode that is not 0 or 2
#define E_BADFAT -26    // a cluster outside the volume
#define E_SLOT -27      // no such slot
#define E_CHANGED -28   // the card changed, or the mount was dropped
#define E_NOFOLDER -29  // no folder FOLDER in the root directory

// The folder of NiceMon's files, an 8.3 name of up to 8 characters in
// upper case, which the Makefile checks
#ifndef FOLDER
#define FOLDER "NICE"
#endif

#define END 0x0FFFFFF8u  // a FAT entry from here ends a chain
#define FILES 2

static struct {
    int mounted;
    int ever;           // a mount has been tried since reset
    unsigned slot;
    unsigned fat;       // the first sector of the first FAT
    unsigned data;      // the first sector of cluster 2
    unsigned spc;       // sectors per cluster
    unsigned root;      // the first cluster of the root directory
    unsigned dir;       // the first cluster of the folder FOLDER
    unsigned top;       // the cluster after the last
} vol;

static unsigned fatbuf[128];
static unsigned fatlba = ~0u;   // the sector in fatbuf

static struct file {
    int open;
    int dir;            // a directory, read with fat_readdir
    int done;           // the directory's end was found
    unsigned first;     // the first cluster, 0 for an empty file
    unsigned clus;      // the cluster that holds the byte at cpos
    unsigned cpos;      // the byte offset of the start of clus
    unsigned pos;       // the byte offset of the next byte
    unsigned size;
    unsigned lba;       // the sector in buf
    unsigned buf[128];
} files[FILES];

static unsigned u16(const unsigned char *p)
{
    return p[0] | p[1] << 8;
}

static unsigned u32(const unsigned char *p)
{
    return p[0] | p[1] << 8 | p[2] << 16 | (unsigned)p[3] << 24;
}

static void drop(void)
{
    vol.mounted = 0;
    fatlba = ~0u;
    for (int i = 0; i < FILES; i++)
        files[i].open = 0;
}

// The mount still stands: the mounted slot is selected, and its card is
// ready and has not changed. Otherwise the mount is dropped.
static int valid(void)
{
    if (vol.mounted) {
        unsigned csr = nice_peek(SD_CSR);
        if (nice_peek(SD_SELECT) == vol.slot && (csr & SD_READY) && !(csr & SD_CHANGED))
            return 1;
        drop();
    }
    return 0;
}

// What the sector in b is: 0 for a FAT32 boot sector, an error for
// another file system, and 1 for no boot sector, or one without the 55 AA
// signature.
static int kind(const unsigned char *b)
{
    static const char exfat[8] = "EXFAT   ";
    int ex = 1;
    for (int i = 0; i < 8; i++)
        ex &= b[3 + i] == (unsigned char)exfat[i];
    if (ex)
        return E_EXFAT;
    unsigned spc = b[13], rsvd = u16(b + 14), nfats = b[16];
    unsigned fatsz = u16(b + 22) ? u16(b + 22) : u32(b + 36);
    unsigned total = u16(b + 19) ? u16(b + 19) : u32(b + 32);
    if ((b[0] != 0xEB && b[0] != 0xE9) || u16(b + 11) != 512 || spc == 0 ||
        (spc & (spc - 1)) || rsvd == 0 || nfats == 0 || fatsz == 0 ||
        b[510] != 0x55 || b[511] != 0xAA)
        return 1;
    // The sectors before the data, the reserved ones, the FATs, and FAT12
    // and FAT16's root directory, must leave room for the data. A damaged
    // sector can say FATs of billions of sectors, so the FATs are checked
    // against the room before their size is summed, which could wrap and
    // let a cluster count past the volume through.
    unsigned rootsecs = (u16(b + 17) * 32 + 511) / 512;
    unsigned fixed = rsvd + rootsecs;
    if (total <= fixed || fatsz > (total - fixed) / nfats)
        return E_NOFS;
    unsigned meta = fixed + nfats * fatsz;
    if (total <= meta)
        return E_NOFS;
    unsigned clusters = (total - meta) / spc;
    if (clusters < 4085)
        return E_FAT12;
    if (clusters < 65525)
        return E_FAT16;
    if (u16(b + 22) || u16(b + 17))
        return E_NOFS;
    return 0;
}

static int find(unsigned first, const unsigned char n[11], unsigned char **e);

// A slot that the system does not have changes nothing.
static int mount(unsigned slot)
{
    unsigned char *b = (unsigned char *)fatbuf;
    if (slot >= nice_peek(SD_SLOTS))
        return E_SLOT;
    drop();
    vol.ever = 1;
    vol.slot = slot;
    int r = fat_sd_init(slot);
    if (r < 0 || (r = fat_sd_read(0, fatbuf)) < 0)
        return r;
    unsigned base = 0;
    int k = kind(b);
    if (k == 1) {
        if (b[510] != 0x55 || b[511] != 0xAA)
            return E_NOFS;
        // The first FAT32 partition, or else the first partition, whose
        // boot sector says what it is
        unsigned other = 0;
        for (int i = 0; i < 4 && !base; i++) {
            const unsigned char *p = b + 446 + 16 * i;
            if (p[4] == 0x0B || p[4] == 0x0C)
                base = u32(p + 8);
            else if (p[4] && !other)
                other = u32(p + 8);
        }
        if (!base && !other)
            return E_NOFS;
        if ((r = fat_sd_read(base ? base : other, fatbuf)) < 0)
            return r;
        k = kind(b);
        if (!base && !k)
            k = E_NOFS;     // FAT32 in a partition of another type
    }
    if (k)
        return k == 1 ? E_NOFS : k;
    vol.spc = b[13];
    vol.fat = base + u16(b + 14);
    vol.data = vol.fat + b[16] * u32(b + 36);
    vol.root = u32(b + 44);
    vol.top = (base + u32(b + 32) - vol.data) / vol.spc + 2;
    fatlba = ~0u;
    if (vol.root < 2 || vol.root >= vol.top)
        return E_BADFAT;
    // The folder: FOLDER padded with blanks, a directory of the root
    unsigned char n[11], *e;
    static const char folder[] = FOLDER;
    for (int k = 0; k < 11; k++)
        n[k] = k < (int)sizeof folder - 1 ? (unsigned char)folder[k] : ' ';
    if ((r = find(vol.root, n, &e)) < 0)
        return r;
    if (r == 0 || !(e[11] & 0x10))
        return E_NOFOLDER;
    vol.dir = u16(e + 20) << 16 | u16(e + 26);
    if (vol.dir < 2 || vol.dir >= vol.top)
        return E_BADFAT;
    vol.mounted = 1;
    return 0;
}

int fat_mount(unsigned slot)
{
    return mount(slot);
}

// The FAT's entry of cluster c in *next, or an error
static int next(unsigned c, unsigned *next)
{
    unsigned lba = vol.fat + (c >> 7);
    if (lba != fatlba) {
        int r = fat_sd_read(lba, fatbuf);
        if (r < 0) {
            fatlba = ~0u;
            return r;
        }
        fatlba = lba;
    }
    *next = fatbuf[c & 127] & 0x0FFFFFFF;
    return 0;
}

// The sector of f that holds the byte at f->pos into f->buf, following
// the chain of clusters. 0, 1 at the end of the chain, or an error.
static int seek(struct file *f)
{
    unsigned bytes = vol.spc * 512;
    while (f->pos - f->cpos >= bytes) {
        unsigned n;
        int r = next(f->clus, &n);
        if (r < 0)
            return r;
        if (n >= END)
            return 1;
        if (n < 2 || n >= vol.top)
            return E_BADFAT;
        f->clus = n;
        f->cpos += bytes;
    }
    unsigned lba = vol.data + (f->clus - 2) * vol.spc + (f->pos - f->cpos) / 512;
    if (lba != f->lba) {
        int r = fat_sd_read(lba, f->buf);
        if (r < 0) {
            f->lba = ~0u;
            return r;
        }
        f->lba = lba;
    }
    return 0;
}

// The open file of handle h of the kind dir, or 0, which closes all when
// the mount was dropped
static struct file *handle(int h, int dir, int *err)
{
    if (h < 0 || h >= FILES || !files[h].open || files[h].dir != dir) {
        *err = E_HANDLE;
        return 0;
    }
    if (!valid()) {
        *err = E_CHANGED;
        return 0;
    }
    return &files[h];
}

// The name at the word address name, one character per word up to a 0
// word, as an 8.3 name in upper case padded with blanks in n, or E_NAME
static int name83(unsigned name, unsigned char n[11])
{
    int i = 0, part = 0, len = 0;
    for (int k = 0; k < 11; k++)
        n[k] = ' ';
    for (;;) {
        unsigned c = nice_peek(name + i++);
        if (c == 0)
            break;
        if (c == '.' && part == 0 && len > 0) {
            part = 1;
            len = 0;
            continue;
        }
        if (c >= 'a' && c <= 'z')
            c -= 0x20;
        if (c <= 0x20 || c >= 0x7F || c == '"' || c == '*' || c == '+' || c == ',' ||
            c == '.' || c == '/' || c == ':' || c == ';' || c == '<' || c == '=' ||
            c == '>' || c == '?' || c == '[' || c == '\\' || c == ']' || c == '|')
            return E_NAME;
        if (len == (part ? 3 : 8))
            return E_NAME;
        n[part ? 8 + len : len] = (unsigned char)c;
        len++;
    }
    return (part == 0 && len == 0) || (part == 1 && len == 0) ? E_NAME : 0;
}

// The next entry of the directory f that is a file or a directory, at e,
// 32 bytes in f->buf: 1, 0 at the end, or an error
static int entry(struct file *f, unsigned char **e)
{
    while (!f->done) {
        int r = seek(f);
        if (r < 0)
            return r;
        if (r == 1)
            break;
        unsigned char *p = (unsigned char *)f->buf + (f->pos & 511);
        f->pos += 32;
        if (p[0] == 0)
            break;
        if (p[0] == 0xE5 || p[11] == 0x0F || (p[11] & 0x08) || p[0] == '.')
            continue;
        *e = p;
        return 1;
    }
    f->done = 1;
    return 0;
}

static void start(struct file *f, unsigned first, int dir, unsigned size);

// The entry of the 8.3 name n in the directory whose first cluster is
// first, at e: 1, 0 when there is none, or an error. The entry is in the
// buffer of a static file, which keeps it until the next call.
static int find(unsigned first, const unsigned char n[11], unsigned char **e)
{
    static struct file d;
    start(&d, first, 1, 0);
    int r;
    while ((r = entry(&d, e)) == 1) {
        int same = 1;
        for (int k = 0; k < 11; k++)
            same &= (k == 0 && (*e)[0] == 0x05 ? 0xE5 : (*e)[k]) == n[k];
        if (same)
            return 1;
    }
    return r;
}

static void start(struct file *f, unsigned first, int dir, unsigned size)
{
    f->open = 1;
    f->dir = dir;
    f->done = 0;
    f->first = first;
    f->clus = first;
    f->cpos = 0;
    f->pos = 0;
    f->size = size;
    f->lba = ~0u;
}

// A mount, the one that stands, or a new one of the slot of the last, or
// after reset of slot 0, or of slot 1 when slot 0 has no card and the
// board has a slot 1, as the MEGA65 has and the Nexys4DDR has not; on a
// board with one slot, slot 0's error stands
static int mounted(void)
{
    if (valid())
        return 0;
    int r;
    if (vol.ever)
        r = mount(vol.slot);
    else if ((r = mount(0)) == E_NOCARD && nice_peek(SD_SLOTS) > 1)
        r = mount(1);
    return r;
}

// A free handle, with its file started as start says, or E_TOOMANY
static int opened(unsigned first, int dir, unsigned size)
{
    for (int h = 0; h < FILES; h++) {
        if (!files[h].open) {
            start(&files[h], first, dir, size);
            return h;
        }
    }
    return E_TOOMANY;
}

int fat_open(unsigned name, int mode)
{
    unsigned char n[11];
    if (mode != 0 && mode != 2)
        return E_MODE;
    int r = mounted();
    if (r < 0)
        return r;
    if (mode == 2) {
        // The folder, the only directory: an empty name, or /
        unsigned c = nice_peek(name);
        if (c && !(c == '/' && nice_peek(name + 1) == 0))
            return E_NAME;
        return opened(vol.dir, 1, 0);
    }
    r = name83(name, n);
    if (r < 0)
        return r;
    unsigned char *e;
    if ((r = find(vol.dir, n, &e)) != 1)
        return r < 0 ? r : E_NOFILE;
    if (e[11] & 0x10)
        return E_ISDIR;
    unsigned first = u16(e + 20) << 16 | u16(e + 26);
    unsigned size = u32(e + 28);
    if (size && (first < 2 || first >= vol.top))
        return E_BADFAT;
    return opened(first, 0, size);
}

int fat_read(int h, unsigned buf, unsigned n)
{
    int err;
    struct file *f = handle(h, 0, &err);
    if (!f)
        return err;
    unsigned done = 0;
    while (done < n && f->pos < f->size) {
        int r = seek(f);
        if (r)
            return r < 0 ? r : E_BADFAT;    // the chain ends before the size
        const unsigned char *b = (const unsigned char *)f->buf;
        unsigned at = f->pos & 511, k = 512 - at;
        if (k > n - done)
            k = n - done;
        if (k > f->size - f->pos)
            k = f->size - f->pos;
        for (unsigned i = 0; i < k; i++)
            nice_poke(buf + done + i, b[at + i]);
        done += k;
        f->pos += k;
    }
    return (int)done;
}

int fat_readdir(int h, unsigned buf)
{
    int err;
    struct file *f = handle(h, 1, &err);
    if (!f)
        return err;
    unsigned char *e;
    int r = entry(f, &e);
    if (r != 1)
        return r;
    unsigned w0 = u32(e);
    if ((w0 & 0xFF) == 0x05)
        w0 ^= 0x05 ^ 0xE5;
    nice_poke(buf, w0);
    nice_poke(buf + 1, u32(e + 4));
    nice_poke(buf + 2, u32(e + 8));
    nice_poke(buf + 3, u32(e + 28));
    return 1;
}

int fat_close(int h)
{
    if (h < 0 || h >= FILES || !files[h].open)
        return E_HANDLE;
    files[h].open = 0;
    return 0;
}

// fat_dir: the folder FOLDER of the card, for the monitor's dir command:
// a row with its name, then a row for each file, its 8.3 name and its size in decimal, and for each
// directory, its name and <DIR>, then the numbers of both. With a slot
// from 0, the card in it is mounted first. 0, or an error.
static void dec(unsigned v, int width)
{
    char d[10];
    int n = 0;
    do {
        d[n++] = (char)('0' + v % 10);
        v /= 10;
    } while (v);
    while (width-- > n)
        nice_putc(' ');
    while (n)
        nice_putc(d[--n]);
}

int fat_dir(int slot)
{
    int r = slot >= 0 ? mount((unsigned)slot) : mounted();
    if (r < 0)
        return r;
    struct file d;
    start(&d, vol.dir, 1, 0);
    unsigned char *e;
    unsigned nfiles = 0, ndirs = 0;
    nice_print("Directory of " FOLDER "\r\n");
    while ((r = entry(&d, &e)) == 1) {
        for (int k = 0; k < 11; k++) {
            if (k == 8)
                nice_putc(' ');
            nice_putc(k == 0 && e[0] == 0x05 ? 0xE5 : e[k]);
        }
        if (e[11] & 0x10) {
            nice_print("  <DIR>");
            ndirs++;
        } else {
            dec(u32(e + 28), 12);
            nfiles++;
        }
        nice_print("\r\n");
    }
    if (r < 0)
        return r;
    nice_print("Files: ");
    dec(nfiles, 0);
    nice_print(", directories: ");
    dec(ndirs, 0);
    nice_print("\r\n");
    return 0;
}

// fat_load: the lines of the open file h, ADDR WORD in hex, written as
// the monitor's l writes them, but that an empty line is passed over and
// the end of the file ends the load. A line is skipped when it is longer
// than LINE_MAX characters, has no address or word of 1 to 8 digits, has
// more after the word than blanks, or its address is below 0x8000 or not
// below end. TAB is a blank, CR, LF, or CR LF ends a line, and other
// control codes and bytes from 0x80 are dropped. The 5 words at stats
// get the words written, the lowest and the highest address, the lines
// skipped, and the number of the first, counted from 1. 0, or an error.
#define LINE_MAX 76
#define PROGRAM 0x8000u

static int hex(const unsigned char *s, int *i, unsigned *v)
{
    int d = 0;
    *v = 0;
    while (s[*i] == ' ')
        (*i)++;
    for (;; d++, (*i)++) {
        unsigned c = s[*i];
        if (c >= '0' && c <= '9')
            c -= '0';
        else if ((c | 0x20) >= 'a' && (c | 0x20) <= 'f')
            c = (c | 0x20) - 'a' + 10;
        else
            break;
        *v = *v << 4 | c;
    }
    return d;
}

// The next byte of the file f, 256 at its end, or an error
static int byte(struct file *f)
{
    if (f->pos >= f->size)
        return 256;
    int r = seek(f);
    if (r)
        return r < 0 ? r : E_BADFAT;
    return ((const unsigned char *)f->buf)[f->pos++ & 511];
}

int fat_load(int h, unsigned end, unsigned stats)
{
    static unsigned char line[LINE_MAX + 2];
    unsigned words = 0, lo = ~0u, hi = 0, bad = 0, first = 0, number = 0;
    int len = 0, last = 0, err;
    struct file *f = handle(h, 0, &err);
    if (!f)
        return err;
    for (;;) {
        int c = byte(f);
        if (c < 0)
            return c;
        if (c == '\n' && last == '\r') {
            last = 0;
            continue;           // the LF of a CR LF
        }
        last = c;
        if (c != '\r' && c != '\n' && c != 256) {
            if (c == '\t')
                c = ' ';
            if (c >= 0x20 && c < 0x80 && len <= LINE_MAX)
                line[len++] = (unsigned char)c;
            continue;
        }
        if (c == 256 && len == 0)
            break;
        number++;
        line[len] = 0;
        int i = 0, ok = len <= LINE_MAX, blanks = 1;
        for (int k = 0; k < len; k++)
            blanks &= line[k] == ' ';
        len = 0;
        if (!blanks) {
            unsigned a, w;
            int da = hex(line, &i, &a);
            int dw = hex(line, &i, &w);
            while (line[i] == ' ')
                i++;
            ok = ok && da >= 1 && da <= 8 && dw >= 1 && dw <= 8 && line[i] == 0 &&
                 a >= PROGRAM && a < end;
            if (ok) {
                nice_poke(a, w);
                words++;
                if (a < lo)
                    lo = a;
                if (a > hi)
                    hi = a;
            } else if (bad++ == 0) {
                first = number;
            }
        }
        if (c == 256)
            break;
    }
    nice_poke(stats, words);
    nice_poke(stats + 1, lo);
    nice_poke(stats + 2, hi);
    nice_poke(stats + 3, bad);
    nice_poke(stats + 4, first);
    return 0;
}
