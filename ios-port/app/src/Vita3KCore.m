// Vita3KCore.m — stub bridge implementation. Compiles and runs today; the
// native Vita3K core is linked in behind the same interface later.
#import "Vita3KCore.h"
#import "JitArena.h"
#import "Sfo.h"
#import "Vpk.h"
#import <mach/mach.h>
#import <sys/sysctl.h>

// mach_vm.h is marked "unsupported" in the public iOS SDK, but the symbols are
// exported by libSystem at runtime. Declare the few we use.
typedef unsigned long long mach_vm_address_t;
typedef unsigned long long mach_vm_size_t;
typedef unsigned long long mach_vm_offset_t;
extern kern_return_t mach_vm_remap(vm_map_t, mach_vm_address_t *, mach_vm_size_t, mach_vm_offset_t,
                                   int, vm_map_t, mach_vm_address_t, boolean_t,
                                   vm_prot_t *, vm_prot_t *, vm_inherit_t);
extern kern_return_t mach_vm_protect(vm_map_t, mach_vm_address_t, mach_vm_size_t, boolean_t, vm_prot_t);
extern kern_return_t mach_vm_deallocate(vm_map_t, mach_vm_address_t, mach_vm_size_t);
extern kern_return_t mach_vm_allocate(vm_map_t, mach_vm_address_t *, mach_vm_size_t, int);
#import <sys/mman.h>
#import <errno.h>
#import <libkern/OSCacheControl.h>
#import <setjmp.h>
#import <signal.h>

// ---- Native core entry points. Defined by CoreStub.m in a UI-preview build;
// the real Vita3K core library provides the strong versions (and makes
// vita3k_ios_present() return 1) when it is linked in. ----
extern int  vita3k_ios_present(void);
extern const char *vita3k_ios_version(void);
extern int  vita3k_ios_boot(const char *title_id, void *metal_layer);
extern void vita3k_ios_send_buttons(uint32_t mask);
extern void vita3k_ios_shutdown(void);

// The cross-toolchain doesn't ship compiler-rt's iOS builtins, so provide the
// availability helper that `@available(...)` lowers to.
int32_t __isPlatformVersionAtLeast(uint32_t platform, uint32_t major, uint32_t minor, uint32_t subminor) {
    (void)platform;
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    if (v.majorVersion != (NSInteger)major) return v.majorVersion > (NSInteger)major;
    if (v.minorVersion != (NSInteger)minor) return v.minorVersion > (NSInteger)minor;
    return v.patchVersion >= (NSInteger)subminor;
}

// ---- JIT26 brk #0xf00d handshake (StikDebug iOS-26 protocol) ----
__attribute__((noinline, naked)) static void *JIT26PrepareRegion(void *addr, unsigned long len) {
    __asm__ volatile("mov x16, #1\n\t brk #0xf00d\n\t ret\n\t");
}
__attribute__((noinline, naked)) static void JIT26Detach(void) {
    __asm__ volatile("mov x16, #0\n\t brk #0xf00d\n\t ret\n\t");
}
// Older StikDebug scripts answered a different immediate; kept as a fallback.
__attribute__((noinline, naked)) static void *JITLegacyPrepare(void *addr, unsigned long len) {
    __asm__ volatile("mov x16, #1\n\t brk #0x69\n\t ret\n\t");
}
extern int csops(pid_t pid, unsigned int ops, void *buf, size_t size);
#define CS_OPS_STATUS 0
#define CS_DEBUGGED   0x10000000u

static sigjmp_buf g_jb;
static volatile int g_lastsig;   // signal that aborted the last guarded probe
static void v3k_sig(int s) { g_lastsig = s; siglongjmp(g_jb, 1); }

// The brk #0xf00d handshake can HANG if no debugger script answers it (and a
// bare brk with nothing attached would kill the process), so run it on a worker
// thread under a SIGTRAP guard and give up after `seconds`. Returns the prepared
// RX region, or NULL (with *why set) on fault/timeout.
static void *prepare_region_guarded(unsigned long len, double seconds, const char **why, BOOL legacy) {
    __block void *out = NULL;
    __block int sig = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        struct sigaction sa = {0}, ot = {0};
        sa.sa_handler = v3k_sig;
        sigaction(SIGTRAP, &sa, &ot);
        g_lastsig = 0;
        if (sigsetjmp(g_jb, 1) == 0) {
            out = legacy ? JITLegacyPrepare(NULL, len) : JIT26PrepareRegion(NULL, len);
        } else {
            out = NULL; sig = g_lastsig;
        }
        sigaction(SIGTRAP, &ot, NULL);
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
                                (int64_t)(seconds * NSEC_PER_SEC))) != 0) {
        if (why) *why = "timed out (no debugger script answered)";
        return NULL;                       // worker may still be parked in the brk
    }
    if (!out && why) *why = sig ? "faulted" : "declined";
    return out;
}

