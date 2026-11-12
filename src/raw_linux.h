#ifndef RAW_LINUX_H
#define RAW_LINUX_H

/* Tiny libc-free Linux syscall layer. Builds as native x86_64 for tests and
 * as static AArch64 for Yandex Station Lite 1. */
typedef unsigned long usize;
typedef long isize;
typedef unsigned long u64;
typedef long s64;
typedef unsigned int u32;
typedef int s32;
typedef unsigned short u16;
typedef short s16;
typedef unsigned char u8;

#if defined(__aarch64__)
#define SYS_READ 63
#define SYS_WRITE 64
#define SYS_CLOSE 57
#define SYS_OPENAT 56
#define SYS_LSEEK 62
#define SYS_UNLINKAT 35
#define SYS_FCHMODAT 53
#define SYS_SOCKET 198
#define SYS_BIND 200
#define SYS_SETSOCKOPT 208
#define SYS_RECVFROM 207
#define SYS_CLOCK_GETTIME 113
#define SYS_RT_SIGACTION 134
#define SYS_EXIT 93
#define SYS_GETPID 172
#elif defined(__x86_64__)
#define SYS_READ 0
#define SYS_WRITE 1
#define SYS_CLOSE 3
#define SYS_OPENAT 257
#define SYS_LSEEK 8
#define SYS_UNLINKAT 263
#define SYS_FCHMODAT 268
#define SYS_SOCKET 41
#define SYS_BIND 49
#define SYS_SETSOCKOPT 54
#define SYS_RECVFROM 45
#define SYS_CLOCK_GETTIME 228
#define SYS_RT_SIGACTION 13
#define SYS_EXIT 60
#define SYS_GETPID 39
#else
#error Unsupported architecture
#endif

static inline isize sc0(long nr) {
#if defined(__aarch64__)
    register long x8 __asm__("x8") = nr;
    register long x0 __asm__("x0");
    __asm__ volatile("svc 0" : "=r"(x0) : "r"(x8) : "memory");
    return x0;
#else
    register long rax __asm__("rax") = nr;
    __asm__ volatile("syscall" : "+a"(rax) : : "rcx", "r11", "memory");
    return rax;
#endif
}

static inline isize sc1(long nr, long a0) {
#if defined(__aarch64__)
    register long x8 __asm__("x8") = nr;
    register long x0 __asm__("x0") = a0;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8) : "memory");
    return x0;
#else
    register long rax __asm__("rax") = nr;
    register long rdi __asm__("rdi") = a0;
    __asm__ volatile("syscall" : "+a"(rax) : "D"(rdi) : "rcx", "r11", "memory");
    return rax;
#endif
}

static inline isize sc2(long nr, long a0, long a1) {
#if defined(__aarch64__)
    register long x8 __asm__("x8") = nr;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1) : "memory");
    return x0;
#else
    register long rax __asm__("rax") = nr;
    register long rdi __asm__("rdi") = a0;
    register long rsi __asm__("rsi") = a1;
    __asm__ volatile("syscall" : "+a"(rax) : "D"(rdi), "S"(rsi) : "rcx", "r11", "memory");
    return rax;
#endif
}

static inline isize sc3(long nr, long a0, long a1, long a2) {
#if defined(__aarch64__)
    register long x8 __asm__("x8") = nr;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
#else
    register long rax __asm__("rax") = nr;
    register long rdi __asm__("rdi") = a0;
    register long rsi __asm__("rsi") = a1;
    register long rdx __asm__("rdx") = a2;
    __asm__ volatile("syscall" : "+a"(rax) : "D"(rdi), "S"(rsi), "d"(rdx) : "rcx", "r11", "memory");
    return rax;
#endif
}

