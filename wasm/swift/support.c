/* Minimal C support for Embedded Swift on wasm32-unknown-none-wasm.
 *
 * The Swift toolchain in this repo ships Embedded Swift modules +
 * wasm-ld, but no WASI sysroot / libc for this target. Embedded
 * Swift code needs an allocator (posix_memalign/free), putchar,
 * stack-check failure, and the usual memory intrinsics. The
 * allocator is a first-fit free list over a fixed arena with
 * splitting and coalescing: free actually returns memory, so a
 * call's intermediate copies (payload in, message, response
 * out) reuse the same arena instead of consuming it forever.
 * (The previous bump allocator never freed; a large call whose
 * copies summed past the arena trapped Swift's allocation
 * failure, and repeated calls leaked the arena per page.)
 * Compiled with zig cc -target wasm32-freestanding and linked
 * with wasm-ld next to the Swift object. */
#include <stddef.h>

/* 128 MiB arena: a multi-MiB call holds many live copies at
 * once (bridge input, byte-array copy, decoded message,
 * response build, marshaled output — plus power-of-two array
 * growth transients), and the free list reuses freed copies
 * within the same call. Measured: an 8 MiB unary peaks past
 * the old 64 MiB and traps Swift's allocation failure
 * (surfaced as INTERNAL: unreachable); 128 MiB covers it
 * with headroom. Payloads far beyond 8 MiB will still hit
 * this ceiling — it is an arena, not a streaming path. */
#define HEAP_BYTES (128u * 1024u * 1024u)
#define HEAP_ALIGN 16u
#define BLOCK_HEADER 16u /* header, 16-aligned; payload follows */

typedef struct block {
    size_t payload_cap; /* usable bytes after the header */
    struct block *next; /* all blocks, in address order */
    int is_free;
    int reserved;
} block_t;

static _Alignas(16) unsigned char g_heap[HEAP_BYTES];
static block_t *g_blocks;

static size_t align_up(size_t value, size_t alignment) {
    if (alignment < sizeof(void *)) alignment = sizeof(void *);
    return (value + alignment - 1) & ~(alignment - 1);
}

static void heap_init(void) {
    if (g_blocks) return;
    g_blocks = (block_t *)g_heap;
    g_blocks->payload_cap = HEAP_BYTES - BLOCK_HEADER;
    g_blocks->next = NULL;
    g_blocks->is_free = 1;
    g_blocks->reserved = 0;
}

static block_t *block_of(void *payload) {
    return (block_t *)((unsigned char *)payload - BLOCK_HEADER);
}

/* Split `block` so its payload capacity becomes `want`; the
 * remainder becomes a new free block after it. Caller ensures
 * the remainder can hold a header plus a minimal payload. */
static void split_block(block_t *block, size_t want) {
    block_t *rest = (block_t *)((unsigned char *)block + BLOCK_HEADER + want);
    rest->payload_cap = block->payload_cap - want - BLOCK_HEADER;
    rest->next = block->next;
    rest->is_free = 1;
    rest->reserved = 0;
    block->payload_cap = want;
    block->next = rest;
}

void *malloc(size_t size) {
    if (size == 0) size = 1;
    size_t want = align_up(size, HEAP_ALIGN);
    heap_init();
    for (block_t *block = g_blocks; block; block = block->next) {
        if (!block->is_free || block->payload_cap < want) continue;
        if (block->payload_cap >= want + BLOCK_HEADER + HEAP_ALIGN) {
            split_block(block, want);
        }
        block->is_free = 0;
        return (unsigned char *)block + BLOCK_HEADER;
    }
    return NULL;
}

int posix_memalign(void **memptr, size_t alignment, size_t size) {
    if (alignment <= HEAP_ALIGN) {
        void *ptr = malloc(size);
        if (!ptr) return 12; /* ENOMEM */
        *memptr = ptr;
        return 0;
    }
    /* Over-allocate, align the payload, and split off the
     * alignment waste as its own free block so the header sits
     * exactly BLOCK_HEADER before the payload (block_of). */
    if (size == 0) size = 1;
    heap_init();
    size_t want = align_up(size, HEAP_ALIGN);
    for (block_t *block = g_blocks; block; block = block->next) {
        if (!block->is_free) continue;
        unsigned char *payload = (unsigned char *)block + BLOCK_HEADER;
        unsigned char *aligned = (unsigned char *)align_up((size_t)payload, alignment);
        size_t waste = (size_t)(aligned - payload);
        if (block->payload_cap < waste + want) continue;
        if (waste > 0) {
            if (waste < BLOCK_HEADER + HEAP_ALIGN) continue;
            /* Prefix [block .. aligned) becomes: the used
             * block's header at aligned-BLOCK_HEADER, with a
             * free block filling before it. Encode by splitting
             * a free prefix block first. */
            split_block(block, waste - BLOCK_HEADER);
            block->is_free = 1;
            block = block->next; /* the used block */
        }
        if (block->payload_cap >= want + BLOCK_HEADER + HEAP_ALIGN) {
            split_block(block, want);
        }
        block->is_free = 0;
        *memptr = (unsigned char *)block + BLOCK_HEADER;
        return 0;
    }
    return 12; /* ENOMEM */
}

void *calloc(size_t count, size_t size) {
    size_t total = count * size;
    unsigned char *ptr = malloc(total);
    if (ptr) {
        for (size_t i = 0; i < total; i++) ptr[i] = 0;
    }
    return ptr;
}

void free(void *ptr) {
    if (!ptr) return;
    heap_init();
    block_t *block = block_of(ptr);
    block->is_free = 1;
    /* Coalesce with the following block when adjacent-free. */
    block_t *next = block->next;
    if (next && next->is_free &&
        (unsigned char *)block + BLOCK_HEADER + block->payload_cap == (unsigned char *)next) {
        block->payload_cap += BLOCK_HEADER + next->payload_cap;
        block->next = next->next;
    }
    /* Coalesce into the previous block when it is free and
     * adjacent (list is address-ordered). */
    for (block_t *prev = g_blocks; prev && prev != block; prev = prev->next) {
        if (prev->next == block) {
            if (prev->is_free &&
                (unsigned char *)prev + BLOCK_HEADER + prev->payload_cap == (unsigned char *)block) {
                prev->payload_cap += BLOCK_HEADER + block->payload_cap;
                prev->next = block->next;
            }
            break;
        }
    }
}

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