NSNotificationName const V3KJITStateDidChangeNotification = @"V3KJITStateDidChange";

// Whatever we get here is ALL the executable memory this process will ever have,
// so ask for the maximum that is useful and let the core halve the request if
// the debugger declines it. 128 MB is not one code cache: Vita3K builds a
// dynarmic JIT per guest thread, and the core sub-allocates a fixed slot per
// thread out of this one arena. dynarmic's intra-cache branches are B/BL
// (+-128 MB), which is the ceiling that makes 128 MB the right ask.
static const unsigned long kV3KArenaBytes = 128ul << 20;

@implementation V3KTitle @end

@interface Vita3KCore () { V3KJITState _jit; int _arenaImpl; }  // _arenaImpl: 0 unknown, 1 real, -1 stub
- (BOOL)legacyProbeWithError:(NSError **)error;
@end
@interface Vita3KCore ()
@end

@implementation Vita3KCore

+ (instancetype)shared {
    static Vita3KCore *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [Vita3KCore new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _jit = V3KJITUnknown;
        [self ensureDataTree];
    }
    return self;
}

- (BOOL)coreLinked { return vita3k_ios_present() != 0; }

- (NSString *)coreVersion {
    const char *v = vita3k_ios_version();
    return v ? [NSString stringWithUTF8String:v] : @"native core not linked yet";
}

- (NSString *)dataRoot {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"vita3k"];
}

- (void)ensureDataTree {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *sub in @[@"ux0/app", @"ux0/user", @"ux0/pspemu", @"vs0", @"import"]) {
        [fm createDirectoryAtPath:[self.dataRoot stringByAppendingPathComponent:sub]
      withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

- (V3KJITState)jitState { return _jit; }

- (NSString *)statusLine {
    NSString *core = self.coreLinked ? @"core linked" : @"UI preview (core not linked)";
    NSString *jit;
    if (v3k_ios_jit_ready()) {
        unsigned long sz = v3k_ios_jit_size(), used = v3k_ios_jit_used();
        jit = [NSString stringWithFormat:@"JIT arena %lu MB (%lu MB used)", sz >> 20, used >> 20];
    } else {
        jit = _jit == V3KJITReady ? @"JIT ready"
            : _jit == V3KJITUnavailable ? @"JIT off — enable in StikDebug"
            : _jit == V3KJITFailed ? @"JIT failed" : @"JIT not prepared";
    }
    return [NSString stringWithFormat:@"%@  ·  %@", core, jit];
}

// ---------------------------------------------------------------------------
// The single pre-prepared executable arena.
//
// The JIT26 handshake is ONE-SHOT per StikDebug attach: regions can only be
// blessed while the debugger is attached, and JIT26Detach() ends that window
// for good. So we take one big arena here, up front, and the recompiler
// sub-allocates every block of code out of it for the rest of the session.
// Running the handshake twice is not a retry — it is a guaranteed failure —
// which is why every entry point below is idempotent and checks readiness
// before touching the brk.
// ---------------------------------------------------------------------------

- (BOOL)jitArenaReady { return v3k_ios_jit_ready() != 0; }

- (BOOL)jitArenaImplemented {
    if (_arenaImpl == 0) return YES;   // not probed yet — assume the real core
    return _arenaImpl > 0;
}

- (NSString *)jitArenaStatus {
    if (_arenaImpl < 0) return @"no arena in this build (UI-preview mode)";
    const char *st = v3k_ios_jit_status();
    return st ? [NSString stringWithUTF8String:st] : @"unknown";
}

- (void)postJITChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:V3KJITStateDidChangeNotification object:self];
    });
}

