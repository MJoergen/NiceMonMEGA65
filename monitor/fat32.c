// FAT32 for the ROM: reading and writing, in the folder FOLDER of the root
// directory (issues #58, #59, and #91, doc/SDCARD.md, "The file system").
// It is part of the ROM's C code (INTERNALS.md, "C in the ROM"), and the
// dispatch table's entries fs_mount, fs_open, fs_read, fs_readdir,
// fs_close, fs_write, fs_delete, and fs_readname jump to its functions
// fat_mount, fat_open, fat_read, fat_readdir, fat_close, fat_write,
// fat_delete, and fat_readname, which take the arguments of the entries:
// addresses are NICE word addresses, not C pointers, read and written
// with nice_peek and nice_poke. fat_load reads a .bin file for the
// monitor's load command, and fat_save writes one for save.
//
// Names are long names (VFAT, #102) of up to 255 characters, matched in
// either case, or 8.3 names. A long name is read from the long-name
// entries before an 8.3 entry, when their numbers, their last-entry bit,
// and their checksum check; a set that does not is passed over, and the
// 8.3 name stands, with the lower-case flags of byte 12. A character
// outside ASCII is ?, and such a name is reached by its 8.3 name only. A
// new file whose name is not an 8.3 name in upper case, or in lower case
// in either part, which byte 12 keeps, gets long-name entries and an 8.3
// alias, with a tail ~1, ~2, and on when the name does not fit, as
// mtools makes them.
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
// sd_init, sd_read, and sd_write give them, and those below, from -16.
//
// Writing keeps to an order in which a reset at any point leaves the card
// no worse than with lost clusters, which fsck.fat frees. A file opened
// to write gets its directory entry at once, empty, with no clusters, and
// an existing file is truncated so: the entry first, then its clusters
// freed. The file's clusters are taken from the FAT as its data reaches
// them, each marked as the end of the chain in every copy of the FAT
// before the one before it is linked to it, and its data written; only
// fat_close puts the first cluster and the size into the entry. A
// deletion marks the long-name entries, then the entry, then frees the
// clusters. A new entry's long-name entries are written before its 8.3
// entry, so a reset between them leaves orphan long-name entries, which
// fsck.fat removes too. A new cluster is searched from FSInfo's next-free hint, and
// the first change of the FAT after a mount sets FSInfo's free count to
// unknown, 0xFFFFFFFF, before it; the hint is written after each change.
// The FAT's cache and the directory's are written through; a file's
// sector is written when it is full, and at fat_close. No sector outside
// the partition is ever written, nor its boot sector: wr checks each.

#include <nice.h>

// The monitor's sector routines, through its shims, which convert buf
// from a byte address of the C code's memory to a NICE word address
int fat_sd_init(unsigned slot);
int fat_sd_read(unsigned lba, unsigned *buf);
int fat_sd_write(unsigned lba, const unsigned *buf);

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
#define E_NAME -20      // not a valid name
#define E_NOFILE -21    // no file of that name
#define E_ISDIR -22     // a directory, opened as a file
#define E_TOOMANY -23   // two files open already
#define E_HANDLE -24    // not an open file, or not of the right kind
#define E_MODE -25      // a mode that is not 0, 1, or 2
#define E_BADFAT -26    // a cluster outside the volume
#define E_SLOT -27      // no such slot
#define E_CHANGED -28   // the card changed, or the mount was dropped
#define E_NOFOLDER -29  // no folder FOLDER in the root directory
#define E_FULL -30      // no free cluster, or the folder has 65536 entries
#define E_OPEN -31      // the file is open, and may not be opened or deleted so
#define E_RDONLY -32    // the file is read-only

// The folder of NiceMon's files, an 8.3 name of up to 8 characters in
// upper case, which the Makefile checks
#ifndef FOLDER
#define FOLDER "NICE"
#endif

#define END 0x0FFFFFF8u  // a FAT entry from here ends a chain
#define EOC 0x0FFFFFFFu  // the FAT entry written at the end of a chain
#define FILES 2
#define DIR_MAX (65536u * 32)   // the bytes of a directory at most
#define DATE 0x5C21u    // the date of a new entry, 2026-01-01, as there is no clock
#define NAME_MAX 255    // the characters of a long name at most,
#define LFN_MAX 20      // and its long-name entries, 13 characters each

// The kinds of an open file
#define K_READ 0
#define K_WRITE 1
#define K_DIR 2

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
    unsigned nfats;     // the copies of the FAT,
    unsigned fatsz;     // and the sectors of each
    unsigned end;       // the sector after the partition
    unsigned fsinfo;    // the sector of FSInfo, 0 for none
    unsigned hint;      // the cluster to search for a free one from, 0 for FSInfo's
    int unknown;        // FSInfo's free count is set to unknown since the mount
    int changed;        // the FAT changed since FSInfo was written
} vol;

