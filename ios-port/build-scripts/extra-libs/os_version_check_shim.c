// os_version_check_shim.c — minimal reimplementation of the two compiler-rt
// darwin builtins that back Objective-C's `@available(...)` checks:
//   __isOSVersionAtLeast / __isPlatformVersionAtLeast
//
// WHY THIS EXISTS: this cross-toolchain (LLVM 18 on Linux, targeting
// arm64-apple-ios) has no Apple libclang_rt.ios.a to supply these symbols —
// Xcode normally autolinks that archive on every Darwin link. Any source
// that uses `@available(...)` (MoltenVK's newer-OS optional-feature checks,
// for one) is left with an undefined reference to these two functions.
//
// This is a deliberately-trimmed port of compiler-rt's
// compiler-rt/lib/builtins/os_version_check.c: it keeps only the modern path
// (call the real dyld-exported `_availability_version_check`), and drops
// upstream's Info.plist/CoreFoundation fallback for pre-2018 OS versions
// that predate that dyld entry point — irrelevant for any iOS device new
// enough to run this emulator (StikDebug/JIT26 alone implies iOS 17+).
#if defined(__APPLE__)

#include <TargetConditionals.h>
#include <stdint.h>
#include <stdbool.h>
#include <dispatch/dispatch.h>

typedef uint32_t dyld_platform_t;
typedef struct {
    dyld_platform_t platform;
    uint32_t version;
} dyld_build_version_t;

// Real implementation lives in libSystem on-device since iOS 12 / macOS 10.14.
extern __attribute__((weak_import))
bool _availability_version_check(uint32_t count, dyld_build_version_t versions[]);

static int32_t GlobalMajor, GlobalMinor, GlobalSubminor;
static dispatch_once_t DispatchOnceCounter;

static void initialize_fallback_version(void *unused) {
    (void)unused;
    // Fallback path (no _availability_version_check): treat as "not met".
    // Every OS this bridge ships for has _availability_version_check, so this
    // branch should never actually execute; it exists only so the function
    // has *a* defined behaviour instead of reading uninitialized globals.
    GlobalMajor = 0;
    GlobalMinor = 0;
    GlobalSubminor = 0;
}

int32_t __isOSVersionAtLeast(int32_t Major, int32_t Minor, int32_t Subminor) {
    dispatch_once_f(&DispatchOnceCounter, NULL, initialize_fallback_version);
    if (Major < GlobalMajor) return 1;
    if (Major > GlobalMajor) return 0;
    if (Minor < GlobalMinor) return 1;
    if (Minor > GlobalMinor) return 0;
    return Subminor <= GlobalSubminor;
}

static inline uint32_t construct_version(uint32_t Major, uint32_t Minor, uint32_t Subminor) {
    return ((Major & 0xffff) << 16) | ((Minor & 0xff) << 8) | (Subminor & 0xff);
}

int32_t __isPlatformVersionAtLeast(uint32_t Platform, uint32_t Major,
                                    uint32_t Minor, uint32_t Subminor) {
    if (!_availability_version_check)
        return __isOSVersionAtLeast((int32_t)Major, (int32_t)Minor, (int32_t)Subminor);

    dyld_build_version_t versions[] = { { Platform, construct_version(Major, Minor, Subminor) } };
    return _availability_version_check(1, versions);
}

#endif // __APPLE__
