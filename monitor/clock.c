// The clock of the time of day for the ROM (issue #109): the monitor's
// time command, the dates of FAT's entries for fat32.c, and the clock set
// from the MEGA65's real-time clock at the cold start (issue #105). It is
// part of the ROM's C code (INTERNALS.md, "C in the ROM"), with fat32.c.
//
// The clock (nice_cpu's SYSTEM.md §10) counts seconds since 1970-01-01
// 00:00:00, and keeps local time, as the MEGA65's real-time clock does
// (issue #105, nice_cpu#158): there are no time zones here, so a date and
// a time convert to the seconds of the clock and back as if they were UTC.
//
// The code is small rather than general, as it takes ROM that the BASIC
// of #54 needs too. It reads 32 bits of the seconds, up to 2106-02-07
// 06:28:15, and time sets the years 1970 to 2105. A date converts by
// counting the days of its years and months in loops, with the leap
// years of 1970 to 2106: every fourth, but 2100. One pattern, FORM, both
// parses a date and a time and prints them.

#include <nice.h>

#define CLOCK_USEC 0xFFFFFF46u
#define CLOCK_SEC_LO 0xFFFFFF47u
#define CLOCK_SEC_HI 0xFFFFFF48u
#define CLOCK_STATUS 0xFFFFFF49u

// The I2C master of the board (doc/SYSTEM.md): its command, its status,
// and its data, 4 bytes in a word
#define I2C_CMD 0xFFFFFF97u
#define I2C_STATUS 0xFFFFFF98u
#define I2C_DATA 0xFFFFFF99u
#define I2C_PRESENT 1u
#define I2C_BUSY 2u
#define I2C_FAIL 12u    // NACK or timeout
#define I2C_READ 0x80u

// The real-time clocks: the R6's RV-3032-C7 and the R3's ISL12020M
#define RV3032 0x51u
#define ISL12020M 0x6Fu

#define YEAR_MIN 1970   // the years that time sets
#define YEAR_MAX 2105
#define FAT_MIN 1980    // the first year that FAT's dates hold

// The date and the time of the pattern FORM, a # for each digit: the
// year, the month, the day, the hours, the minutes, and the seconds, in
// the order of fields
static const char form[] = "####-##-## ##:##:##";
static unsigned field[6];
static unsigned usec;   // the microseconds of the last split

static const unsigned char mdays[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};

// The days of the year y, and of the month m, 0 to 11, of the year y
static unsigned ylen(unsigned y)
{
    return (y & 3) || y == 2100 ? 365 : 366;
}

static unsigned mlen(unsigned y, unsigned m)
{
    return mdays[m] + (m == 1 && ylen(y) == 366);
}

// The clock's time in field and usec. 1, or 0 when the clock is not set,
// or past 32 bits of seconds.
static int split(void)
{
    if (!(nice_peek(CLOCK_STATUS) & 1))
        return 0;
    usec = nice_peek(CLOCK_USEC);   // and the snapshot of the seconds
    unsigned sec = nice_peek(CLOCK_SEC_LO);
    if (nice_peek(CLOCK_SEC_HI))
        return 0;
    unsigned days = sec / 86400, s = sec % 86400;
    unsigned y = 1970, m = 0;
    while (days >= ylen(y))
        days -= ylen(y++);
    while (days >= mlen(y, m))
        days -= mlen(y, m++);
    field[0] = y;
    field[1] = m + 1;
    field[2] = days + 1;
    field[3] = s / 3600;
    field[4] = s / 60 % 60;
    field[5] = s % 60;
    return 1;
}

// FAT's date of the clock's time, and in *t its time in bits 15..0, in
// steps of two seconds, and the hundredths of a second over them, 0 to
// 199, in bits 23..16, as an entry's creation time has them in byte 13.
// 0 when the clock is not set, or its year is before FAT's first.
unsigned clock_fat(unsigned *t)
{
    if (!split() || field[0] < FAT_MIN)
        return 0;
    *t = ((field[5] & 1) * 100 + usec / 10000) << 16 | field[3] << 11 | field[4] << 5 |
         field[5] / 2;
    return (field[0] - 1980) << 9 | field[1] << 5 | field[2];
}

// Sets the clock to the date and the time in field, at us microseconds,
// which sets "set". 0, with nothing set, when they are no date and time
// of the years YEAR_MIN to YEAR_MAX.
static int set(unsigned us)
{
    if (field[0] < YEAR_MIN || field[0] > YEAR_MAX || field[1] - 1 > 11 ||
        field[2] - 1 >= mlen(field[0], field[1] - 1) || field[3] > 23 || field[4] > 59 ||
        field[5] > 59)
        return 0;
    unsigned days = field[2] - 1;
    for (unsigned y = YEAR_MIN; y < field[0]; y++)
        days += ylen(y);
    for (unsigned m = 0; m + 1 < field[1]; m++)
        days += mlen(field[0], m);
    nice_poke(CLOCK_SEC_LO, days * 86400 + field[3] * 3600 + field[4] * 60 + field[5]);
    nice_poke(CLOCK_SEC_HI, 0);
    nice_poke(CLOCK_USEC, us);
    return 1;
}

