// sanctuary (macOS): Linux calls the GPU library uses, force-included on macOS like
// sanctuary_win_compat.h on Windows. The macOS build is x86_64 under Rosetta 2 (docs/macos.md).
#pragma once
#ifdef SANCTUARY_MACOS
#include <pthread.h>
#include <stdint.h>
#include <sys/resource.h>

// Linux thread id: macOS's 64-bit thread id, truncated (logs, diagnostics and thread matching).
static inline int gettid(void) {
    uint64_t id = 0;
    pthread_threadid_np(nullptr, &id);
    return static_cast<int>(id);
}

// getrusage(RUSAGE_THREAD): src/compat_mac.c (the calling thread's CPU times through thread_info).
#define RUSAGE_THREAD 1
extern "C" int compat_getrusage(int who, struct rusage* usage);
#define getrusage(who, usage) compat_getrusage((who), (usage))
#endif
