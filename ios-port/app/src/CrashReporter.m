#import "CrashReporter.h"
#import "JitArena.h"
#import <execinfo.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <string.h>
#import <stdlib.h>
#import <pthread.h>
#import <sys/stat.h>
#import <mach-o/dyld_images.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>
#import <dlfcn.h>
#import <locale.h>

// Not public API, but present in libdyld on every Apple platform. dyld records
// exactly why it refused to load an image here, then aborts — and the message
// only ever goes to a console we cannot read on a sideloaded device. Reading it
// out turns "dyld aborted" into "dyld aborted because symbol X, expected in
// library Y, was missing".
// Resolved once at startup with dlsym rather than linked: it is absent from the
// SDK stub we link against, and dlsym is not async-signal-safe so it must not be
// called from the handler itself.
typedef const struct dyld_all_image_infos *(*v3k_aii_fn)(void);
static v3k_aii_fn g_dyld_aii = NULL;

// A signal handler may only call async-signal-safe functions, so everything
// below writes with write(2) and formats by hand. The path is resolved and
// cached at install time for the same reason.
#ifndef V3K_BUILD_ID
#define V3K_BUILD_ID "unstamped"
#endif

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
        w(fd, "Vita3K iOS crash report\n=======================\nbuild: ");
        w(fd, V3K_BUILD_ID);
        w(fd, "\n\nsignal: ");
        w(fd, signame(sig));
        w(fd, "\ncode:   "); wdec(fd, info ? info->si_code : 0);
        w(fd, "\naddr:   "); whex(fd, info ? (unsigned long long)(uintptr_t)info->si_addr : 0ULL);
        w(fd, "\n");
        if (info) describeAddress(fd, info->si_addr);

        w(fd, "\nJIT arena: ");
        w(fd, v3k_ios_jit_status());

        // If the loader aborted, name the library it could not load.
        //
        // dyld4 (iOS 15+) no longer fills in dyld_all_image_infos' error fields,
        // so asking it produced nothing. Determine it directly instead: walk THIS
        // binary's own LC_LOAD_DYLIB commands — the libraries it declares it
        // needs — and check each against the list of images actually loaded.
        // Whatever is required but absent is what dyld died on.
        // The required-library enumeration used to run here. It answered its
        // question conclusively — every library resolved [ok] across several
        // builds — and then became a liability: it is roughly 17,000 dyld
        // lookups performed from inside a signal handler, it faulted partway,
        // and it truncated the report before the crash annotation (dyld's own
        // statement of the cause) could be written. Removed so the useful part
        // always survives. Re-add it only if a missing library is suspected again.

        // dyld4 stores its fatal message in a __crash_info section rather than in
        // dyld_all_image_infos (which is why the previous probe printed nothing).
        // This is the same annotation the real crash reporter reads to produce
        // lines like "Symbol not found: _foo / Expected in: /path/lib". Scan every
        // loaded image for one carrying a message.
        w(fd, "\n\ncrash annotations:\n");
        {
            int found = 0;
            uint32_t n = _dyld_image_count();
            for (uint32_t i = 0; i < n; ++i) {
                const struct mach_header *h = _dyld_get_image_header(i);
                if (!h) continue;
                const char *secs[] = { "__crash_info", "__crash_info" };
                const char *segs[] = { "__DATA", "__DATA_DIRTY" };
                for (int k = 0; k < 2; ++k) {
                    unsigned long sz = 0;
                    uint8_t *p = getsectiondata((const struct mach_header_64 *)h, segs[k], secs[k], &sz);
                    if (!p || sz < 16) continue;
                    // struct crashreporter_annotations_t: version, then message ptr
                    uint64_t msgptr = 0;
                    memcpy(&msgptr, p + 8, sizeof msgptr);
                    if (!msgptr) continue;
                    const char *msg = (const char *)(uintptr_t)msgptr;
                    if (!msg || !*msg) continue;
                    const char *name = _dyld_get_image_name(i);
                    w(fd, "  "); w(fd, name ? name : "?"); w(fd, ":\n    ");
                    w(fd, msg); w(fd, "\n");
                    found = 1;
                }
            }
            if (!found) w(fd, "  (none recorded)\n");
        }

        const struct dyld_all_image_infos *aii = g_dyld_aii ? g_dyld_aii() : NULL;
        if (!g_dyld_aii) w(fd, "\ndyld info: _dyld_get_all_image_infos unavailable");
        else if (!aii)   w(fd, "\ndyld info: null");
        else if (!(aii->errorMessage && *aii->errorMessage) && !aii->errorKind)
            w(fd, "\ndyld info: no error recorded (expected on dyld4)");
        if (aii) {
            if (aii->errorMessage && *aii->errorMessage) {
                w(fd, "\n\ndyld error: "); w(fd, aii->errorMessage);
            }
            if (aii->errorKind) {
                w(fd, "\ndyld errorKind: "); wdec(fd, (long long)aii->errorKind);
                w(fd, aii->errorKind == 1 ? "  (missing symbol)"
                    : aii->errorKind == 2 ? "  (dylib missing)"
                    : aii->errorKind == 3 ? "  (dylib wrong version)"
                    : aii->errorKind == 4 ? "  (dylib wrong arch)" : "");
            }
            if (aii->errorSymbol && *aii->errorSymbol) {
                w(fd, "\ndyld missing symbol: "); w(fd, aii->errorSymbol);
            }
            if (aii->errorClientOfDylibPath && *aii->errorClientOfDylibPath) {
                w(fd, "\ndyld referenced from: "); w(fd, aii->errorClientOfDylibPath);
            }
            if (aii->errorTargetDylibPath && *aii->errorTargetDylibPath) {
                w(fd, "\ndyld expected in: "); w(fd, aii->errorTargetDylibPath);
            }
        }
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

// Install as early as the process allows.
//
// The reporter used to be installed from -application:didFinishLaunching..., i.e.
// inside main(). That is too late for a whole class of failure: a crashing C++
// static initializer, or a symbol dyld cannot bind, kills the process BEFORE
// main() runs — which presents as a black screen and an instant exit with no
// log written, and that is exactly what happened with an unresolved
// transform_dis_main. A constructor with an early priority runs before most
// other initializers, so those now leave a report behind too.
//
// The path is built with plain C rather than NSSearchPathForDirectoriesInDomains
// because this runs during static init, when as little as possible should be
// assumed about what is already initialised.
__attribute__((constructor(101))) static void v3k_install_crash_reporter_early(void) {
    const char *home = getenv("HOME");
    if (!home || !*home) return;
    char dir[900];
    snprintf(dir, sizeof dir, "%s/Documents/vita3k", home);
    mkdir(dir, 0755);                       // harmless if it already exists
    snprintf(g_crashPath, sizeof g_crashPath, "%s/crash.log", dir);

    setlocale(LC_ALL, "C");   // cheap insurance: a bad/missing locale is a classic
                              // "exception thrown in static initializer" on iOS
    g_dyld_aii = (v3k_aii_fn)dlsym(RTLD_DEFAULT, "_dyld_get_all_image_infos");

    static char altstack[SIGSTKSZ * 2];
    stack_t ss = { .ss_sp = altstack, .ss_size = sizeof altstack, .ss_flags = 0 };
    sigaltstack(&ss, NULL);

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    for (int i = 0; i < kSignalCount; ++i) sigaction(kSignals[i], &sa, &g_old[i]);
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

// Exposed for CxxTerminate.mm, which cannot include this file's ObjC headers.
const char *v3k_crash_log_path(void) { return g_crashPath; }

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
