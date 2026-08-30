// CxxTerminate.mm — name the C++ exception that kills us during load.
//
// dyld reported the cause exactly: "c++ exception thrown in static initializer".
// A global object's constructor throws while the app is still being loaded, the
// exception escapes into dyld, and dyld aborts. No application frame appears in
// the backtrace, so the ordinary signal handler cannot say which one.
//
// std::terminate runs at the moment the exception escapes, with the throwing
// frames still on the stack. From there the exception's type, its what() message
// and a backtrace through the offending initializer are all still readable.
// Compiled as Objective-C++ because CrashReporter.m is plain Objective-C.
#include <exception>
#include <typeinfo>
#include <cxxabi.h>
#include <execinfo.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <stdio.h>
#include <sys/mman.h>

#ifndef V3K_BUILD_ID
#define V3K_BUILD_ID "unstamped"
#endif

extern "C" const char *v3k_crash_log_path(void);

// Non-zero until main() starts. Any C++ throw while this is set happened during
// image load — exactly the window dyld complained about.
extern "C" { int v3k_in_static_init = 1; }

static std::terminate_handler g_prev = nullptr;

static void w(int fd, const char *s) { if (s) write(fd, s, strlen(s)); }

static void v3k_terminate() {
    const char *path = v3k_crash_log_path();
    int fd = (path && *path) ? open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644) : -1;
    if (fd >= 0) {
        w(fd, "Vita3K iOS crash report\n=======================\nbuild: " V3K_BUILD_ID "\n\n");
        w(fd, "cause: uncaught C++ exception (std::terminate)\n"
              "  dyld reports this as \"c++ exception thrown in static initializer\"\n"
              "  when it happens while the app is still loading.\n\n");

        const std::type_info *ti = abi::__cxa_current_exception_type();
        w(fd, "exception type: ");
        if (ti) {
            int st = 0;
            char *dem = abi::__cxa_demangle(ti->name(), nullptr, nullptr, &st);
            w(fd, (st == 0 && dem) ? dem : ti->name());
            if (dem) free(dem);
        } else {
            w(fd, "(none recorded)");
        }
        w(fd, "\nmessage: ");
        const char *msg = nullptr;
        try {
            std::exception_ptr e = std::current_exception();
            if (e) std::rethrow_exception(e);
        } catch (const std::exception &ex) {
            msg = ex.what();
        } catch (...) {
            msg = "(exception not derived from std::exception)";
        }
        w(fd, msg ? msg : "(none)");

        w(fd, "\n\nbacktrace — the throwing initializer is in here:\n");
        void *frames[96];
        int n = backtrace(frames, 96);
        backtrace_symbols_fd(frames, n, fd);
        w(fd, "\n(end)\n");
        fsync(fd);
        close(fd);
    }
    if (g_prev) g_prev();
    abort();
}

// Belt and braces: std::terminate may never run, because dyld can catch the
// escaping exception itself (that is how it produces its own message). So also
// intercept the throw at its source. Defining __cxa_throw in the executable
// means every throw from the statically linked C++ in this binary comes through
// here first, and only throws before main() are reported — the emulator throws
// and catches legitimately once it is running, and those must be left alone.
extern "C" void __cxa_throw(void *thrown, std::type_info *tinfo, void (*dest)(void *)) {
    if (v3k_in_static_init) {
        v3k_in_static_init = 0;               // report the FIRST one only
        const char *path = v3k_crash_log_path();
        int fd = (path && *path) ? open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644) : -1;
        if (fd >= 0) {
            w(fd, "Vita3K iOS crash report\n=======================\nbuild: " V3K_BUILD_ID "\n\n");
            w(fd, "cause: C++ exception thrown during static initialization\n"
                  "  (caught at the throw itself, so the initializer is on the stack below)\n\n");
            w(fd, "exception type: ");
            if (tinfo) {
                int st = 0;
                char *dem = abi::__cxa_demangle(tinfo->name(), nullptr, nullptr, &st);
                w(fd, (st == 0 && dem) ? dem : tinfo->name());
                if (dem) free(dem);
            } else w(fd, "(unknown)");
            w(fd, "\nmessage: ");
            // The object is not yet thrown, so read what() straight off it.
            const char *msg = nullptr;
            if (thrown && tinfo) {
                try { msg = static_cast<std::exception *>(thrown)->what(); } catch (...) { msg = nullptr; }
            }
            w(fd, msg ? msg : "(unavailable)");
            w(fd, "\n\nbacktrace — the throwing initializer is in here:\n");
            void *frames[96];
            int n = backtrace(frames, 96);
            backtrace_symbols_fd(frames, n, fd);
            w(fd, "\n(end)\n");
            fsync(fd);
            close(fd);
        }
    }
    typedef void (*throw_fn)(void *, std::type_info *, void (*)(void *));
    static throw_fn real = nullptr;
    if (!real) real = (throw_fn)dlsym(RTLD_NEXT, "__cxa_throw");
    if (real) real(thrown, tinfo, dest);
    abort();                                   // unreachable in practice
}

// 102: after CrashReporter's constructor (101) has set the log path, and still
// ahead of the ordinary unprioritised initializers, one of which is the thrower.
__attribute__((constructor(102))) void v3k_install_terminate(void) {
    g_prev = std::set_terminate(v3k_terminate);
}


