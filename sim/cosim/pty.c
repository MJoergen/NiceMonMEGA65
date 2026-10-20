/*
 * A pseudo-terminal for tb_cosim.vhd, so that the tools talk to the
 * simulated system as to the board. The functions are called from VHDL
 * through VHPIDIRECT.
 *
 * pty_open() makes the pseudo-terminal, links nicemon.pty in the current
 * directory to its device, and returns 0, or -1 on an error.
 * pty_read() returns the next byte from the tool, or -1 if none has come.
 * pty_write() sends a byte to the tool.
 */
#define _DEFAULT_SOURCE
#define _XOPEN_SOURCE 600
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <termios.h>
#include <unistd.h>

#define LINK "nicemon.pty"

static int master = -1;

int pty_open(void)
{
    struct termios t;
    int slave;

    master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0 || grantpt(master) || unlockpt(master))
        return -1;
    /* The tool sets the device raw, but it may read before it does. */
    /* The device stays open here, so that the tool can close and open it
     * again without the master seeing a hang-up. */
    slave = open(ptsname(master), O_RDWR | O_NOCTTY);
    if (slave >= 0 && tcgetattr(slave, &t) == 0) {
        cfmakeraw(&t);
        tcsetattr(slave, TCSANOW, &t);
    }
    fcntl(master, F_SETFL, O_NONBLOCK);
    unlink(LINK);
    if (symlink(ptsname(master), LINK))
        return -1;
    printf("tb_cosim: the board is at %s, linked from %s\n", ptsname(master), LINK);
    fflush(stdout);
    return 0;
}

int pty_read(void)
{
    unsigned char c;

    if (read(master, &c, 1) == 1)
        return c;
    return -1;
}

int pty_write(int c)
{
    unsigned char b = (unsigned char)c;

    while (write(master, &b, 1) != 1)
        usleep(100);
    return 0;
}