static inline isize sc4(long nr, long a0, long a1, long a2, long a3) {
#if defined(__aarch64__)
    register long x8 __asm__("x8") = nr;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    register long x3 __asm__("x3") = a3;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
    return x0;
#else
    register long rax __asm__("rax") = nr;
    register long rdi __asm__("rdi") = a0;
    register long rsi __asm__("rsi") = a1;
    register long rdx __asm__("rdx") = a2;
    register long r10 __asm__("r10") = a3;
    __asm__ volatile("syscall" : "+a"(rax) : "D"(rdi), "S"(rsi), "d"(rdx), "r"(r10) : "rcx", "r11", "memory");
    return rax;
#endif
}

static inline isize sc5(long nr, long a0, long a1, long a2, long a3, long a4) {
#if defined(__aarch64__)
    register long x8 __asm__("x8") = nr;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    register long x3 __asm__("x3") = a3;
    register long x4 __asm__("x4") = a4;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4) : "memory");
    return x0;
#else
    register long rax __asm__("rax") = nr;
    register long rdi __asm__("rdi") = a0;
    register long rsi __asm__("rsi") = a1;
    register long rdx __asm__("rdx") = a2;
    register long r10 __asm__("r10") = a3;
    register long r8 __asm__("r8") = a4;
    __asm__ volatile("syscall" : "+a"(rax) : "D"(rdi), "S"(rsi), "d"(rdx), "r"(r10), "r"(r8) : "rcx", "r11", "memory");
    return rax;
#endif
}

static inline isize sc6(long nr, long a0, long a1, long a2, long a3, long a4, long a5) {
#if defined(__aarch64__)
    register long x8 __asm__("x8") = nr;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    register long x3 __asm__("x3") = a3;
    register long x4 __asm__("x4") = a4;
    register long x5 __asm__("x5") = a5;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory");
    return x0;
#else
    register long rax __asm__("rax") = nr;
    register long rdi __asm__("rdi") = a0;
    register long rsi __asm__("rsi") = a1;
    register long rdx __asm__("rdx") = a2;
    register long r10 __asm__("r10") = a3;
    register long r8 __asm__("r8") = a4;
    register long r9 __asm__("r9") = a5;
    __asm__ volatile("syscall" : "+a"(rax) : "D"(rdi), "S"(rsi), "d"(rdx), "r"(r10), "r"(r8), "r"(r9) : "rcx", "r11", "memory");
    return rax;
#endif
}

#define AT_FDCWD (-100)
#define O_RDONLY 0
#define O_WRONLY 1
#define O_CREAT 64
#define O_TRUNC 512
#define O_APPEND 1024
#define AF_UNIX 1
#define SOCK_DGRAM 2
#define SOL_SOCKET 1
#define SO_RCVBUF 8
#define SO_RCVTIMEO 20
#define CLOCK_REALTIME 0
#define CLOCK_MONOTONIC 1
#define EINTR 4
#define EAGAIN 11
#define EWOULDBLOCK 11

struct timespec64 { s64 tv_sec; s64 tv_nsec; };
struct timeval64 { s64 tv_sec; s64 tv_usec; };

static inline int is_error(isize r) { return r < 0 && r >= -4095; }
static inline isize sys_write(int fd, const void *p, usize n) { return sc3(SYS_WRITE, fd, (long)p, n); }
static inline isize sys_read(int fd, void *p, usize n) { return sc3(SYS_READ, fd, (long)p, n); }
static inline void sys_close(int fd) { (void)sc1(SYS_CLOSE, fd); }
static inline isize sys_openat(const char *p, int flags, int mode) { return sc4(SYS_OPENAT, AT_FDCWD, (long)p, flags, mode); }
static inline isize sys_lseek(int fd, long off, int whence) { return sc3(SYS_LSEEK, fd, off, whence); }
static inline isize sys_unlink(const char *p) { return sc3(SYS_UNLINKAT, AT_FDCWD, (long)p, 0); }
static inline isize sys_chmod(const char *p, int mode) { return sc4(SYS_FCHMODAT, AT_FDCWD, (long)p, mode, 0); }
static inline isize sys_clock_gettime(int id, struct timespec64 *ts) { return sc2(SYS_CLOCK_GETTIME, id, (long)ts); }

#endif