- (void)prepareJITWithCompletion:(void (^)(BOOL, NSError *))completion {
    void (^finish)(BOOL, NSError *) = ^(BOOL ok, NSError *e) {
        [self postJITChanged];
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, e); });
    };

    // Already up. Never re-run the handshake — it cannot succeed a second time.
    if (v3k_ios_jit_ready()) { _jit = V3KJITReady; finish(YES, nil); return; }
    if (_jit == V3KJITReady && _arenaImpl < 0) { finish(YES, nil); return; }  // preview probe already passed

    unsigned int flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof flags) != 0 || !(flags & CS_DEBUGGED)) {
        _jit = V3KJITUnavailable;
        finish(NO, [NSError errorWithDomain:@"Vita3K" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"Not debugged. In StikDebug, enable JIT for Vita3K with the script "
                                        "universal.js attached, then come back — the app prepares its memory automatically."}]);
        return;
    }

    // Do the work off the main thread: the brk can stall for seconds, and the
    // core guards it with its own 8 s timeout. Our outer wait is the backstop.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block int rc = V3K_JIT_NO_IMPL;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            rc = v3k_ios_jit_init(kV3KArenaBytes);
            dispatch_semaphore_signal(done);
        });
        BOOL timedOut = dispatch_semaphore_wait(done,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC))) != 0;

        if (timedOut) {
            self->_jit = V3KJITFailed;
            finish(NO, [NSError errorWithDomain:@"Vita3K" code:3 userInfo:@{
                NSLocalizedDescriptionKey: @"The debugger never answered the JIT handshake. Make sure StikDebug is "
                                            "still running and that universal.js is attached to Vita3K, then relaunch."}]);
            return;
        }

        if (rc == V3K_JIT_NO_IMPL) {
            // No arena compiled in (UI-preview build): fall back to the small
            // standalone probe so the diagnostics screen still means something.
            self->_arenaImpl = -1;
            NSError *e = nil;
            BOOL ok = [self legacyProbeWithError:&e];
            finish(ok, ok ? nil : e);
            return;
        }

        self->_arenaImpl = 1;
        BOOL ok = (rc == 0) && v3k_ios_jit_ready();
        self->_jit = ok ? V3KJITReady : V3KJITFailed;
        finish(ok, ok ? nil : [NSError errorWithDomain:@"Vita3K" code:4 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:
                @"Could not reserve the executable arena: %@. Re-enable JIT in StikDebug (with universal.js "
                 "attached) and relaunch Vita3K — the handshake only works once per attach.",
                self.jitArenaStatus]}]);
    });
}

- (BOOL)prepareJITWithError:(NSError **)error {
    if (v3k_ios_jit_ready()) { _jit = V3KJITReady; return YES; }
    __block BOOL ok = NO; __block NSError *err = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [self prepareJITWithCompletion:^(BOOL o, NSError *e) { ok = o; err = e; dispatch_semaphore_signal(done); }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC))) != 0) {
        if (error) *error = [NSError errorWithDomain:@"Vita3K" code:5 userInfo:@{
            NSLocalizedDescriptionKey: @"Timed out preparing JIT memory."}];
        return NO;
    }
    if (!ok && error) *error = err;
    return ok;
}

// The original standalone 1 MB probe. Only used when no arena implementation is
// linked (UI-preview builds) — it burns the one-shot attach, so it must never
// run in a build that has the real core.
- (BOOL)legacyProbeWithError:(NSError **)error {
    unsigned int flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof flags) != 0 || !(flags & CS_DEBUGGED)) {
        _jit = V3KJITUnavailable;
        if (error) *error = [NSError errorWithDomain:@"Vita3K" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"Not debugged. Enable JIT for Vita3K in StikDebug (keep it running), then try again."}];
        return NO;
    }
    const unsigned long len = 1u << 20;   // 1 MB starter arena
    struct sigaction sa = {0}, ob = {0}, ot = {0}, os = {0}, oi = {0};
    sa.sa_handler = v3k_sig;
    sigaction(SIGTRAP, &sa, &ot); sigaction(SIGBUS, &sa, &ob);
    sigaction(SIGSEGV, &sa, &os); sigaction(SIGILL, &sa, &oi);

    BOOL ok = NO;
    void *rx = NULL;
    if (sigsetjmp(g_jb, 1) == 0) { rx = JIT26PrepareRegion(NULL, len); }
    else { rx = NULL; }
    if (rx && rx != (void *)-1) {
        mach_vm_address_t rw = 0; vm_prot_t cur = 0, mx = 0;
        if (mach_vm_remap(mach_task_self(), &rw, len, 0, VM_FLAGS_ANYWHERE,
                          mach_task_self(), (mach_vm_address_t)(uintptr_t)rx, false,
                          &cur, &mx, VM_INHERIT_NONE) == KERN_SUCCESS) {
            mach_vm_protect(mach_task_self(), rw, len, false, VM_PROT_READ | VM_PROT_WRITE);
            if (sigsetjmp(g_jb, 1) == 0) { JIT26Detach(); }
            // write a tiny probe (mov w0,#42; ret) via RW, execute via RX
            uint32_t code[2] = {0x52800540u, 0xD65F03C0u};
            memcpy((void *)(uintptr_t)rw, code, sizeof code);
            sys_icache_invalidate(rx, sizeof code);
            if (sigsetjmp(g_jb, 1) == 0) {
                int (*fn)(void) = (int (*)(void))rx;
                ok = (fn() == 42);
            }
            mach_vm_deallocate(mach_task_self(), rw, len);
        }
    }
    sigaction(SIGTRAP, &ot, NULL); sigaction(SIGBUS, &ob, NULL);
    sigaction(SIGSEGV, &os, NULL); sigaction(SIGILL, &oi, NULL);

    _jit = ok ? V3KJITReady : V3KJITFailed;
    if (!ok && error) *error = [NSError errorWithDomain:@"Vita3K" code:2 userInfo:@{
        NSLocalizedDescriptionKey: @"The JIT26 handshake did not yield executable memory. Update StikDebug, re-enable JIT, and retry."}];
    return ok;
}

