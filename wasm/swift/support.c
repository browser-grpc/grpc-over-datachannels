/* Minimal C support for Embedded Swift on wasm32-unknown-none-wasm.
 *
 * The Swift toolchain in this repo ships Embedded Swift modules +
 * wasm-ld, but no WASI sysroot / libc for this target. Embedded
 * Swift code needs an allocator (posix_memalign/free), putchar,
 * stack-check failure, and the usual memory intrinsics. A bump
 * allocator over a fixed arena is sufficient for the facade's
 * page-lifetime allocations: free is a no-op, so bridge memory is
 * reclaimed when the page tears the module down. Compiled with
 * zig cc -target wasm32-freestanding and linked with wasm-ld
 * next to the Swift object. */
#include <stddef.h>

#define HEAP_BYTES (4u * 1024u * 1024u)
static _Alignas(16) unsigned char g_heap[HEAP_BYTES];
static size_t g_offset;

static size_t align_up(size_t value, size_t alignment) {
    if (alignment < sizeof(void *)) alignment = sizeof(void *);
    return (value + alignment - 1) & ~(alignment - 1);
}

int posix_memalign(void **memptr, size_t alignment, size_t size) {
    size_t start = align_up(g_offset, alignment);
    if (start + size > HEAP_BYTES) return 12; /* ENOMEM */
    *memptr = g_heap + start;
    g_offset = start + size;
    return 0;
}

void *malloc(size_t size) {
    void *ptr = 0;
    return posix_memalign(&ptr, 16, size) == 0 ? ptr : 0;
}

void *calloc(size_t count, size_t size) {
    size_t total = count * size;
    unsigned char *ptr = malloc(total);
    if (ptr) {
        for (size_t i = 0; i < total; i++) ptr[i] = 0;
    }
    return ptr;
}

void free(void *ptr) { (void)ptr; }

int putchar(int c) { return c; }

/* Swift's hash seed randomization. Not a security boundary for
 * this facade (keys are local call ids), so a small splitmix64
 * generator is sufficient; pages needing stronger randomness
 * can override this symbol at link time. */
void arc4random_buf(void *buf, size_t n) {
    static unsigned long long state = 0x9e3779b97f4a7c15ull;
    unsigned char *out = buf;
    for (size_t i = 0; i < n; i++) {
        state += 0x9e3779b97f4a7c15ull;
        unsigned long long z = state;
        z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull;
        z = (z ^ (z >> 27)) * 0x94d049bb133111ebull;
        out[i] = (unsigned char)(z ^ (z >> 31));
    }
}

void __stack_chk_fail(void) { __builtin_trap(); }

void *memcpy(void *dst, const void *src, size_t n) {
    unsigned char *d = dst;
    const unsigned char *s = src;
    for (size_t i = 0; i < n; i++) d[i] = s[i];
    return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
    unsigned char *d = dst;
    const unsigned char *s = src;
    if (d == s) return dst;
    if (d < s) {
        for (size_t i = 0; i < n; i++) d[i] = s[i];
    } else {
        for (size_t i = n; i > 0; i--) d[i - 1] = s[i - 1];
    }
    return dst;
}

void *memset(void *dst, int c, size_t n) {
    unsigned char *d = dst;
    for (size_t i = 0; i < n; i++) d[i] = (unsigned char)c;
    return dst;
}

int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *x = a;
    const unsigned char *y = b;
    for (size_t i = 0; i < n; i++) {
        if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
    }
    return 0;
}

size_t strlen(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    return n;
}

/* libm/compiler-rt helpers Swift's stdlib references on this
 * target (Double rounding / conversion, 128-bit multiply). */
double round(double x) {
    if (x != x) return x;
    if (x >= 4503599627370496.0 || x <= -4503599627370496.0) return x;
    long long i = (long long)(x >= 0 ? x + 0.5 : x - 0.5);
    return (double)i;
}

double fma(double a, double b, double c) { return a * b + c; }

void __multi3(unsigned long long *ret, unsigned long long a_lo,
              unsigned long long a_hi, unsigned long long b_lo,
              unsigned long long b_hi) {
    unsigned __int128 a = ((unsigned __int128)a_hi << 64) | a_lo;
    unsigned __int128 b = ((unsigned __int128)b_hi << 64) | b_lo;
    unsigned __int128 r = a * b;
    ret[0] = (unsigned long long)r;
    ret[1] = (unsigned long long)(r >> 64);
}
