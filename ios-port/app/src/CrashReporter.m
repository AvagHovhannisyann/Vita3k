#import "CrashReporter.h"
#import "JitArena.h"
#import <execinfo.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <string.h>
#import <stdlib.h>
#import <pthread.h>

// A signal handler may only call async-signal-safe functions, so everything
// below writes with write(2) and formats by hand. The path is resolved and
// cached at install time for the same reason.
static char g_crashPath[1024];
static struct sigaction g_old[8];
static const int kSignals[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP, SIGSYS };
static const int kSignalCount = (int)(sizeof kSignals / sizeof kSignals[0]);

static void w(int fd, const char *s) { if (s) write(fd, s, strlen(s)); }

static void whex(int fd, unsigned long long v) {
    char buf[19] = "0x0000000000000000";
    for (int i = 17; i >= 2; --i) { buf[i] = "0123456789abcdef"[v & 0xf]; v >>= 4; }
    write(fd, buf, 18);
}

static void wdec(int fd, long long v) {
    char buf[24]; int i = (int)sizeof buf;
    int neg = v < 0; unsigned long long u = neg ? (unsigned long long)(-v) : (unsigned long long)v;
    buf[--i] = '\0';
    do { buf[--i] = (char)('0' + (u % 10)); u /= 10; } while (u);
    if (neg) buf[--i] = '-';
    w(fd, &buf[i]);
}

static const char *signame(int s) {
    switch (s) {
        case SIGSEGV: return "SIGSEGV (bad memory access)";
        case SIGBUS:  return "SIGBUS (bad address / non-executable page)";
        case SIGILL:  return "SIGILL (illegal instruction)";
        case SIGFPE:  return "SIGFPE (arithmetic)";
        case SIGABRT: return "SIGABRT (abort/assert)";
        case SIGTRAP: return "SIGTRAP (breakpoint — an unanswered brk?)";
        case SIGSYS:  return "SIGSYS (bad syscall)";
        default:      return "signal";
    }
}

// Say where the faulting address lives. When the recompiler is running, "inside
// the JIT arena" versus "outside it" is the difference between a bad emitted
// instruction and a page that was never made executable.
static void describeAddress(int fd, void *addr) {
    unsigned long size = v3k_ios_jit_size();
    if (!size) { w(fd, "  (no JIT arena in this process)\n"); return; }
    uintptr_t a = (uintptr_t)addr;
    uintptr_t rx = (uintptr_t)v3k_ios_jit_rx(), rw = (uintptr_t)v3k_ios_jit_rw();
    if (rx && a >= rx && a < rx + size) {
        w(fd, "  INSIDE the JIT arena's executable mapping, offset ");
        whex(fd, a - rx); w(fd, "\n  -> the page is blessed but this instruction faulted: "
                                "suspect emitted code or a stale icache.\n");
    } else if (rw && a >= rw && a < rw + size) {
        w(fd, "  INSIDE the JIT arena's writable alias, offset ");
        whex(fd, a - rw); w(fd, "\n  -> a write went to the wrong mapping.\n");
    } else {
        w(fd, "  OUTSIDE the JIT arena (rx="); whex(fd, rx);
        w(fd, " rw="); whex(fd, rw); w(fd, " size="); wdec(fd, (long long)size); w(fd, ")\n");
    }
}

static void handler(int sig, siginfo_t *info, void *uap) {
    (void)uap;
    int fd = open(g_crashPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        w(fd, "Vita3K iOS crash report\n=======================\n\nsignal: ");
        w(fd, signame(sig));
        w(fd, "\ncode:   "); wdec(fd, info ? info->si_code : 0);
        w(fd, "\naddr:   "); whex(fd, info ? (unsigned long long)(uintptr_t)info->si_addr : 0ULL);
        w(fd, "\n");
        if (info) describeAddress(fd, info->si_addr);

        w(fd, "\nJIT arena: ");
        w(fd, v3k_ios_jit_status());
        w(fd, "\n\nbacktrace:\n");
        void *frames[64];
        int n = backtrace(frames, 64);
        backtrace_symbols_fd(frames, n, fd);   // async-signal-safe by design
        w(fd, "\n(end)\n");
        fsync(fd);
        close(fd);
    }
    // Restore and re-raise so the OS still records its own crash log.
    for (int i = 0; i < kSignalCount; ++i)
        if (kSignals[i] == sig) { sigaction(sig, &g_old[i], NULL); break; }
    raise(sig);
}

static void uncaught(NSException *ex) {
    int fd = open(g_crashPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    w(fd, "Vita3K iOS crash report\n=======================\n\nuncaught Objective-C exception\n\nname:   ");
    w(fd, ex.name.UTF8String ?: "?");
    w(fd, "\nreason: "); w(fd, ex.reason.UTF8String ?: "?");
    w(fd, "\n\nJIT arena: "); w(fd, v3k_ios_jit_status());
    w(fd, "\n\nbacktrace:\n");
    for (NSString *line in ex.callStackSymbols) { w(fd, line.UTF8String ?: ""); w(fd, "\n"); }
    w(fd, "\n(end)\n");
    fsync(fd); close(fd);
}

void V3KInstallCrashReporter(NSString *directory) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    NSString *path = [directory stringByAppendingPathComponent:@"crash.log"];
    strncpy(g_crashPath, path.fileSystemRepresentation, sizeof g_crashPath - 1);

    // Run handlers on their own stack: a stack-overflow SIGSEGV cannot be
    // reported from the stack that overflowed.
    static char altstack[SIGSTKSZ * 2];
    stack_t ss = { .ss_sp = altstack, .ss_size = sizeof altstack, .ss_flags = 0 };
    sigaltstack(&ss, NULL);

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    for (int i = 0; i < kSignalCount; ++i) sigaction(kSignals[i], &sa, &g_old[i]);

    NSSetUncaughtExceptionHandler(&uncaught);
}

NSString *V3KCrashReportPath(void) {
    return [NSString stringWithUTF8String:g_crashPath];
}

NSString *V3KLastCrashReport(void) {
    if (!g_crashPath[0]) return nil;
    return [NSString stringWithContentsOfFile:V3KCrashReportPath()
                                     encoding:NSUTF8StringEncoding error:nil];
}

void V3KClearLastCrashReport(void) {
    if (g_crashPath[0]) [NSFileManager.defaultManager removeItemAtPath:V3KCrashReportPath() error:nil];
}