static NSString *regionForTitleId(NSString *tid) {
    if (tid.length < 4) return @"—";
    NSString *p = [tid substringToIndex:4];
    if ([p isEqualToString:@"PCSF"] || [p isEqualToString:@"PCSA"]) return @"US";
    if ([p isEqualToString:@"PCSB"] || [p isEqualToString:@"PCSC"]) return @"EU";
    if ([p isEqualToString:@"PCSD"] || [p isEqualToString:@"PCSG"]) return @"JP";
    if ([p isEqualToString:@"PCSE"] || [p isEqualToString:@"PCSH"]) return @"US";
    return @"—";
}

static unsigned long long dirSize(NSString *path) {
    NSFileManager *fm = NSFileManager.defaultManager;
    unsigned long long total = 0;
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:path];
    for (NSString *sub in e) {
        NSDictionary *a = e.fileAttributes;
        if ([a.fileType isEqualToString:NSFileTypeRegular]) total += a.fileSize;
    }
    return total;
}

- (V3KTitle *)titleFromAppDir:(NSString *)base titleId:(NSString *)tid {
    NSFileManager *fm = NSFileManager.defaultManager;
    V3KTitle *t = [V3KTitle new];
    t.titleId = tid;
    t.appPath = base;
    t.region = regionForTitleId(tid);
    t.name = tid;
    t.category = @"gd";
    NSString *sfo = [base stringByAppendingPathComponent:@"sce_sys/param.sfo"];
    NSDictionary *p = V3KParseSfoAtPath(sfo);
    if (p) {
        if ([p[@"TITLE"] isKindOfClass:NSString.class]) t.name = p[@"TITLE"];
        if ([p[@"APP_VER"] isKindOfClass:NSString.class]) t.version = p[@"APP_VER"];
        if ([p[@"CATEGORY"] isKindOfClass:NSString.class]) t.category = p[@"CATEGORY"];
        if ([p[@"TITLE_ID"] isKindOfClass:NSString.class]) t.titleId = p[@"TITLE_ID"];
    }
    NSString *icon = [base stringByAppendingPathComponent:@"sce_sys/icon0.png"];
    if ([fm fileExistsAtPath:icon]) t.iconPath = icon;
    t.sizeBytes = dirSize(base);
    return t;
}

- (NSArray<V3KTitle *> *)installedTitles {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *appDir = [self.dataRoot stringByAppendingPathComponent:@"ux0/app"];
    NSMutableArray<V3KTitle *> *out = [NSMutableArray array];
    for (NSString *tid in [fm contentsOfDirectoryAtPath:appDir error:nil] ?: @[]) {
        NSString *base = [appDir stringByAppendingPathComponent:tid];
        BOOL dir = NO;
        if (![fm fileExistsAtPath:base isDirectory:&dir] || !dir || [tid hasPrefix:@"."]) continue;
        [out addObject:[self titleFromAppDir:base titleId:tid]];
    }
    [out sortUsingComparator:^NSComparisonResult(V3KTitle *a, V3KTitle *b) {
        return [a.name caseInsensitiveCompare:b.name];
    }];
    return out;
}

- (NSDictionary<NSString *, id> *)inspectPackageAtURL:(NSURL *)url {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *sfo = V3KZipReadEntry(url.path, @"sce_sys/param.sfo");
    if (scoped) [url stopAccessingSecurityScopedResource];
    return sfo ? V3KParseSfoData(sfo) : nil;
}

