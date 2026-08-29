// Vita3KCore.m — stub bridge implementation. Compiles and runs today; the
// native Vita3K core is linked in behind the same interface later.
#import "Vita3KCore.h"
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
extern int csops(pid_t pid, unsigned int ops, void *buf, size_t size);
#define CS_OPS_STATUS 0
#define CS_DEBUGGED   0x10000000u

static sigjmp_buf g_jb;
static void v3k_sig(int s) { (void)s; siglongjmp(g_jb, 1); }

@implementation V3KTitle @end

@interface Vita3KCore () { V3KJITState _jit; }
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
    NSString *jit = _jit == V3KJITReady ? @"JIT ready"
                  : _jit == V3KJITUnavailable ? @"JIT off — enable in StikDebug"
                  : _jit == V3KJITFailed ? @"JIT failed" : @"JIT not tested";
    return [NSString stringWithFormat:@"%@  ·  %@", core, jit];
}

- (BOOL)prepareJITWithError:(NSError **)error {
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

- (NSArray<V3KTitle *> *)installedTitles {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *appDir = [self.dataRoot stringByAppendingPathComponent:@"ux0/app"];
    NSMutableArray<V3KTitle *> *out = [NSMutableArray array];
    for (NSString *tid in [fm contentsOfDirectoryAtPath:appDir error:nil] ?: @[]) {
        NSString *base = [appDir stringByAppendingPathComponent:tid];
        BOOL dir = NO;
        if (![fm fileExistsAtPath:base isDirectory:&dir] || !dir) continue;
        V3KTitle *t = [V3KTitle new];
        t.titleId = tid;
        t.name = tid;   // real core parses sce_sys/param.sfo TITLE
        NSString *icon = [base stringByAppendingPathComponent:@"sce_sys/icon0.png"];
        if ([fm fileExistsAtPath:icon]) t.iconPath = icon;
        t.category = @"gd";
        [out addObject:t];
    }
    return out;
}

- (BOOL)importPackageAtURL:(NSURL *)url error:(NSError **)error {
    NSString *dst = [[self.dataRoot stringByAppendingPathComponent:@"import"]
                     stringByAppendingPathComponent:url.lastPathComponent];
    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
    return [NSFileManager.defaultManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:error];
    // The real core: unpack VPK/PKG into ux0:/app/<titleId> and register it.
}

- (BOOL)deleteTitle:(V3KTitle *)title error:(NSError **)error {
    NSString *base = [[self.dataRoot stringByAppendingPathComponent:@"ux0/app"]
                      stringByAppendingPathComponent:title.titleId];
    return [NSFileManager.defaultManager removeItemAtPath:base error:error];
}

- (void)bootTitleId:(NSString *)titleId inLayer:(CALayer *)layer {
    vita3k_ios_boot(titleId.UTF8String, (__bridge void *)layer);
}
- (void)sendButtons:(uint32_t)mask { vita3k_ios_send_buttons(mask); }
- (void)sendLeftStickX:(float)x y:(float)y {}
- (void)sendRightStickX:(float)x y:(float)y {}
- (void)sendTouchFront:(CGPoint)p down:(BOOL)down {}
- (void)shutdown { vita3k_ios_shutdown(); }

@end