// A read of n bytes from register reg of the I2C chip at address chip,
// into the master's data. 1 when the chip answered every byte.
static int i2c_read(unsigned chip, unsigned reg, unsigned n)
{
    while (nice_peek(I2C_STATUS) & I2C_BUSY)
        ;
    nice_poke(I2C_CMD, n << 16 | reg << 8 | I2C_READ | chip);
    unsigned s;
    while ((s = nice_peek(I2C_STATUS)) & I2C_BUSY)
        ;
    return !(s & I2C_FAIL);
}

// Byte i of the data that the I2C master read, as a number from its two
// BCD digits, of the bits of mask. A digit over 9 gives 100 or more, which
// no field takes.
static unsigned bcd(unsigned i, unsigned mask)
{
    unsigned b = nice_peek(I2C_DATA + i / 4) >> i % 4 * 8 & mask;
    return (b & 15) > 9 ? 100 : (b >> 4) * 10 + (b & 15);
}

// The clock from the MEGA65's real-time clock, at the cold start (issue
// #105), unless it is set already, by a program, by time, or by an earlier
// start, or the board has no I2C master, as in niceemu, where the master's
// status is plain memory, 0. The R6's RV-3032-C7 keeps the hundredths of a
// second, the seconds, the minutes, the hours, the weekday, the date, the
// month, and the year from register 0, and its status at 0x0D, whose VLF
// and PORF say that it lost its time. The R3's ISL12020M keeps the
// seconds, the minutes, the hours, the date, the month, the year, and the
// weekday from register 0, and its status at 7, whose RTCF says that it
// lost its time. Its hours have bit 7 set in 24-hour mode, and else bit 5
// for PM, and 12 for 0. Both keep the local time, in BCD, and the years
// 2000 to 2099. The clock is not set when no chip answers, it lost its
// time, or it holds no date and time.
void clock_rtc(void)
{
    if ((nice_peek(CLOCK_STATUS) & 1) || !(nice_peek(I2C_STATUS) & I2C_PRESENT))
        return;
    unsigned us = 0, sec, date;
    if (i2c_read(RV3032, 0, 14)) {
        if (nice_peek(I2C_DATA + 3) & 0x300)
            return;
        us = bcd(0, 0xFF) * 10000;
        field[3] = bcd(3, 0x3F);
        sec = 1;
        date = 5;
    } else if (i2c_read(ISL12020M, 0, 8)) {
        if (nice_peek(I2C_DATA + 1) & 0x01000000)
            return;
        field[3] = bcd(2, 0x3F);
        if (!(nice_peek(I2C_DATA) & 0x800000))
            field[3] = bcd(2, 0x1F) % 12 + (nice_peek(I2C_DATA) & 0x200000 ? 12 : 0);
        sec = 0;
        date = 3;
    } else {
        return;
    }
    field[5] = bcd(sec, 0x7F);
    field[4] = bcd(sec + 1, 0x7F);
    field[2] = bcd(date, 0x3F);
    field[1] = bcd(date + 1, 0x1F);
    field[0] = 2000 + bcd(date + 2, 0xFF);
    set(us);
}

// time [YYYY-MM-DD HH:MM:SS]: the line from p, the word after time. With
// a date and a time as FORM has them, with blanks before and after, the
// clock is set to them, at 0 microseconds, which sets "set"; anything
// else that is not blank is no time, and sets nothing. Then the clock is
// shown as FORM has it, or that it is not set.
void clock_cmd(unsigned p)
{
    while (nice_peek(p) == ' ')
        p++;
    if (nice_peek(p)) {
        unsigned n = 0, k = 0;
        for (unsigned i = 0; form[i]; i++, p++) {
            unsigned c = nice_peek(p);
            if (form[i] != '#') {
                if (c != (unsigned)form[i])
                    goto bad;
            } else if (c - '0' > 9) {
                goto bad;
            } else {
                n = n * 10 + c - '0';
                if (form[i + 1] != '#') {
                    field[k++] = n;
                    n = 0;
                }
            }
        }
        while (nice_peek(p) == ' ')
            p++;
        if (nice_peek(p) || !set(0))
            goto bad;
    }
    if (!split()) {
        nice_print(nice_peek(CLOCK_STATUS) & 1 ? "Clock past 2106\r\n" : "Clock not set\r\n");
        return;
    }
    // Each field's digits, from the place of its first: 1000 for a field
    // of four digits, 10 for one of two
    for (unsigned i = 0, k = 0, w = 1000; form[i]; i++) {
        if (form[i] != '#') {
            nice_putc(form[i]);
            w = 10;
            continue;
        }
        nice_putc('0' + field[k] / w % 10);
        if (w == 1)
            k++;
        w /= 10;
    }
    nice_print("\r\n");
    return;
bad:
    nice_print("time [YYYY-MM-DD HH:MM:SS]: the local date and time, such as "
               "time 2026-11-11 14:30:00\r\n");
}