- (BOOL)importPackageAtURL:(NSURL *)url error:(NSError **)error {
    __block BOOL ok = NO; __block NSError *e = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [self installPackageAtURL:url progress:nil completion:^(BOOL success, NSString *tid, NSError *err) {
        ok = success; e = err; dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (!ok && error) *error = e;
    return ok;
}

- (void)installPackageAtURL:(NSURL *)url
                   progress:(void (^)(double))progress
                 completion:(void (^)(BOOL, NSString *, NSError *))completion {
    NSString *root = self.dataRoot;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL scoped = [url startAccessingSecurityScopedResource];
        // Determine target titleId from the VPK's own param.sfo.
        NSString *titleId = nil;
        NSData *sfo = V3KZipReadEntry(url.path, @"sce_sys/param.sfo");
        NSDictionary *p = sfo ? V3KParseSfoData(sfo) : nil;
        if ([p[@"TITLE_ID"] isKindOfClass:NSString.class]) titleId = p[@"TITLE_ID"];
        if (!titleId) titleId = url.lastPathComponent.stringByDeletingPathExtension;

        NSString *dest = [[root stringByAppendingPathComponent:@"ux0/app"] stringByAppendingPathComponent:titleId];
        [NSFileManager.defaultManager removeItemAtPath:dest error:nil];
        NSError *err = nil;
        BOOL ok = V3KZipExtractAll(url.path, dest, progress, &err);
        if (scoped) [url stopAccessingSecurityScopedResource];
        NSString *tid = titleId;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, ok ? tid : nil, err); });
    });
}

- (BOOL)importFirmwareAtURL:(NSURL *)url error:(NSError **)error {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSString *dst = [[self.dataRoot stringByAppendingPathComponent:@"import"]
                     stringByAppendingPathComponent:url.lastPathComponent];
    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
    BOOL ok = [NSFileManager.defaultManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:error];
    if (scoped) [url stopAccessingSecurityScopedResource];
    return ok;   // The core installs the staged PUP into vs0 on next boot.
}

- (NSArray<NSString *> *)saveDataPathsForTitle:(V3KTitle *)title {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *saveRoot = [self.dataRoot stringByAppendingPathComponent:@"ux0/user/00/savedata"];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *e in [fm contentsOfDirectoryAtPath:saveRoot error:nil] ?: @[]) {
        if ([e hasPrefix:title.titleId]) [out addObject:[saveRoot stringByAppendingPathComponent:e]];
    }
    return out;
}

- (BOOL)firmwareInstalled {
    NSString *vs0 = [self.dataRoot stringByAppendingPathComponent:@"vs0/sys"];
    return [NSFileManager.defaultManager fileExistsAtPath:vs0];
}

- (BOOL)deleteTitle:(V3KTitle *)title error:(NSError **)error {
    NSString *base = [[self.dataRoot stringByAppendingPathComponent:@"ux0/app"]
                      stringByAppendingPathComponent:title.titleId];
    return [NSFileManager.defaultManager removeItemAtPath:base error:error];
}

- (void)bootTitleId:(NSString *)titleId inLayer:(CALayer *)layer {
    // Guard rail. The recompiler will ask for executable memory the moment the
    // guest executes its first instruction, and on iOS that memory can only
    // come from an arena blessed BEFORE the debugger detached. Booting without
    // one does not degrade gracefully — it faults. Refuse instead.
    if (self.coreLinked && _arenaImpl >= 0 && !v3k_ios_jit_ready()) {
        NSLog(@"[Vita3K] refusing to boot %@: JIT arena not prepared (%s)",
              titleId, v3k_ios_jit_status());
        return;
    }
    vita3k_ios_boot(titleId.UTF8String, (__bridge void *)layer);
}
- (void)sendButtons:(uint32_t)mask { vita3k_ios_send_buttons(mask); }
- (void)sendLeftStickX:(float)x y:(float)y {}
- (void)sendRightStickX:(float)x y:(float)y {}
- (void)sendTouchFront:(CGPoint)p down:(BOOL)down {}
- (void)shutdown { vita3k_ios_shutdown(); }


#pragma mark - JIT diagnostics

- (BOOL)processIsDebugged {
    unsigned int f = 0;
    if (csops(getpid(), CS_OPS_STATUS, &f, sizeof f) != 0) return NO;
    return (f & CS_DEBUGGED) != 0;
}

