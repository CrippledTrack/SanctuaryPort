/* macOS: the process heap below 1 TiB. The game packs pointers into 40-bit fields, and host heap
 * objects reach it (thread handles, TLS and TCB blocks, mutex and semaphore objects). Linux keeps
 * them in the low brk heap (probe.c mallopt) and Windows in a low heap (no high-entropy ASLR);
 * macOS malloc hands out addresses near 0x7fxx_xxxx_xxxx. mimalloc (linked as an object, built
 * as the default malloc zone: packaging/macos/deps.sh) takes over malloc for the whole process,
 * system libraries included, and is given one region right above the PS4 user range,
 * [0xfc00000000, 0x10000000000): 16 GiB, below 1 TiB, never used by the guest. It may not
 * take memory from the OS anywhere else. */
#ifdef __APPLE__
#include <mimalloc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#define HEAP_BASE UINT64_C(0xfc00000000)
#define HEAP_SIZE (UINT64_C(16) << 30)

/* Before other constructors that allocate (priority 101 is the first one user code gets). */
__attribute__((constructor(101))) static void macos_low_heap(void) {
    /* Read-write and untouched: macOS commits pages only when they are used. */
    void *heap = mmap((void *)HEAP_BASE, HEAP_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (heap != (void *)HEAP_BASE) {
        static const char message[] = "STOP: cannot reserve the heap below 1 TiB (0xfc00000000)\n";
        ssize_t written = write(2, message, sizeof(message) - 1);
        (void)written;
        _exit(21);
    }
    if (!mi_manage_os_memory(heap, HEAP_SIZE, true, false, true, -1)) {
        static const char message[] = "STOP: mimalloc refused the low heap region\n";
        ssize_t written = write(2, message, sizeof(message) - 1);
        (void)written;
        _exit(21);
    }
    /* Every later allocation comes from that region (an allocation it cannot satisfy fails). */
    mi_option_set(mi_option_arena_reserve, 0);
    mi_option_set_enabled(mi_option_limit_os_alloc, true);
}

uint64_t runtime_macos_heap_base(void) { return HEAP_BASE; }
#endif