static unsigned fatbuf[128];
static unsigned fatlba = ~0u;   // the sector in fatbuf

// An open file, or a directory. A file opened to write has its first
// cluster in first, 0 while it has none, its last in clus, and the sector
// that pos is in, in buf, at lba, once a byte of it is written.
static struct file {
    int open;
    int kind;           // K_READ, K_WRITE, or K_DIR, read with fat_readdir
    int done;           // the directory's end was found
    unsigned first;     // the first cluster, 0 for an empty file
    unsigned clus;      // the cluster that holds the byte at cpos
    unsigned cpos;      // the byte offset of the start of clus
    unsigned pos;       // the byte offset of the next byte
    unsigned size;
    unsigned lba;       // the sector in buf
    unsigned elba;      // a file's directory entry: its sector,
    unsigned eoff;      // and its byte offset there
    unsigned lfn;       // a directory's: the offset of the long name before the entry entry() gave, or ~0u
    unsigned buf[128];
} files[FILES];

// The directory that find and make search, whose buffer holds the entry
// they give, and a sector for FSInfo, an entry, or a new cluster's zeros
static struct file dirf;
static unsigned sec[128];

// The name of the entry that entry() gave last: its long name, or else its
// 8.3 name as a name, HELLO.BIN, in the case of byte 12, up to a 0 byte;
// lascii is 0 when it has a ? for a character outside ASCII. The name
// given to fat_open or fat_delete, as getname reads it, wlen characters.
static unsigned char lname[NAME_MAX + 1];
static int lascii;
static unsigned char want[NAME_MAX + 1];
static unsigned wlen;

// The bytes of a long-name entry that hold its 13 characters, UTF-16
static const unsigned char lfnat[13] = {1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30};

static unsigned u16(const unsigned char *p)
{
    return p[0] | p[1] << 8;
}

static unsigned u32(const unsigned char *p)
{
    return p[0] | p[1] << 8 | p[2] << 16 | (unsigned)p[3] << 24;
}

static void put16(unsigned char *p, unsigned v)
{
    p[0] = (unsigned char)v;
    p[1] = (unsigned char)(v >> 8);
}

static void put32(unsigned char *p, unsigned v)
{
    put16(p, v);
    put16(p + 2, v >> 16);
}