- (NSString *)codeSigningFlagsDescription {
    unsigned int f = 0;
    if (csops(getpid(), CS_OPS_STATUS, &f, sizeof f) != 0) return @"csops() unavailable";
    NSMutableArray *bits = [NSMutableArray array];
    if (f & 0x00000001u) [bits addObject:@"valid"];
    if (f & 0x00000002u) [bits addObject:@"adhoc"];
    if (f & 0x00000004u) [bits addObject:@"get-task-allow"];
    if (f & 0x00001000u) [bits addObject:@"enforcement"];
    if (f & 0x00002000u) [bits addObject:@"require-LV"];
    if (f & 0x02000000u) [bits addObject:@"dyld-platform"];
    if (f & 0x10000000u) [bits addObject:@"DEBUGGED"];
    if (f & 0x20000000u) [bits addObject:@"signed"];
    return [NSString stringWithFormat:@"0x%08x [%@]", f, [bits componentsJoinedByString:@" "]];
}

// bti c ; mov w0,#42 ; ret   (bti decodes as NOP on pre-ARMv8.5 cores)
static const uint32_t kProbeCode[3] = { 0xD503245Fu, 0x52800540u, 0xD65F03C0u };

static const char *signame_(int s) {
    return s == SIGILL ? "SIGILL" : s == SIGBUS ? "SIGBUS" : s == SIGSEGV ? "SIGSEGV"
         : s == SIGTRAP ? "SIGTRAP" : "fault";
}

// Execute `mem` under a fault guard. Returns 1 on the expected result, 0 on a
// wrong value, -1 if it faulted (signal name written to sigOut).
static int guarded_exec(void *mem, const char **sigOut) {
    struct sigaction sa = {0}, ob = {0}, os = {0}, oi = {0}, ot = {0};
    sa.sa_handler = v3k_sig;
    sigaction(SIGBUS, &sa, &ob); sigaction(SIGSEGV, &sa, &os);
    sigaction(SIGILL, &sa, &oi); sigaction(SIGTRAP, &sa, &ot);
    g_lastsig = 0;
    int rc;
    if (sigsetjmp(g_jb, 1) == 0) {
        int v = ((int (*)(void))mem)();
        rc = (v == 42) ? 1 : 0;
    } else {
        rc = -1;
        if (sigOut) *sigOut = signame_(g_lastsig);
    }
    sigaction(SIGBUS, &ob, NULL); sigaction(SIGSEGV, &os, NULL);
    sigaction(SIGILL, &oi, NULL); sigaction(SIGTRAP, &ot, NULL);
    return rc;
}

