/* x86-64 registers of a signal context, by index, on Linux and macOS (the runtime only runs on
 * x86-64; macOS through Rosetta 2). Linux: ucontext gregs with glibc's REG_* numbering. macOS: the
 * thread state struct (__ss: rax rbx rcx rdx rdi rsi rbp rsp r8-r15 rip rflags), whose order the
 * REG_* names below follow. Use HOST_GREGS(uc)[REG_RIP] and friends, never uc_mcontext directly. */
#ifndef SANCTUARY_HOST_UCONTEXT_H
#define SANCTUARY_HOST_UCONTEXT_H
#ifndef _WIN32
#include <stdint.h>
#ifdef __APPLE__
#include <sys/ucontext.h>
typedef uint64_t greg_t;
enum {
    REG_RAX, REG_RBX, REG_RCX, REG_RDX, REG_RDI, REG_RSI, REG_RBP, REG_RSP,
    REG_R8, REG_R9, REG_R10, REG_R11, REG_R12, REG_R13, REG_R14, REG_R15,
    REG_RIP, REG_EFL,
};
#define HOST_GREGS(uc) ((greg_t *)&(uc)->uc_mcontext->__ss)
/* A write fault: the page-fault error code's write bit. */
#define HOST_FAULT_IS_WRITE(uc) (((uc)->uc_mcontext->__es.__err & 2) != 0)
#else
#include <ucontext.h>
#define HOST_GREGS(uc) ((uc)->uc_mcontext.gregs)
#define HOST_FAULT_IS_WRITE(uc) (((uc)->uc_mcontext.gregs[REG_ERR] & 2) != 0)
#endif
#endif
#endif
