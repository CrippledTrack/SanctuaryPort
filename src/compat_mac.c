/* macOS counterparts of Linux calls (compat_mac.h). */
#ifdef __APPLE__
#include <errno.h>
#include <mach/mach.h>
#include <pthread.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
/* The real calls, not compat_mac.h's macros. */
int compat_getrusage(int who, struct rusage *usage);
int compat_clock_nanosleep(clockid_t clock, int flags, const struct timespec *t, struct timespec *rest);
int compat_mutex_timedlock(pthread_mutex_t *mutex, const struct timespec *deadline);
int compat_rwlock_timedrdlock(pthread_rwlock_t *lock, const struct timespec *deadline);
int compat_rwlock_timedwrlock(pthread_rwlock_t *lock, const struct timespec *deadline);

int compat_getrusage(int who, struct rusage *usage) {
    if (who != 1 /* RUSAGE_THREAD */) return getrusage(who, usage);
    memset(usage, 0, sizeof(*usage));
    thread_basic_info_data_t info;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    mach_port_t thread = pthread_mach_thread_np(pthread_self());
    if (thread_info(thread, THREAD_BASIC_INFO, (thread_info_t)&info, &count) != KERN_SUCCESS) {
        errno = EINVAL;
        return -1;
    }
    usage->ru_utime.tv_sec = info.user_time.seconds;
    usage->ru_utime.tv_usec = info.user_time.microseconds;
    usage->ru_stime.tv_sec = info.system_time.seconds;
    usage->ru_stime.tv_usec = info.system_time.microseconds;
    return 0;
}

static int64_t ns_of(const struct timespec *t) { return (int64_t)t->tv_sec * 1000000000 + t->tv_nsec; }
static int64_t now_ns(clockid_t clock) { struct timespec t; clock_gettime(clock, &t); return ns_of(&t); }

int compat_clock_nanosleep(clockid_t clock, int flags, const struct timespec *t, struct timespec *rest) {
    int64_t wait = (flags & 1) ? ns_of(t) - now_ns(clock) : ns_of(t);
    if (wait <= 0) return 0;
    struct timespec d = {(time_t)(wait / 1000000000), (long)(wait % 1000000000)};
    return nanosleep(&d, rest) ? errno : 0;
}

/* Short sleeps until the lock is free or the deadline passes. */
#define TIMED_LOCK(trylock)                                                                       \
    for (long sleep_ns = 20000;;) {                                                               \
        int e = (trylock);                                                                        \
        if (e != EBUSY) return e;                                                                 \
        int64_t left = ns_of(deadline) - now_ns(CLOCK_REALTIME);                                  \
        if (left <= 0) return ETIMEDOUT;                                                          \
        struct timespec d = {0, left < sleep_ns ? (long)left : sleep_ns};                         \
        nanosleep(&d, NULL);                                                                      \
        if (sleep_ns < 1000000) sleep_ns *= 2;                                                    \
    }
int compat_mutex_timedlock(pthread_mutex_t *mutex, const struct timespec *deadline) {
    TIMED_LOCK(pthread_mutex_trylock(mutex))
}
int compat_rwlock_timedrdlock(pthread_rwlock_t *lock, const struct timespec *deadline) {
    TIMED_LOCK(pthread_rwlock_tryrdlock(lock))
}
int compat_rwlock_timedwrlock(pthread_rwlock_t *lock, const struct timespec *deadline) {
    TIMED_LOCK(pthread_rwlock_trywrlock(lock))
}
#endif
