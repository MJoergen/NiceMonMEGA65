// Counts the primes up to a limit that it reads from the UART, with the
// sieve of Eratosthenes, as nice_cpu/translator/test/primes.c does. It reads
// with scanf and prints with printf, from nice_cpu's C library. It also
// prints how long the count took, from the performance counters (ISA.md
// §8.5), which nice_cycles and nice_instructions of nice.h read. It asks
// again until it reads 0, and then halts.

#include <nice.h>
#include <stdio.h>
#include <string.h>

#define MAX_LIMIT 20000

// composite[i] is set when i is not a prime.
static unsigned char composite[MAX_LIMIT + 1];

static int count_primes(int n)
{
    int count = 0;
    memset(composite, 0, n + 1);
    for (int i = 2; i <= n; i++) {
        if (composite[i])
            continue;
        count++;
        for (int j = i * i; j <= n; j += i)
            composite[j] = 1;
    }
    return count;
}

// Skips the rest of the line, after input that is not a number.
static void skip_line(void)
{
    int c;
    do
        c = getchar();
    while (c != '\r' && c != '\n' && c != EOF);
}

int main(void)
{
    for (;;) {
        int limit;
        printf("Count the primes up to (0 to stop): ");
        if (scanf("%d", &limit) != 1) {
            skip_line();
            printf("\r\nThat is not a number.\r\n");
            continue;
        }
        printf("%d\r\n", limit);
        if (limit == 0)
            return 0;
        if (limit < 0 || limit > MAX_LIMIT) {
            printf("The limit must be from 1 to %d.\r\n", MAX_LIMIT);
            continue;
        }

        unsigned long long cycles = nice_cycles();
        unsigned long long instrs = nice_instructions();
        int count = count_primes(limit);
        cycles = nice_cycles() - cycles;
        instrs = nice_instructions() - instrs;

        printf("Primes up to %d: %d\r\n", limit, count);
        printf("%llu instructions in %llu cycles\r\n", instrs, cycles);
    }
}