- (NSString *)jitDiagnosticsReport {
    NSMutableString *r = [NSMutableString string];
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    [r appendFormat:@"iOS %ld.%ld.%ld\n", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion];
    [r appendFormat:@"CS %@\n", [self codeSigningFlagsDescription]];
    BOOL dbg = self.processIsDebugged;
    [r appendFormat:@"debugged: %@\n\n", dbg ? @"YES" : @"no"];

    const size_t len = 16384;
    const char *sig = NULL;

    // A0) The arena is what actually matters. If it is already up, report it and
    //     do NOT touch the brk again — the handshake is one-shot per attach, and
    //     re-running it here is exactly what made the second run of this screen
    //     report "no region (faulted)" on device.
    if (v3k_ios_jit_ready()) {
        [r appendFormat:@"A JIT arena: READY — %s\n", v3k_ios_jit_status()];
        [r appendFormat:@"  rx=%p rw=%p  %lu MB (%lu MB used)\n",
            v3k_ios_jit_rx(), v3k_ios_jit_rw(), v3k_ios_jit_size() >> 20, v3k_ios_jit_used() >> 20];
        const char *asig = NULL;
        int arc = guarded_exec(v3k_ios_jit_rx(), &asig);
        [r appendString: arc == 1 ? @"  execute out of the arena: PASS\n"
                       : arc == 0 ? @"  execute out of the arena: ran but wrong value\n"
                                  : [NSString stringWithFormat:@"  execute out of the arena: %s\n", asig ?: "fault"]];
        [r appendString:@"\nJIT WORKS \u2713 — the emulator has its executable memory.\n"];
        return r;
    }

    // A) JIT26 brk handshake (the iOS 26/27 TXM path) — only if debugged, since
    //    a brk with no debugger script attached would kill the process.
    if (!dbg) {
        [r appendString:@"A JIT26 handshake: skipped (not debugged — enable JIT in StikDebug first)\n"];
    } else if (_arenaImpl >= 0 && self.coreLinked) {
        // A real arena is available but not up yet: prepare THAT rather than a
        // throwaway probe region, so the one handshake we get is the one the
        // emulator will actually use.
        int rc = v3k_ios_jit_init(kV3KArenaBytes);
        if (rc == V3K_JIT_NO_IMPL) {
            _arenaImpl = -1;
            [r appendString:@"A JIT arena: no implementation linked — falling back to a standalone probe\n"];
        } else {
            _arenaImpl = 1;
            _jit = v3k_ios_jit_ready() ? V3KJITReady : V3KJITFailed;
            [r appendFormat:@"A JIT arena init: %@ — %s\n",
                v3k_ios_jit_ready() ? @"OK" : @"FAILED", v3k_ios_jit_status()];
            if (v3k_ios_jit_ready()) {
                const char *asig = NULL;
                int arc = guarded_exec(v3k_ios_jit_rx(), &asig);
                [r appendFormat:@"  rx=%p rw=%p  %lu MB\n", v3k_ios_jit_rx(), v3k_ios_jit_rw(),
                    v3k_ios_jit_size() >> 20];
                [r appendString: arc == 1 ? @"  execute out of the arena: PASS\n"
                               : arc == 0 ? @"  execute out of the arena: ran but wrong value\n"
                                          : [NSString stringWithFormat:@"  execute out of the arena: %s\n", asig ?: "fault"]];
                [r appendString:@"\nJIT WORKS \u2713 — the emulator has its executable memory.\n"];
                return r;
            }
            [r appendString:@"\nRe-enable JIT in StikDebug (universal.js attached) and relaunch Vita3K.\n"
                             "The handshake only works once per attach, so a retry needs a fresh attach.\n"];
            return r;
        }
    }
    // Fall back to the standalone probe only when there is no real arena to
    // prepare (UI-preview build, or no arena implementation linked).
    BOOL useArena = self.coreLinked && _arenaImpl >= 0;
    if (dbg && !useArena) {
        const char *why = "declined";
        void *rx = prepare_region_guarded(len, 8.0, &why, NO);
        if (!rx || rx == (void *)-1) {
            const char *why2 = "declined";
            rx = prepare_region_guarded(len, 4.0, &why2, YES);   // legacy brk #0x69
            if (rx && rx != (void *)-1) [r appendString:@"A JIT26: legacy brk #0x69 answered\n"];
        }
        if (!rx || rx == (void *)-1) {
            [r appendFormat:@"A JIT26 handshake: no region (%s)\n"
                            @"   -> In StikDebug: long-press Vita3K, Attach Script, universal.js\n", why];
        } else {
            mach_vm_address_t rw = 0; vm_prot_t cur = 0, mx = 0;
            kern_return_t kr = mach_vm_remap(mach_task_self(), &rw, len, 0, VM_FLAGS_ANYWHERE,
                                             mach_task_self(), (mach_vm_address_t)(uintptr_t)rx,
                                             false, &cur, &mx, VM_INHERIT_NONE);
            if (kr != KERN_SUCCESS) {
                [r appendFormat:@"A JIT26: RX@%p prepared but RW alias failed (kr=%d)\n", rx, kr];
            } else {
                mach_vm_protect(mach_task_self(), rw, len, false, VM_PROT_READ | VM_PROT_WRITE);
                struct sigaction s2 = {0}, o2 = {0}; s2.sa_handler = v3k_sig;
                sigaction(SIGTRAP, &s2, &o2);
                if (sigsetjmp(g_jb, 1) == 0) JIT26Detach();
                sigaction(SIGTRAP, &o2, NULL);
                memcpy((void *)(uintptr_t)rw, kProbeCode, sizeof kProbeCode);
                sys_icache_invalidate(rx, sizeof kProbeCode);
                sig = NULL;
                int rc = guarded_exec(rx, &sig);
                mach_vm_deallocate(mach_task_self(), rw, len);
                if (rc == 1) { [r appendString:@"A JIT26 handshake: PASS — executed emitted code\n"];
                               [r appendString:@"\nRESULT: JIT WORKS via the StikDebug JIT26 protocol.\n"]; return r; }
                [r appendFormat:@"A JIT26 handshake: prepared, but execute %s\n", rc < 0 ? sig : "wrong result"];
            }
        }
    }

    // B) vm_remap dual-mapping (no debugger handshake)
    {
        mach_vm_address_t rw = 0;
        if (mach_vm_allocate(mach_task_self(), &rw, len, VM_FLAGS_ANYWHERE) == KERN_SUCCESS) {
            memcpy((void *)(uintptr_t)rw, kProbeCode, sizeof kProbeCode);
            mach_vm_address_t rx = 0; vm_prot_t c = 0, m = 0;
            if (mach_vm_remap(mach_task_self(), &rx, len, 0, VM_FLAGS_ANYWHERE,
                              mach_task_self(), rw, false, &c, &m, VM_INHERIT_NONE) == KERN_SUCCESS &&
                mach_vm_protect(mach_task_self(), rx, len, false, VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS) {
                sys_icache_invalidate((void *)(uintptr_t)rx, sizeof kProbeCode);
                sig = NULL;
                int rc = guarded_exec((void *)(uintptr_t)rx, &sig);
                mach_vm_deallocate(mach_task_self(), rx, len);
                if (rc == 1) { mach_vm_deallocate(mach_task_self(), rw, len);
                               [r appendString:@"B dual-map (vm_remap): PASS\n\nRESULT: JIT WORKS via vm_remap dual-mapping.\n"]; return r; }
                [r appendFormat:@"B dual-map (vm_remap): execute %s\n", rc < 0 ? sig : "wrong result"];
            } else {
                [r appendString:@"B dual-map (vm_remap): could not map an RX alias\n"];
            }
            mach_vm_deallocate(mach_task_self(), rw, len);
        }
    }

    // C) oaknut/dynarmic path: mmap(R+X) -> mprotect(RW) -> write -> mprotect(R+X)
    {
        void *p = mmap(NULL, len, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (p == MAP_FAILED) {
            [r appendFormat:@"C mmap(R+X): failed errno=%d\n", errno];
        } else {
            if (mprotect(p, len, PROT_READ | PROT_WRITE) != 0) {
                [r appendFormat:@"C mprotect(RW): denied errno=%d\n", errno];
            } else {
                memcpy(p, kProbeCode, sizeof kProbeCode);
                if (mprotect(p, len, PROT_READ | PROT_EXEC) != 0) {
                    [r appendFormat:@"C mprotect(R+X): denied errno=%d\n", errno];
                } else {
                    sys_icache_invalidate(p, sizeof kProbeCode);
                    sig = NULL;
                    int rc = guarded_exec(p, &sig);
                    if (rc == 1) { munmap(p, len);
                                   [r appendString:@"C oaknut path: PASS\n\nRESULT: JIT WORKS via mprotect toggling.\n"]; return r; }
                    [r appendFormat:@"C oaknut path: execute %s\n", rc < 0 ? sig : "wrong result"];
                }
            }
            munmap(p, len);
        }
    }

    // D) MAP_JIT (needs the allow-jit entitlement; expected EPERM when sideloaded)
    {
        void *p = mmap(NULL, len, PROT_READ | PROT_WRITE | PROT_EXEC,
                       MAP_ANON | MAP_PRIVATE | 0x0800 /*MAP_JIT*/, -1, 0);
        if (p == MAP_FAILED) [r appendFormat:@"D MAP_JIT: failed errno=%d (expected without the entitlement)\n", errno];
        else { [r appendString:@"D MAP_JIT: mapped (unexpected — entitlement present?)\n"]; munmap(p, len); }
    }

    [r appendString:@"\nRESULT: no route to executable memory succeeded.\n"];
    if (!dbg) [r appendString:@"Enable JIT for Vita3K in StikDebug (with this app running), then re-run.\n"];
    else      [r appendString:@"The process IS debugged but the kernel still refuses execute.\n"
                              @"On iOS 26/27 this usually means the JIT26 protocol did not complete.\n"];
    return r;
}


#pragma mark - StikDebug integration

- (NSURL *)stikDebugJITURL {
    // Ask StikDebug to attach AND bind universal.js, which is what answers the
    // brk #0xf00d handshake. Passing the pid lets it target this exact process.
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"org.vita3k.emulator";
    NSString *s = [NSString stringWithFormat:
        @"stikdebug://enable-jit?bundle-id=%@&pid=%d&script-name=universal.js", bid, getpid()];
    return [NSURL URLWithString:s];
}

- (BOOL)stikDebugAvailable {
    return [UIApplication.sharedApplication canOpenURL:[self stikDebugJITURL]];
}

- (BOOL)requestJITViaStikDebug {
    NSURL *u = [self stikDebugJITURL];
    if (![UIApplication.sharedApplication canOpenURL:u]) return NO;
    [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
    return YES;
}

@end
