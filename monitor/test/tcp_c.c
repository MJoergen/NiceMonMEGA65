// The test of TCP's entries from C (issue #111), built with nicebuild.py
// --monitor --asm mon.nasm --asm mon_c.nasm (Makefile), so that a pointer
// of C, an offset in the wasm module's memory, goes through the stubs of
// mon_c.nasm. tools/tcptest.py runs it under the monitor of the tests in
// niceemu, against tools/tcppeer.py, whose port 2001 echoes. It sets
// 10.0.0.9, reads it back, sends 1000 bytes from an odd address, receives
// them at another, compares, and closes. Then it listens on port 3010,
// where the peer connects and sends 200 bytes, which it sends back, and
// closes. It returns 0, or the number of the step that failed, times
// 1000, less the error.
#include "mon.h"

#define RX 512
#define TX 300

static unsigned cb[TCP_CB_WORDS(RX, TX)];
static unsigned char out[1001];
static unsigned char in[1003];

static int fail(int step, int err)
{
    return step * 1000 - err;
}

static int wait_state(int h, int want)
{
    int s = h;
    for (unsigned i = 0; i < 2000000; i++) {
        s = tcp_state(h);
        if (s == want || s < 0)
            break;
    }
    return s;
}

int main(void)
{
    static const unsigned set[4] = {0x0A000009, 0xFFFFFF00, 0, 0};
    unsigned cfg[4];
    if (net_set(set) != 0)
        return fail(1, 0);
    if (net_config(cfg) != 0 || cfg[0] != 0x0A000009 || cfg[1] != 0xFFFFFF00)
        return fail(2, 0);
    for (unsigned i = 0; i < 1000; i++)
        out[1 + i] = (unsigned char)(i * 7 + 3);
    int h = tcp_open(cb, 0x0A000002, 2001, TCP_SIZES(RX, TX));
    if (h < 0)
        return fail(3, h);
    int s = wait_state(h, TCP_OPEN);
    if (s != TCP_OPEN)
        return fail(4, s);
    unsigned sent = 0, got = 0;
    for (unsigned i = 0; i < 4000000 && got < 1000; i++) {
        if (sent < 1000) {
            int n = tcp_send(h, out + 1 + sent, 1000 - sent);
            if (n < 0)
                return fail(5, n);
            sent += (unsigned)n;
        }
        int n = tcp_recv(h, in + 3 + got, 1000 - got);
        if (n < 0)
            return fail(6, n);
        got += (unsigned)n;
    }
    if (got != 1000)
        return fail(7, 0);
    for (unsigned i = 0; i < 1000; i++)
        if (in[3 + i] != out[1 + i])
            return fail(8, 0);
    if (tcp_close(h, 0) != 0)
        return fail(9, 0);
    s = wait_state(h, TCP_FREE);
    if (s != TCP_FREE)
        return fail(10, s);

    h = tcp_listen(cb, 3010, TCP_SIZES(RX, TX));
    if (h < 0)
        return fail(11, h);
    got = 0;
    for (unsigned i = 0; i < 4000000 && got < 200; i++) {
        int n = tcp_recv(h, in + 1 + got, 200 - got);
        if (n < 0)
            return fail(12, n);
        got += (unsigned)n;
    }
    if (got != 200)
        return fail(13, 0);
    sent = 0;
    for (unsigned i = 0; i < 4000000 && sent < 200; i++) {
        int n = tcp_send(h, in + 1 + sent, 200 - sent);
        if (n < 0)
            return fail(14, n);
        sent += (unsigned)n;
    }
    if (sent != 200 || tcp_close(h, 0) != 0)
        return fail(15, 0);
    s = wait_state(h, TCP_FREE);
    if (s != TCP_FREE)
        return fail(16, s);
    return 0;
}
