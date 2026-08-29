// Vita3KCore.m — stub bridge implementation. Compiles and runs today; the
// native Vita3K core is linked in behind the same interface later.
#import "Vita3KCore.h"
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
    vita3k_ios_boot(titleId.UTF8String, (__bridge void *)layer);
}
- (void)sendButtons:(uint32_t)mask { vita3k_ios_send_buttons(mask); }
- (void)sendLeftStickX:(float)x y:(float)y {}
- (void)sendRightStickX:(float)x y:(float)y {}
- (void)sendTouchFront:(CGPoint)p down:(BOOL)down {}
- (void)shutdown { vita3k_ios_shutdown(); }

@end
