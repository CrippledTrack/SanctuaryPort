/* macOS counterparts of the Linux (glibc) calls the runtime uses. Included through runtime.h
 * after the C library headers, like compat_win.h, so the macros only replace calls in this
 * project's own sources. The macOS build is x86_64 and runs under Rosetta 2 (docs/macos.md). */
#ifndef SANCTUARY_COMPAT_MAC_H
#define SANCTUARY_COMPAT_MAC_H
#ifdef __APPLE__
#include <errno.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>

#ifndef PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP
#define PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP PTHREAD_RECURSIVE_MUTEX_INITIALIZER
#endif
#ifndef CLOCK_REALTIME_COARSE
#define CLOCK_REALTIME_COARSE CLOCK_REALTIME
#endif
/* struct stat: Linux st_atim/st_mtim/st_ctim are st_*timespec on macOS. */
#define st_atim st_atimespec
#define st_mtim st_mtimespec
#define st_ctim st_ctimespec

/* getrusage(RUSAGE_THREAD): the calling thread's CPU times (thread_info). */
#define RUSAGE_THREAD 1
struct rusage;
int compat_getrusage(int who, struct rusage *usage);
#define getrusage(who, usage) compat_getrusage((who), (usage))

static inline ssize_t compat_getrandom(void *buffer, size_t size, unsigned flags) {
    (void)flags;
    arc4random_buf(buffer, size);
    return (ssize_t)size;
}
#define getrandom(buffer, size, flags) compat_getrandom((buffer), (size), (flags))

/* clock_nanosleep: only relative sleeps exist; TIMER_ABSTIME on CLOCK_MONOTONIC is emulated. */
#ifndef TIMER_ABSTIME
#define TIMER_ABSTIME 1
#endif
int compat_clock_nanosleep(clockid_t clock, int flags, const struct timespec *t, struct timespec *rest);
#define clock_nanosleep(clock, flags, t, rest) compat_clock_nanosleep((clock), (flags), (t), (rest))

/* Timed locks (absolute CLOCK_REALTIME deadlines, as in POSIX): try-lock with short sleeps. */
int compat_mutex_timedlock(pthread_mutex_t *mutex, const struct timespec *deadline);
int compat_rwlock_timedrdlock(pthread_rwlock_t *lock, const struct timespec *deadline);
int compat_rwlock_timedwrlock(pthread_rwlock_t *lock, const struct timespec *deadline);
#define pthread_mutex_timedlock(m, d) compat_mutex_timedlock((m), (d))
#define pthread_rwlock_timedrdlock(l, d) compat_rwlock_timedrdlock((l), (d))
#define pthread_rwlock_timedwrlock(l, d) compat_rwlock_timedwrlock((l), (d))

/* Sockets: no SOCK_CLOEXEC or accept4. The restart path closes every descriptor before exec
 * (probe.c), so close-on-exec only matters there. */
#ifndef SOCK_CLOEXEC
#define SOCK_CLOEXEC 0
#endif
#define accept4(fd, address, length, flags) ((void)(flags), accept((fd), (address), (length)))

/* Linux thread id: macOS's 64-bit thread id, truncated (logs and diagnostics only). */
static inline pid_t compat_gettid(void) { uint64_t id = 0; pthread_threadid_np(NULL, &id); return (pid_t)id; }
#define gettid() compat_gettid()

/* Condition variables wait on CLOCK_REALTIME only (runtime_sema.c picks that clock here). */
#define pthread_condattr_setclock(attr, clock) ((void)(attr), (clock) == CLOCK_REALTIME ? 0 : EINVAL)
#endif
#endif