// A sector written, but none outside the partition, nor below its first
// FAT but FSInfo, when the volume has one, so never the MBR or the boot
// sector
static int wr(unsigned lba, const unsigned *buf)
{
    if ((lba < vol.fat && !(vol.fsinfo && lba == vol.fsinfo)) ||
        lba >= vol.end)
        return E_BADFAT;
    return fat_sd_write(lba, buf);
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

static int find(unsigned first, const unsigned char *n, int bylong, unsigned char **e);

// A slot that the system does not have changes nothing.
static int mount(unsigned slot)
{
    unsigned char *b = (unsigned char *)fatbuf;
    if (slot >= nice_peek(SD_SLOTS))
        return E_SLOT;
    drop();
    vol.ever = 1;
    vol.slot = slot;
    vol.hint = 0;
    vol.unknown = 0;
    vol.changed = 0;
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
    vol.nfats = b[16];
    vol.fatsz = u32(b + 36);
    vol.data = vol.fat + vol.nfats * vol.fatsz;
    vol.root = u32(b + 44);
    vol.end = base + u32(b + 32);
    vol.top = (vol.end - vol.data) / vol.spc + 2;
    // FAT32's FATs may have more entries than the volume has clusters
    if (vol.top > vol.fatsz * 128)
        vol.top = vol.fatsz * 128;
    unsigned fsi = u16(b + 48);
    vol.fsinfo = fsi >= 1 && fsi < u16(b + 14) ? base + fsi : 0;
    fatlba = ~0u;
    if (vol.root < 2 || vol.root >= vol.top)
        return E_BADFAT;
    // The folder: FOLDER padded with blanks, a directory of the root
    unsigned char n[11], *e;
    static const char folder[] = FOLDER;
    for (int k = 0; k < 11; k++)
        n[k] = k < (int)sizeof folder - 1 ? (unsigned char)folder[k] : ' ';
    if ((r = find(vol.root, n, 0, &e)) < 0)
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

// The sector of the first FAT that holds the entry of cluster c in
// fatbuf: 0, or an error
static int fatsec(unsigned c)
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
    return 0;
}

// The FAT's entry of cluster c in *next, or an error
static int next(unsigned c, unsigned *next)
{
    int r = fatsec(c);
    if (r < 0)
        return r;
    *next = fatbuf[c & 127] & 0x0FFFFFFF;
    return 0;
}

// FSInfo with the free count unknown and the next-free hint, vol.hint,
// which it gives when vol.hint is 0. A sector without FSInfo's signatures
// is left alone. 0, or an error.
static int info(void)
{
    if (!vol.fsinfo)
        return 0;
    unsigned char *b = (unsigned char *)sec;
    int r = fat_sd_read(vol.fsinfo, sec);
    if (r < 0)
        return r;
    if (u32(b) != 0x41615252u || u32(b + 484) != 0x61417272u || u32(b + 508) != 0xAA550000u)
        return 0;
    if (!vol.hint)
        vol.hint = u32(b + 492);
    put32(b + 488, 0xFFFFFFFFu);
    put32(b + 492, vol.hint);
    if ((r = wr(vol.fsinfo, sec)) < 0)
        return r;
    vol.unknown = 1;
    vol.changed = 0;
    return 0;
}

// FSInfo written after a change of the FAT
static int infodone(void)
{
    return vol.changed ? info() : 0;
}

// The FAT's entry of cluster c set to v, in every copy of the FAT, after
// FSInfo's free count is unknown. 0, or an error.
static int set(unsigned c, unsigned v)
{
    int r;
    if (!vol.unknown && (r = info()) < 0)
        return r;
    if ((r = fatsec(c)) < 0)
        return r;
    fatbuf[c & 127] = (fatbuf[c & 127] & 0xF0000000u) | v;
    vol.changed = 1;
    for (unsigned k = 0; k < vol.nfats; k++) {
        if ((r = wr(fatlba + k * vol.fatsz, fatbuf)) < 0) {
            fatlba = ~0u;   // the card may not hold what the cache does
            return r;
        }
    }
    return 0;
}

// A free cluster in *c, searched from the hint up to the last and then
// from 2, a sector of the FAT at a time, but not taken. 0, E_FULL, or an
// error.
static int search(unsigned *c)
{
    if (!vol.hint && vol.fsinfo) {
        int r = info();     // for its hint
        if (r < 0)
            return r;
    }
    unsigned k = vol.hint >= 2 && vol.hint < vol.top ? vol.hint : 2;
    unsigned left = vol.top - 2;
    while (left) {
        int r = fatsec(k);
        if (r < 0)
            return r;
        unsigned stop = (k | 127) + 1;
        if (stop > vol.top)
            stop = vol.top;
        if (stop - k > left)
            stop = k + left;
        left -= stop - k;
        for (; k < stop; k++) {
            if (!(fatbuf[k & 127] & 0x0FFFFFFF)) {
                *c = k;
                return 0;
            }
        }
        if (k == vol.top)
            k = 2;
    }
    return E_FULL;
}

// The free cluster c taken as the end of a chain, and linked after prev,
// unless prev is 0. 0, or an error.
static int take(unsigned prev, unsigned c)
{
    int r = set(c, EOC);
    if (r == 0 && prev)
        r = set(prev, c);
    if (r == 0)
        vol.hint = c + 1 < vol.top ? c + 1 : 2;
    return r;
}

// The chain from cluster c freed, up to its end, or a cluster outside the
// volume, or a free one, as a chain with a loop in it comes back to one.
// The hint goes back to the first freed below it. 0, or an error.
static int release(unsigned c)
{
    while (c >= 2 && c < vol.top) {
        unsigned n;
        int r = next(c, &n);
        if (r < 0)
            return r;
        if (n == 0)
            return E_BADFAT;
        if ((r = set(c, 0)) < 0)
            return r;
        if (c < vol.hint)
            vol.hint = c;
        c = n;
    }
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

// The open file of handle h of the kind kind, or 0, which closes all when
// the mount was dropped
static struct file *handle(int h, int kind, int *err)
{
    if (h < 0 || h >= FILES || !files[h].open || files[h].kind != kind) {
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
// word, in want and wlen: 0, or E_NAME when it is empty or longer than
// NAME_MAX, or has a character outside bits 7..0
static int getname(unsigned name)
{
    for (wlen = 0;; wlen++) {
        unsigned c = nice_peek(name + wlen);
        if (c == 0)
            break;
        if (wlen == NAME_MAX || c > 0xFF)
            return E_NAME;
        want[wlen] = (unsigned char)c;
    }
    want[wlen] = 0;
    return wlen ? 0 : E_NAME;
}

// A character that no name may have, in either kind: a control code, a
// character outside ASCII, or one of "*/:<>?\|
static int bad(unsigned c)
{
    return c < 0x20 || c >= 0x7F || c == '"' || c == '*' || c == '/' || c == ':' ||
           c == '<' || c == '>' || c == '?' || c == '\\' || c == '|';
}

// A character that a long name may have, but an 8.3 name not: the blank
// and +,.;=[]
static int not83(unsigned c)
{
    return c == ' ' || c == '+' || c == ',' || c == '.' || c == ';' || c == '=' ||
           c == '[' || c == ']';
}

// want as an 8.3 name in upper case padded with blanks in n: 1, with the
// flags of byte 12 in *lower for a part in lower case, or ~0u for a part
// in mixed case, or 0 when it is no 8.3 name
static int name83(unsigned char n[11], unsigned *lower)
{
    int part = 0, len = 0;
    unsigned up[2] = {0, 0}, low[2] = {0, 0};
    for (int k = 0; k < 11; k++)
        n[k] = ' ';
    for (unsigned i = 0; i < wlen; i++) {
        unsigned c = want[i];
        if (c == '.' && part == 0 && len > 0) {
            part = 1;
            len = 0;
            continue;
        }
        if (c >= 'a' && c <= 'z') {
            low[part] = 1;
            c -= 0x20;
        } else if (c >= 'A' && c <= 'Z') {
            up[part] = 1;
        }
        if (bad(c) || not83(c) || len == (part ? 3 : 8))
            return 0;
        n[part ? 8 + len : len] = (unsigned char)c;
        len++;
    }
    if (len == 0)
        return 0;
    *lower = (up[0] && low[0]) || (up[1] && low[1]) ? ~0u : (low[0] ? 0x08 : 0) | (low[1] ? 0x10 : 0);
    return 1;
}

// want as a name that a new file may have: a long name of characters
// that bad() lets through, which does not end in a blank or a dot, as
// Windows drops those. 1, or 0.
static int longok(void)
{
    for (unsigned i = 0; i < wlen; i++)
        if (bad(want[i]))
            return 0;
    return want[wlen - 1] != ' ' && want[wlen - 1] != '.';
}

// The checksum of an 8.3 name that its long-name entries hold
static unsigned char sum(const unsigned char *n)
{
    unsigned char s = 0;
    for (int k = 0; k < 11; k++)
        s = (unsigned char)(((s & 1) << 7) + (s >> 1) + n[k]);
    return s;
}

// The 8.3 name of the entry e in lname as a name: the base, then a dot
// and the extension if it has one, without their blanks, each part in
// lower case when byte 12 says so
static void short_name(const unsigned char *e)
{
    unsigned len = 0;
    lascii = 1;
    for (int k = 0; k < 11; k++) {
        unsigned c = k == 0 && e[0] == 0x05 ? 0xE5 : e[k];
        if (k == 8 && e[8] != ' ')
            lname[len++] = '.';
        if (c == ' ')
            continue;
        if (c >= 'A' && c <= 'Z' && (e[12] & (k < 8 ? 0x08 : 0x10)))
            c += 0x20;
        if (c < 0x20 || c >= 0x7F) {
            c = '?';
            lascii = 0;
        }
        lname[len++] = (unsigned char)c;
    }
    lname[len] = 0;
}

// The next entry of the directory f that is a file or a directory, at e,
// 32 bytes in f->buf, with f->lfn the offset of the long-name entries
// right before it, or ~0u, and its name in lname: 1, 0 at the end, or an
// error. The long-name entries are checked as they come, as they may be
// in the sectors before e's: the first holds the last part, its number
// with bit 6 set, and the checksum, and each after it the number one
// less and the same checksum, down to 1. Their characters go to lname as
// they come, at the offsets of their numbers.
static int entry(struct file *f, unsigned char **e)
{
    unsigned lfn = ~0u, len = 0;
    int next = -1;          // the number of the long-name entry due, 0 after 1, -1 for none
    int ascii = 1;
    unsigned char s = 0;
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
        if (p[0] != 0xE5 && p[11] == 0x0F) {
            if (lfn == ~0u)
                lfn = f->pos - 32;
            int k = p[0] & 0x1F;
            if (p[0] & 0x40) {
                next = k;
                s = p[13];
                len = 13 * k;
                ascii = 1;
            }
            if (k == 0 || k > LFN_MAX || k != next || p[13] != s) {
                next = -1;
                continue;
            }
            for (int j = 0; j < 13; j++) {
                unsigned pos = 13 * (k - 1) + j, c = u16(p + lfnat[j]);
                if (pos >= len)
                    break;
                if (c == 0) {
                    len = pos;
                    break;
                }
                if (c < 0x20 || c >= 0x7F) {
                    c = '?';
                    ascii = 0;
                }
                if (pos < NAME_MAX)
                    lname[pos] = (unsigned char)c;
            }
            next = k - 1;
            continue;
        }
        if (p[0] == 0xE5 || (p[11] & 0x08) || p[0] == '.') {
            lfn = ~0u;
            next = -1;
            continue;
        }
        if (next == 0 && sum(p) == s && len >= 1 && len <= NAME_MAX) {
            lname[len] = 0;
            lascii = ascii;
        } else {
            short_name(p);
        }
        f->lfn = lfn;
        *e = p;
        return 1;
    }
    f->done = 1;
    return 0;
}

// The same name, but that a letter of a matches either case in b
static int same(const unsigned char *a, const unsigned char *b)
{
    for (;; a++, b++) {
        unsigned x = *a, y = *b;
        if (x >= 'a' && x <= 'z')
            x -= 0x20;
        if (y >= 'a' && y <= 'z')
            y -= 0x20;
        if (x != y)
            return 0;
        if (x == 0)
            return 1;
    }
}

static void start(struct file *f, unsigned first, int kind, unsigned size);

// The entry in the directory whose first cluster is first of the 8.3 name
// n, unless n is 0, or when bylong is 1 of the name in want, as its long
// name in either case, at e: 1, 0 when there is none, or an error. The
// entry is in dirf's buffer, which keeps it until the next call, at
// dirf.lba.
static int find(unsigned first, const unsigned char *n, int bylong, unsigned char **e)
{
    start(&dirf, first, K_DIR, 0);
    int r;
    while ((r = entry(&dirf, e)) == 1) {
        int ok = n != 0;
        for (int k = 0; ok && k < 11; k++)
            ok = (k == 0 && (*e)[0] == 0x05 ? 0xE5 : (*e)[k]) == n[k];
        if (ok || (bylong && lascii && same(lname, want)))
            return 1;
    }
    return r;
}

// The entry of the name in want, as find gives it: by its 8.3 name, when
// want is one, and by its long name
static int lookup(unsigned char **e)
{
    unsigned char n[11];
    unsigned lower;
    return find(vol.dir, name83(n, &lower) ? n : 0, 1, e);
}

static void start(struct file *f, unsigned first, int kind, unsigned size)
{
    f->open = 1;
    f->kind = kind;
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

// A free handle, or E_TOOMANY
static int freeh(void)
{
    for (int h = 0; h < FILES; h++)
        if (!files[h].open)
            return h;
    return E_TOOMANY;
}

// An open file whose directory entry is at the sector lba and the offset
// off, that is opened to write, or of any kind when any is 1, or 0
static int busy(unsigned lba, unsigned off, int any)
{
    for (int h = 0; h < FILES; h++) {
        struct file *f = &files[h];
        if (f->open && f->kind != K_DIR && f->elba == lba && f->eoff == off &&
            (any || f->kind == K_WRITE))
            return 1;
    }
    return 0;
}

// The first cluster of the entry e
static unsigned cluster(const unsigned char *e)
{
    return u16(e + 20) << 16 | u16(e + 26);
}

// A file's entry e checked for a change: E_ISDIR, E_RDONLY, E_OPEN when a
// file has it open, or 0
static int writable(const unsigned char *e)
{
    if (e[11] & 0x10)
        return E_ISDIR;
    if (e[11] & 0x01)
        return E_RDONLY;
    if (busy(dirf.lba, (unsigned)(e - (unsigned char *)dirf.buf), 1))
        return E_OPEN;
    return 0;
}

static int at(unsigned off, unsigned char **p);

// A new entry of the 8.3 name n in the folder, empty, with the flags lower
// in byte 12, and nl long-name entries of the name in want before it, in
// the first run of nl + 1 free entries, which may go on into a new
// cluster of zeros added to the folder. The long-name entries are written
// first, then the 8.3 entry, a sector at a time. It is in dirf's buffer
// at e. 0, or an error.
static int make(const unsigned char n[11], unsigned lower, unsigned nl, unsigned char **e)
{
    start(&dirf, vol.dir, K_DIR, 0);
    unsigned run = 0, from = 0;
    int r;
    while (run <= nl) {
        if (dirf.pos >= DIR_MAX)
            return E_FULL;
        if ((r = seek(&dirf)) < 0)
            return r;
        if (r == 1) {
            // The end of the chain, dirf.clus its last cluster: a new one,
            // its zeros written before it is taken and linked
            unsigned c;
            if ((r = search(&c)) < 0)
                return r;
            for (int k = 0; k < 128; k++)
                sec[k] = 0;
            unsigned lba = vol.data + (c - 2) * vol.spc;
            for (unsigned k = 0; k < vol.spc; k++)
                if ((r = wr(lba + k, sec)) < 0)
                    return r;
            if ((r = take(dirf.clus, c)) < 0)
                return r;
            continue;
        }
        unsigned char *p = (unsigned char *)dirf.buf + (dirf.pos & 511);
        if (p[0] == 0 || p[0] == 0xE5) {
            if (run++ == 0)
                from = dirf.pos;
        } else {
            run = 0;
        }
        dirf.pos += 32;
    }
    unsigned char s = sum(n);
    for (unsigned k = 0; k <= nl; k++) {
        unsigned q = from + 32 * k;
        unsigned char *p;
        if ((r = at(q, &p)) < 0)
            return r;
        for (int i = 0; i < 32; i++)
            p[i] = 0;
        if (k < nl) {
            // The long-name entry of the number nl - k, its 13 characters
            // from want, then a 0 after the name, and 0xFFFF after that
            unsigned m = nl - k;
            p[0] = (unsigned char)(m | (k == 0 ? 0x40 : 0));
            p[11] = 0x0F;
            p[13] = s;
            for (int j = 0; j < 13; j++) {
                unsigned pos = 13 * (m - 1) + j;
                put16(p + lfnat[j], pos < wlen ? want[pos] : pos == wlen ? 0 : 0xFFFF);
            }
        } else {
            for (int i = 0; i < 11; i++)
                p[i] = n[i];
            p[11] = 0x20;           // archive
            p[12] = (unsigned char)lower;
            put16(p + 16, DATE);    // created,
            put16(p + 18, DATE);    // read,
            put16(p + 24, DATE);    // and written
            *e = p;
        }
        if ((k == nl || ((q + 32) & 511) == 0) && (r = wr(dirf.lba, dirf.buf)) < 0)
            return r;
    }
    return 0;
}

// The basis of want's 8.3 alias, as Windows makes it, in upper case in n:
// the base from the characters before the last dot, and the extension
// from those after it, without blanks and dots, and with _ for +,;=[].
// 1 when that lost a character, or cut a part, so that the alias needs a
// tail, or else 0. A name whose dots are all at its start has no
// extension.
static int basis(unsigned char n[11])
{
    unsigned dot = wlen, len = 0;
    int lossy = 0, part = 0, any = 0;
    for (unsigned i = 0; i < wlen; i++) {
        if (want[i] == '.')
            dot = any ? i : wlen;
        else if (want[i] != ' ')
            any = 1;
    }
    for (int k = 0; k < 11; k++)
        n[k] = ' ';
    for (unsigned i = 0; i < wlen; i++) {
        unsigned c = want[i];
        if (i == dot) {
            part = 1;
            len = 0;
            continue;
        }
        if (c >= 'a' && c <= 'z')
            c -= 0x20;
        if (c == ' ' || c == '.' || len == (part ? 3u : 8u)) {
            lossy = 1;
            continue;
        }
        if (not83(c)) {
            c = '_';
            lossy = 1;
        }
        n[part ? 8 + len : len] = (unsigned char)c;
        len++;
    }
    return lossy;
}

// The 8.3 name of a new file of the name in want in n, with the flags
// of byte 12 in *lower, and the number of its long-name entries in *nl:
// want itself when it is an 8.3 name in upper case, or in lower case in
// a part, with no long-name entries; or else want's basis, with the
// first tail ~1, ~2, and on that no entry of the folder has, when it
// needs one. 0, E_NAME, or an error.
static int newname(unsigned char n[11], unsigned *lower, unsigned *nl)
{
    *nl = 0;
    if (name83(n, lower) && *lower != ~0u)
        return 0;
    if (!longok())
        return E_NAME;
    *lower = 0;
    *nl = (wlen + 12) / 13;
    if (!basis(n))
        return 0;   // free, as lookup found no file of this 8.3 name
    unsigned base = 0;
    while (base < 8 && n[base] != ' ')
        base++;
    for (unsigned t = 1;; t++) {
        char d[7];
        int nd = 0;
        for (unsigned v = t; v; v /= 10)
            d[nd++] = (char)('0' + v % 10);
        unsigned k = base < 7u - nd ? base : 7u - nd;
        n[k++] = '~';
        while (nd)
            n[k++] = (unsigned char)d[--nd];
        while (k < 8)
            n[k++] = ' ';
        unsigned char *e;
        int r = find(vol.dir, n, 0, &e);
        if (r <= 0)
            return r;
    }
}

int fat_open(unsigned name, int mode)
{
    if (mode < 0 || mode > 2)
        return E_MODE;
    int r = mounted();
    if (r < 0)
        return r;
    // The handle, whose lack, E_TOOMANY, is reported after the errors of
    // the name and the file, as in table 1.1, and before the entry is
    // changed, so that a full table leaves the file as it was
    int h = freeh();
    if (mode == 2) {
        // The folder, the only directory: an empty name, or /
        unsigned c = nice_peek(name);
        if (c && !(c == '/' && nice_peek(name + 1) == 0))
            return E_NAME;
        if (h < 0)
            return h;
        start(&files[h], vol.dir, K_DIR, 0);
        return h;
    }
    unsigned char *e;
    if ((r = getname(name)) < 0 || (r = lookup(&e)) < 0)
        return r;
    unsigned first = 0, size = 0;
    if (mode == 0) {
        if (r == 0)
            return E_NOFILE;
        if (e[11] & 0x10)
            return E_ISDIR;
        if (busy(dirf.lba, (unsigned)(e - (unsigned char *)dirf.buf), 0))
            return E_OPEN;
        first = cluster(e);
        size = u32(e + 28);
        if (size && (first < 2 || first >= vol.top))
            return E_BADFAT;
        if (h < 0)
            return h;
    } else if (r == 1) {
        // Truncated: the entry emptied, then its clusters freed
        if ((r = writable(e)) < 0)
            return r;
        if (h < 0)
            return h;
        unsigned old = cluster(e);
        put16(e + 20, 0);
        put16(e + 26, 0);
        put32(e + 28, 0);
        if ((r = wr(dirf.lba, dirf.buf)) < 0 || (r = release(old)) < 0 ||
            (r = infodone()) < 0)
            return r;
    } else {
        unsigned char n[11];
        unsigned lower, nl;
        if ((r = newname(n, &lower, &nl)) < 0)
            return r;
        if (h < 0)
            return h;
        if ((r = make(n, lower, nl, &e)) < 0 || (r = infodone()) < 0)
            return r;
    }
    struct file *f = &files[h];
    start(f, first, mode == 0 ? K_READ : K_WRITE, size);
    f->elba = dirf.lba;
    f->eoff = (unsigned)(e - (unsigned char *)dirf.buf);
    return h;
}

int fat_read(int h, unsigned buf, unsigned n)
{
    int err;
    struct file *f = handle(h, K_READ, &err);
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

// The next entry of the directory of handle h, as fat_readdir and
// fat_readname give it, its 4 words at buf, and when withname is 1 its
// name at name, one character per word up to a 0 word
static int readdir(int h, unsigned buf, int withname, unsigned name)
{
    int err;
    struct file *f = handle(h, K_DIR, &err);
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
    for (unsigned k = 0; withname; k++) {
        nice_poke(name + k, lname[k]);
        if (lname[k] == 0)
            break;
    }
    return 1;
}

int fat_readdir(int h, unsigned buf)
{
    return readdir(h, buf, 0, 0);
}

int fat_readname(int h, unsigned buf, unsigned name)
{
    return readdir(h, buf, 1, name);
}

// n bytes written to the file f opened to write: from the C code's
// memory at src, or when src is 0 from the words at the word address buf,
// bits 7..0 of each. A cluster is taken when the first byte of it is
// written, and a sector written when it is full. The bytes written, or
// an error: E_FULL only when none was.
static int put(struct file *f, const unsigned char *src, unsigned buf, unsigned n)
{
    unsigned bytes = vol.spc * 512, done = 0;
    unsigned char *b = (unsigned char *)f->buf;
    while (done < n) {
        unsigned at = f->pos & 511;
        int r;
        if (at == 0 && f->lba == ~0u) {
            // A new sector, in a new cluster at the start of one
            if (f->clus == 0 || f->pos - f->cpos == bytes) {
                unsigned c;
                if ((r = search(&c)) < 0 || (r = take(f->clus, c)) < 0)
                    return r == E_FULL && done ? (int)done : r;
                if (f->clus)
                    f->cpos += bytes;
                else
                    f->first = c;
                f->clus = c;
            }
            f->lba = vol.data + (f->clus - 2) * vol.spc + (f->pos - f->cpos) / 512;
            for (int k = 0; k < 128; k++)
                f->buf[k] = 0;
        }
        unsigned k = 512 - at;
        if (k > n - done)
            k = n - done;
        for (unsigned i = 0; i < k; i++)
            b[at + i] = src ? src[done + i] : (unsigned char)nice_peek(buf + done + i);
        if (at + k == 512) {
            if ((r = wr(f->lba, f->buf)) < 0)
                return r;
            f->lba = ~0u;
        }
        f->pos += k;
        done += k;
    }
    return (int)done;
}

int fat_write(int h, unsigned buf, unsigned n)
{
    int err;
    struct file *f = handle(h, K_WRITE, &err);
    if (!f)
        return err;
    return put(f, 0, buf, n);
}

// A file opened to write is finished: its last sector, then its first
// cluster and its size in its entry, then FSInfo. The handle is closed
// also after an error.
int fat_close(int h)
{
    if (h < 0 || h >= FILES || !files[h].open)
        return E_HANDLE;
    struct file *f = &files[h];
    f->open = 0;
    if (f->kind != K_WRITE)
        return 0;
    if (!valid())
        return E_CHANGED;
    int r;
    if (f->lba != ~0u && (r = wr(f->lba, f->buf)) < 0)
        return r;
    unsigned char *e = (unsigned char *)sec + f->eoff;
    if ((r = fat_sd_read(f->elba, sec)) < 0)
        return r;
    put16(e + 20, f->first >> 16);
    put16(e + 26, f->first);
    put32(e + 28, f->pos);
    if ((r = wr(f->elba, sec)) < 0)
        return r;
    return infodone();
}

// The entry of the folder at the offset off, at the pointer that dirf's
// buffer has it, read from the start of the folder when it is before
// dirf's position. 0, or an error.
static int at(unsigned off, unsigned char **p)
{
    if (off < dirf.cpos)
        start(&dirf, vol.dir, K_DIR, 0);
    dirf.pos = off;
    int r = seek(&dirf);
    if (r)
        return r < 0 ? r : E_BADFAT;
    *p = (unsigned char *)dirf.buf + (off & 511);
    return 0;
}

// A file deleted: its long-name entries marked free, then its entry, each
// sector written as it changes, then its clusters freed, then FSInfo
int fat_delete(unsigned name)
{
    unsigned char *e;
    int r = mounted();
    if (r < 0 || (r = getname(name)) < 0 || (r = lookup(&e)) < 0)
        return r;
    if (r == 0)
        return E_NOFILE;
    if ((r = writable(e)) < 0)
        return r;
    unsigned first = cluster(e), lfn = dirf.lfn, off = dirf.pos - 32;
    unsigned char s = sum(e);
    for (unsigned q = lfn; lfn != ~0u && q < off; q += 32) {
        unsigned char *p;
        if ((r = at(q, &p)) < 0)
            return r;
        if (p[11] == 0x0F && p[13] == s) {
            p[0] = 0xE5;
            if ((r = wr(dirf.lba, dirf.buf)) < 0)
                return r;
        }
    }
    if ((r = at(off, &e)) < 0)
        return r;
    e[0] = 0xE5;
    if ((r = wr(dirf.lba, dirf.buf)) < 0 || (r = release(first)) < 0)
        return r;
    return infodone();
}

// fat_dir: the folder FOLDER of the card, for the monitor's dir command:
// a row with its name, then a row for each file, its name, the long name
// or the 8.3 name, in DIR_NAME columns and its size in decimal in 12, and
// for each directory, its name and <DIR>, then the numbers of both. A
// name of DIR_NAME characters or more has a row of its own. With a slot
// from 0, the card in it is mounted first. 0, or an error.
#define DIR_NAME 24

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
    start(&d, vol.dir, K_DIR, 0);
    unsigned char *e;
    unsigned nfiles = 0, ndirs = 0;
    nice_print("Directory of " FOLDER "\r\n");
    while ((r = entry(&d, &e)) == 1) {
        int len = 0;
        while (lname[len])
            nice_putc(lname[len++]);
        if (len >= DIR_NAME) {
            nice_print("\r\n");
            len = 0;
        }
        while (len++ < DIR_NAME)
            nice_putc(' ');
        if (e[11] & 0x10) {
            nice_print("       <DIR>");
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
    struct file *f = handle(h, K_READ, &err);
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

// fat_save: the n words from the word address addr written to the file h,
// opened to write, as lines of ADDR WORD in 8 hex digits each, in lower
// case, ended by LF, as niceasm writes a .bin file. 0, or an error, E_FULL
// too when the card filled up.
int fat_save(int h, unsigned addr, unsigned n)
{
    static const char digits[] = "0123456789abcdef";
    unsigned char line[18];
    int err;
    struct file *f = handle(h, K_WRITE, &err);
    if (!f)
        return err;
    for (unsigned i = 0; i < n; i++, addr++) {
        unsigned w = nice_peek(addr);
        for (int k = 0; k < 8; k++) {
            line[k] = (unsigned char)digits[addr >> (28 - 4 * k) & 15];
            line[9 + k] = (unsigned char)digits[w >> (28 - 4 * k) & 15];
        }
        line[8] = ' ';
        line[17] = '\n';
        int r = put(f, line, 0, sizeof line);
        if (r < 0)
            return r;
        if (r != (int)sizeof line)
            return E_FULL;
    }
    return 0;
}