// ---------------------------------------------------------------------------
// Last resort, and the one that cannot be dodged.
//
// Neither previous net fired: dyld catches the escaping exception itself (that
// is how it produces "c++ exception thrown in static initializer"), so
// std::terminate never runs; and the throw originates inside a system dylib, so
// the __cxa_throw defined above never sees it either.
//
// So stop trying to observe dyld and do the work instead. This constructor has
// priority 103, which means the only initializers that have run so far are our
// own (101 and 102) — every other entry in __mod_init_func is still pending.
// Walk that list and call each one inside a try/catch. Whichever throws IS the
// culprit, and here its address, its symbol and the exception are all readable.
//
// This is a diagnostic build: it reports and aborts rather than letting dyld run
// the list a second time. The app cannot start today anyway, so naming the bug
// is worth more than a launch that was never going to happen.
// ---------------------------------------------------------------------------
void v3k_install_terminate(void);

// Replaces an initializer once it has run, so dyld's second pass is inert.
extern "C" void v3k_noop_initializer(void) {}

__attribute__((constructor(103))) static void v3k_probe_initializers(void) {
    const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!mh) return;
    unsigned long size = 0;
    uint8_t *sect = getsectiondata(mh, "__DATA_CONST", "__mod_init_func", &size);
    if (!sect) sect = getsectiondata(mh, "__DATA", "__mod_init_func", &size);
    if (!sect || size < sizeof(uintptr_t)) return;

    uintptr_t *fns = (uintptr_t *)sect;
    size_t n = size / sizeof(uintptr_t);

    const char *path = v3k_crash_log_path();
    typedef void (*initfn)(void);

    // Run each initializer EXACTLY once.
    //
    // B8 established that none of them throws on a clean run — the probe walked
    // all of them without catching anything. What broke B8 was the second pass:
    // dyld resumes this list after we return and runs every entry AGAIN, and
    // re-entering an initializer that takes a lock or a std::once_flag either
    // deadlocks (black screen, no crash) or trips an assert (abort() called).
    //
    // So neutralise each entry as it completes: overwrite it with a no-op, and
    // dyld's pass becomes 323 calls that do nothing. __DATA_CONST is not yet
    // read-only this early, but mprotect it anyway rather than assume.
    uintptr_t pageStart = (uintptr_t)sect & ~(uintptr_t)(getpagesize() - 1);
    size_t protLen = (uintptr_t)sect + size - pageStart;
    bool writable = (mprotect((void *)pageStart, protLen, PROT_READ | PROT_WRITE) == 0);

    for (size_t i = 0; i < n; ++i) {
        initfn f = (initfn)fns[i];
        if (!f) continue;
        // Skip our own three constructors; they have already run.
        if ((void *)f == (void *)v3k_probe_initializers) continue;
        if ((void *)f == (void *)v3k_install_terminate) continue;

        const char *extype = nullptr, *exmsg = nullptr;
        bool threw = false;
        try {
            f();
            if (writable) fns[i] = (uintptr_t)&v3k_noop_initializer;   // dyld must not re-run it
        } catch (const std::exception &e) {
            threw = true; exmsg = e.what();
            const std::type_info *ti = abi::__cxa_current_exception_type();
            extype = ti ? ti->name() : "unknown";
        } catch (...) {
            threw = true; extype = "(non-std exception)"; exmsg = "";
        }
        if (!threw) continue;

        int fd = (path && *path) ? open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644) : -1;
        if (fd >= 0) {
            w(fd, "Vita3K iOS crash report\n=======================\nbuild: " V3K_BUILD_ID "\n\n");
            w(fd, "FOUND THE THROWING STATIC INITIALIZER\n\n");
            char buf[512];
            Dl_info info;
            memset(&info, 0, sizeof info);
            int ok = dladdr((void *)f, &info);
            snprintf(buf, sizeof buf, "initializer index: %zu of %zu\n", i, n); w(fd, buf);
            snprintf(buf, sizeof buf, "function address:  %p\n", (void *)f); w(fd, buf);
            snprintf(buf, sizeof buf, "image slide offset: 0x%llx\n",
                     (unsigned long long)((uintptr_t)f - (uintptr_t)mh)); w(fd, buf);
            if (ok && info.dli_sname) {
                int st = 0;
                char *dem = abi::__cxa_demangle(info.dli_sname, nullptr, nullptr, &st);
                w(fd, "symbol:            "); w(fd, (st == 0 && dem) ? dem : info.dli_sname); w(fd, "\n");
                if (dem) free(dem);
            } else {
                w(fd, "symbol:            (not resolvable)\n");
            }
            if (ok && info.dli_fname) { w(fd, "image:             "); w(fd, info.dli_fname); w(fd, "\n"); }

            w(fd, "\nexception type:    ");
            if (extype) {
                int st = 0;
                char *dem = abi::__cxa_demangle(extype, nullptr, nullptr, &st);
                w(fd, (st == 0 && dem) ? dem : extype);
                if (dem) free(dem);
            } else w(fd, "(unknown)");
            w(fd, "\nmessage:           "); w(fd, (exmsg && *exmsg) ? exmsg : "(none)");
            w(fd, "\n\n(end)\n");
            fsync(fd);
            close(fd);
        }
        abort();   // diagnostic build: stop here rather than let dyld re-run the list
    }
}
