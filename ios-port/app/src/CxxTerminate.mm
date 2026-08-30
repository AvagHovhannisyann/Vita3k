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
__attribute__((constructor(102))) static void v3k_install_terminate(void) {
    g_prev = std::set_terminate(v3k_terminate);
}
