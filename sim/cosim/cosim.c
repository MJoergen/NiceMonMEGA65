/*
 * The UART line of tb_cosim.vhd, served over TCP on 127.0.0.1, so that the
 * tools reach the simulated system as they reach the board (--cosim PORT).
 * The functions are called from VHDL through VHPIDIRECT.
 *
 * The connection is the line, as a USB serial adapter is: it carries the
 * bytes both ways, and a connection resets nothing. A half-close, or a
 * close, of the connection is a break on the line, which ends the
 * program's input. One host is served at a time. A host that connects
 * while another is served waits until the other has half-closed or closed,
 * and then the old connection is closed, after the bytes sent on it.
 *
 * cosim_open(port) listens on 127.0.0.1:port, any free port for 0, prints
 * "cosim: port N" on stdout, and returns 0, or -1 on an error.
 * cosim_read() returns the next byte from the host, -1 if none has come,
 * or -2 once for the end of the host's bytes, a half-close or a close.
 * cosim_write(c) sends a byte to the host, and drops it when no host is
 * connected, as a line that nobody listens to.
 */
#define _DEFAULT_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <sys/socket.h>
#include <unistd.h>

static int listener = -1;
/* The host's connection, and whether its end of the bytes has come */
static int conn = -1;
static int ended;

int cosim_open(int port)
{
    struct sockaddr_in a = {0};
    socklen_t len = sizeof a;
    int on = 1;

    listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0)
        return -1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listener, (struct sockaddr *)&a, sizeof a) ||
        listen(listener, 4) ||
        getsockname(listener, (struct sockaddr *)&a, &len))
        return -1;
    fcntl(listener, F_SETFL, O_NONBLOCK);
    printf("cosim: port %d\n", ntohs(a.sin_port));
    fflush(stdout);
    return 0;
}

/* Takes a waiting host when none is served, or the one served has ended. */
static void take(void)
{
    int fd;

    if (conn >= 0 && !ended)
        return;
    fd = accept(listener, NULL, NULL);
    if (fd < 0)
        return;
    fcntl(fd, F_SETFL, O_NONBLOCK);
    if (conn >= 0)
        close(conn);
    conn = fd;
    ended = 0;
}

int cosim_read(void)
{
    unsigned char c;
    ssize_t n;

    take();
    if (conn < 0 || ended)
        return -1;
    n = recv(conn, &c, 1, 0);
    if (n == 1)
        return c;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR))
        return -1;
    ended = 1;
    return -2;
}

int cosim_write(int c)
{
    unsigned char b = (unsigned char)c;
    ssize_t n;

    while (conn >= 0) {
        n = send(conn, &b, 1, MSG_NOSIGNAL);
        if (n == 1)
            break;
        if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            /* The host has gone; the byte is dropped. */
            close(conn);
            conn = -1;
            break;
        }
        usleep(100);
    }
    return 0;
}
