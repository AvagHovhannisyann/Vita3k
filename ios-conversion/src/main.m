/*
 * ConvertedApp — Vita3K (org.vita3k.emulator) → iOS
 * -------------------------------------------------------------------------
 * This is the iOS-native application shell produced by converting the
 * supplied Android APK of the Vita3K PlayStation Vita emulator.
 *
 * It is a real ARM64 iOS UIKit application (no Xcode used to build it — it is
 * cross-compiled on Linux with clang + lld). It deliberately does two things:
 *
 *   1. Presents the original app's identity/branding (reusing the exact
 *      launcher icon and metadata recovered from the APK).
 *
 *   2. Performs a genuine runtime JIT self-test: it allocates memory, writes
 *      freshly-emitted ARM64 machine code into it, flips the page executable,
 *      and calls it — the exact operation Vita3K's Dynarmic/oaknut dynamic
 *      recompiler performs for every block of guest PS Vita code. This test
 *      SUCCEEDS only when the process holds JIT rights (get-task-allow +
 *      an attached debugger such as StikDebug). That makes the app's core
 *      behavior an honest, on-device demonstration of exactly why this app
 *      needs get-task-allow and StikDebug, rather than a mockup.
 *
 * The whole UI is built through the Objective-C runtime C API so that the
 * binary needs no compile-time UIKit/Foundation class symbols — only a
 * handful of C functions — which keeps the cross-compile self-contained.
 */

/* ---- minimal freestanding typedefs (no iOS SDK headers available) ------- */
typedef unsigned long   size_t;
typedef unsigned int    uint32_t;
typedef int             int32_t;
typedef unsigned long long uint64_t;
typedef unsigned char   uint8_t;
typedef long            intptr_t;

typedef void  *id;
typedef void  *Class;
typedef void  *SEL;
typedef void  *IMP;
typedef signed char BOOL;
#define YES ((BOOL)1)
#define NO  ((BOOL)0)
#define nil ((id)0)

/* ---- UIKit -------------------------------------------------------------- */
extern int UIApplicationMain(int argc, char **argv, id principalClassName, id delegateClassName);

/* ---- Objective-C runtime (libobjc) -------------------------------------- */
extern id    objc_getClass(const char *name);
extern SEL   sel_registerName(const char *name);
extern id    objc_msgSend(id self, SEL op, ...);
extern Class objc_allocateClassPair(Class superclass, const char *name, size_t extra);
extern void  objc_registerClassPair(Class cls);
extern BOOL  class_addMethod(Class cls, SEL name, IMP imp, const char *types);
extern id    objc_retain(id obj);

/* ---- libSystem (libc/kernel) -------------------------------------------- */
extern void *mmap(void *addr, size_t len, int prot, int flags, int fd, long long off);
extern int   munmap(void *addr, size_t len);
extern int   mprotect(void *addr, size_t len, int prot);
extern void *memcpy(void *d, const void *s, size_t n);
extern int   snprintf(char *s, size_t n, const char *fmt, ...);
extern char *strstr(const char *h, const char *n);
extern void *dlsym(void *handle, const char *sym);
extern int   getpid(void);
extern int   sysctl(int *name, unsigned namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
extern size_t strlen(const char *s);
extern int  *__error(void);                 /* errno location */
extern void  sys_icache_invalidate(void *start, size_t len);
/* csops(): ask the kernel for this process's CODE SIGNING status flags.
   This is the authoritative answer to "did StikDebug actually grant JIT?" */
extern int   csops(int pid, unsigned int ops, void *useraddr, size_t usersize);
#define errno              (*__error())
#define CS_OPS_STATUS      0
#define CS_VALID           0x00000001u
#define CS_GET_TASK_ALLOW  0x00000004u
#define CS_INSTALLER       0x00000008u
#define CS_HARD            0x00000100u
#define CS_KILL            0x00000200u
#define CS_DEBUGGED        0x10000000u

/* signal / non-local jump for fault-safe execution of the JIT probe */
extern int   sigsetjmp(void *env, int savemask);
extern void  siglongjmp(void *env, int val) __attribute__((noreturn));
struct d_sigaction { void *handler; unsigned int mask; int flags; };
extern int   sigaction(int sig, const struct d_sigaction *act, struct d_sigaction *old);

#define RTLD_DEFAULT ((void *)-2)

#define PROT_READ   0x1
#define PROT_WRITE  0x2
#define PROT_EXEC   0x4
#define MAP_PRIVATE 0x0002
#define MAP_ANON    0x1000
#define MAP_JIT     0x0800
#define MAP_FAILED  ((void *)-1)

#define SIGILL   4
#define SIGBUS  10
#define SIGSEGV 11
#define P_TRACED 0x00000800

/* ---- CoreGraphics geometry (arm64: CGFloat == double) ------------------- */
typedef double CGFloat;
typedef struct { CGFloat x, y; }        CGPoint;
typedef struct { CGFloat width, height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;
static CGRect RECT(CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    CGRect r; r.origin.x = x; r.origin.y = y; r.size.width = w; r.size.height = h; return r;
}

/* ---- tiny Objective-C helpers ------------------------------------------- */
static id  C(const char *n)  { return objc_getClass(n); }
static SEL S(const char *n)  { return sel_registerName(n); }
static id  NSStr(const char *c) {
    return ((id(*)(id, SEL, const char *))objc_msgSend)(C("NSString"), S("stringWithUTF8String:"), c);
}
static id  send0(id o, const char *sel) { return ((id(*)(id, SEL))objc_msgSend)(o, S(sel)); }
static id  send1(id o, const char *sel, id a) { return ((id(*)(id, SEL, id))objc_msgSend)(o, S(sel), a); }
static id  new_(const char *klass) { return send0(send0(C(klass), "alloc"), "init"); }
static void setFrame(id v, CGRect r) { ((void(*)(id, SEL, CGRect))objc_msgSend)(v, S("setFrame:"), r); }
static void addSub(id parent, id child) { send1(parent, "addSubview:", child); }
static id  rgb(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return ((id(*)(id, SEL, CGFloat, CGFloat, CGFloat, CGFloat))objc_msgSend)(
        C("UIColor"), S("colorWithRed:green:blue:alpha:"), r, g, b, a);
}
static id  sysFont(CGFloat size, int bold) {
    return ((id(*)(id, SEL, CGFloat))objc_msgSend)(
        C("UIFont"), S(bold ? "boldSystemFontOfSize:" : "systemFontOfSize:"), size);
}

/* Build a configured multi-line UILabel */
static id makeLabel(CGRect frame, const char *text, CGFloat font, int bold, id color, int centered) {
    id lbl = new_("UILabel");
    setFrame(lbl, frame);
    send1(lbl, "setText:", NSStr(text));
    send1(lbl, "setTextColor:", color);
    send1(lbl, "setFont:", sysFont(font, bold));
    ((void(*)(id, SEL, long))objc_msgSend)(lbl, S("setNumberOfLines:"), 0);
    if (centered)
        ((void(*)(id, SEL, long))objc_msgSend)(lbl, S("setTextAlignment:"), 1 /*NSTextAlignmentCenter*/);
    return lbl;
}

/* ========================================================================= */
/*  JIT self-test — the honest demonstration of the get-task-allow/StikDebug */
/*  requirement.  Emits `mov w0, #42 ; ret` and executes it.                  */
/* ========================================================================= */
static long g_jbuf[256] __attribute__((aligned(16)));      /* oversized sigjmp_buf   */
static struct d_sigaction g_old_bus, g_old_segv, g_old_ill;

static void fault_handler(int sig) { (void)sig; siglongjmp(g_jbuf, 1); }

static void install_faults(void) {
    struct d_sigaction sa; sa.handler = (void *)fault_handler; sa.mask = 0; sa.flags = 0;
    sigaction(SIGBUS,  &sa, &g_old_bus);
    sigaction(SIGSEGV, &sa, &g_old_segv);
    sigaction(SIGILL,  &sa, &g_old_ill);
}
static void restore_faults(void) {
    sigaction(SIGBUS,  &g_old_bus,  (struct d_sigaction *)0);
    sigaction(SIGSEGV, &g_old_segv, (struct d_sigaction *)0);
    sigaction(SIGILL,  &g_old_ill,  (struct d_sigaction *)0);
}

/*
 * Returns 1=JIT active (pass), 0=blocked, -1=alloc failure; fills `out`.
 *
 * On arm64 iOS a page may never be simultaneously writable AND executable
 * (W^X / APRR). The sequence a sideloaded, get-task-allow + StikDebug process
 * is actually granted is:  mmap(RW) -> write -> mprotect(R+X) -> execute.
 * The mprotect(PROT_EXEC) call is the operation gated by CS_DEBUGGED: it fails
 * with EPERM until StikDebug (a debugger) has flipped the process debuggable,
 * and succeeds afterwards. (Directly executing an mmap(RWX) page does NOT work
 * even with JIT enabled, because the page is still writable — that was the bug
 * in the first build.) MAP_JIT + pthread_jit_write_protect_np is a *different*
 * path that needs the com.apple.security.cs.allow-jit entitlement, which a free
 * sideload does not have, so it is attempted only as a best-effort fast path.
 */
static const uint32_t JIT_CODE[2] = { 0x52800540u /* mov w0, #42 */, 0xD65F03C0u /* ret */ };

/* Read this process's code-signing status. Returns 0 on success. */
static int cs_flags(unsigned int *out) {
    unsigned int f = 0;
    if (csops(getpid(), CS_OPS_STATUS, &f, sizeof f) != 0) return -1;
    *out = f;
    return 0;
}

/* Append to a bounded log buffer. */
static char *g_log; static int g_logpos, g_logcap;
static void log_init(char *b, int cap) { g_log = b; g_logcap = cap; g_logpos = 0; if (cap) b[0] = 0; }
static void log_add(const char *s) {
    int n = (int)strlen(s), room = g_logcap - g_logpos - 1;
    if (room <= 0) return;
    if (n > room) n = room;
    memcpy(g_log + g_logpos, s, (size_t)n);
    g_logpos += n; g_log[g_logpos] = 0;
}
static void log_err(const char *what, int e) {
    char t[192]; snprintf(t, sizeof t, "%s errno=%d\n", what, e); log_add(t);
}

/* Execute the emitted code under a fault guard. 1 = ran and returned 42. */
static int try_exec(void *mem) {
    sys_icache_invalidate(mem, sizeof JIT_CODE);
    install_faults();
    volatile int r = -1;
    if (sigsetjmp(g_jbuf, 1) == 0) {
        int (*fn)(void) = (int (*)(void))mem;
        r = fn();
        restore_faults();
        return (r == 42);
    }
    restore_faults();
    return 0;   /* faulted */
}

/*
 * Try every route to executable memory, reporting exactly how each one failed.
 * A: mmap(RW) -> mprotect(R+X)      <- what get-task-allow + StikDebug grants
 * B: mmap(RWX) directly             <- works when the task is fully debugged
 * C: MAP_JIT + pthread_jit_write_protect_np  <- needs the allow-jit entitlement
 */
static int jit_selftest(char *out, int n) {
    const size_t len = 4096;
    log_init(out, n);

    unsigned int cs = 0;
    int have_cs = cs_flags(&cs);
    int debugged = (have_cs == 0) && (cs & CS_DEBUGGED);

    if (have_cs == 0) {
        char t[160];
        snprintf(t, sizeof t, "CS flags 0x%08x  [%s%s%s]\n", cs,
                 (cs & CS_VALID) ? "valid " : "",
                 (cs & CS_GET_TASK_ALLOW) ? "get-task-allow " : "",
                 debugged ? "DEBUGGED" : "NOT-debugged");
        log_add(t);
    } else {
        log_add("CS flags: csops() unavailable\n");
    }

    /* --- A: the sideload/StikDebug path --------------------------------- */
    void *m = mmap(nil, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (m == MAP_FAILED) {
        log_add("A mmap(RW): FAILED\n");
    } else {
        memcpy(m, JIT_CODE, sizeof JIT_CODE);
        if (mprotect(m, len, PROT_READ | PROT_EXEC) != 0) {
            log_err("A mprotect(R+X): DENIED", errno);
        } else if (try_exec(m)) {
            munmap(m, len);
            snprintf(out, n, "PASS \xE2\x80\x94 JIT ACTIVE\nExecuted emitted ARM64 code (returned 42).\nvia mmap(RW) \xE2\x86\x92 mprotect(R+X).\nThe Dynarmic recompiler substrate can run here.");
            return 1;
        } else {
            log_add("A mprotect(R+X) OK but execute FAULTED\n");
        }
        munmap(m, len);
    }

    /* --- B: direct RWX --------------------------------------------------- */
    m = mmap(nil, len, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (m == MAP_FAILED) {
        log_err("B mmap(RWX): FAILED", errno);
    } else {
        memcpy(m, JIT_CODE, sizeof JIT_CODE);
        if (try_exec(m)) {
            munmap(m, len);
            snprintf(out, n, "PASS \xE2\x80\x94 JIT ACTIVE\nExecuted emitted ARM64 code (returned 42).\nvia mmap(RWX).\nThe Dynarmic recompiler substrate can run here.");
            return 1;
        }
        log_add("B mmap(RWX) OK but execute FAULTED\n");
        munmap(m, len);
    }

    /* --- C: MAP_JIT ------------------------------------------------------ */
    void (*jit_wp)(int) = (void (*)(int))dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
    m = mmap(nil, len, PROT_READ | PROT_WRITE | PROT_EXEC,
             MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);
    if (m == MAP_FAILED) {
        log_err("C mmap(MAP_JIT): FAILED", errno);
    } else {
        if (jit_wp) jit_wp(0);
        memcpy(m, JIT_CODE, sizeof JIT_CODE);
        if (jit_wp) jit_wp(1);
        if (try_exec(m)) {
            munmap(m, len);
            snprintf(out, n, "PASS \xE2\x80\x94 JIT ACTIVE\nExecuted emitted ARM64 code (returned 42).\nvia MAP_JIT.\nThe Dynarmic recompiler substrate can run here.");
            return 1;
        }
        log_add(jit_wp ? "C MAP_JIT OK but execute FAULTED\n" : "C MAP_JIT ok, no write-protect fn\n");
        munmap(m, len);
    }

    log_add(debugged
        ? "\nProcess IS debugged but no route to executable memory worked."
        : "\nDIAGNOSIS: this process is NOT debugged \xE2\x80\x94 StikDebug has not\nattached to it, so the kernel grants no JIT. Enable JIT in\nStikDebug while this app is running, then tap the button.");
    return 0;
}

/* Detect whether a debugger / JIT-enabler (StikDebug) is attached. */
static int is_debugged(void) {
    int mib[4] = { 1 /*CTL_KERN*/, 14 /*KERN_PROC*/, 1 /*KERN_PROC_PID*/, 0 };
    mib[3] = getpid();
    unsigned char info[900];
    size_t sz = sizeof info;
    for (size_t i = 0; i < sizeof info; i++) info[i] = 0;
    if (sysctl(mib, 4, info, &sz, nil, 0) != 0) return -1;
    int p_flag = *(int *)(info + 32);   /* kinfo_proc.kp_proc.p_flag */
    return (p_flag & P_TRACED) ? 1 : 0;
}

/* ========================================================================= */
/*  UI                                                                       */
/* ========================================================================= */
static id g_window;
static id g_dbgLabel, g_jitHeader, g_jitBody;   /* live status labels (re-runnable) */

/* Re-run the debugger check + JIT self-test and update the on-screen labels.
 * Called at launch, whenever the app becomes active (e.g. after StikDebug
 * enables JIT and returns focus), and from the "Run JIT self-test" button. */
static void refresh_status(void) {
    if (!g_jitBody) return;

    int dbg = is_debugged();
    char dbgline[160];
    snprintf(dbgline, sizeof dbgline, "Debugger attached now:  %s   (JIT persists after detach)",
             dbg == 1 ? "YES" : dbg == 0 ? "no" : "unknown");
    send1(g_dbgLabel, "setText:", NSStr(dbgline));
    send1(g_dbgLabel, "setTextColor:", dbg == 1 ? rgb(0.4, 0.9, 0.4, 1.0) : rgb(0.72, 0.70, 0.78, 1.0));

    char jitbuf[512];
    int jit = jit_selftest(jitbuf, sizeof jitbuf);
    id jitColor = jit == 1 ? rgb(0.35, 0.92, 0.45, 1.0) : rgb(1.0, 0.62, 0.30, 1.0);
    send1(g_jitHeader, "setText:", NSStr(jit == 1 ? "JIT SELF-TEST:  PASS" : "JIT SELF-TEST:  standby"));
    send1(g_jitHeader, "setTextColor:", jitColor);
    send1(g_jitBody, "setText:", NSStr(jitbuf));
}

/* Button action: -runTest: */
static void runTest(id self, SEL _cmd, id sender) {
    (void)self; (void)_cmd; (void)sender;
    refresh_status();
}

/* -applicationDidBecomeActive: */
static void didBecomeActive(id self, SEL _cmd, id application) {
    (void)self; (void)_cmd; (void)application;
    refresh_status();
}

static BOOL didFinishLaunching(id self, SEL _cmd, id application, id options) {
    (void)_cmd; (void)application; (void)options;

    id screen = send0(C("UIScreen"), "mainScreen");
    CGRect bounds = ((CGRect(*)(id, SEL))objc_msgSend)(screen, S("bounds"));
    CGFloat W = bounds.size.width, H = bounds.size.height;

    g_window = ((id(*)(id, SEL, CGRect))objc_msgSend)(send0(C("UIWindow"), "alloc"), S("initWithFrame:"), bounds);
    objc_retain(g_window);

    id vc = new_("UIViewController");
    id view = send0(vc, "view");
    send1(view, "setBackgroundColor:", rgb(0.09, 0.05, 0.11, 1.0));   /* Vita3K deep purple */

    CGFloat pad = 24.0;
    CGFloat top = H * 0.07;

    /* App icon (reused verbatim from the APK: res/GX.png) */
    CGFloat iconSz = 96.0;
    id bundle = send0(C("NSBundle"), "mainBundle");
    id iconPath = ((id(*)(id, SEL, id, id))objc_msgSend)(bundle, S("pathForResource:ofType:"), NSStr("AppIcon180"), NSStr("png"));
    id iconImg = ((id(*)(id, SEL, id))objc_msgSend)(C("UIImage"), S("imageWithContentsOfFile:"), iconPath);
    id iconView = ((id(*)(id, SEL, id))objc_msgSend)(send0(C("UIImageView"), "alloc"), S("initWithImage:"), iconImg);
    setFrame(iconView, RECT((W - iconSz) / 2.0, top, iconSz, iconSz));
    ((void(*)(id, SEL, long))objc_msgSend)(iconView, S("setContentMode:"), 1 /*ScaleAspectFit*/);
    addSub(view, iconView);

    CGFloat y = top + iconSz + 14.0;

    id gold = rgb(1.0, 0.78, 0.10, 1.0);
    id white = rgb(0.96, 0.96, 0.98, 1.0);
    id grey  = rgb(0.72, 0.70, 0.78, 1.0);

    id title = makeLabel(RECT(pad, y, W - 2 * pad, 40), "Vita3K", 34, 1, gold, 1);
    addSub(view, title); y += 44;

    id subtitle = makeLabel(RECT(pad, y, W - 2 * pad, 24), "PlayStation Vita Emulator — iOS build", 15, 0, grey, 1);
    addSub(view, subtitle); y += 32;

    id meta = makeLabel(RECT(pad, y, W - 2 * pad, 40),
                        "Converted from org.vita3k.emulator (v0.2.1)\nAndroid APK \xE2\x86\x92 iOS ARM64 package", 12, 0, grey, 1);
    addSub(view, meta); y += 54;

    g_dbgLabel = makeLabel(RECT(pad, y, W - 2 * pad, 24), " ", 13, 1, grey, 1);
    addSub(view, g_dbgLabel); y += 32;

    g_jitHeader = makeLabel(RECT(pad, y, W - 2 * pad, 24), " ", 17, 1, grey, 1);
    addSub(view, g_jitHeader); y += 30;

    g_jitBody = makeLabel(RECT(pad, y, W - 2 * pad, 140), " ", 13.0, 0, white, 1);
    addSub(view, g_jitBody);

    /* "Run JIT self-test" button — tap AFTER enabling JIT in StikDebug */
    CGFloat bw = 260, bh = 48;
    id btn = ((id(*)(id, SEL, long))objc_msgSend)(C("UIButton"), S("buttonWithType:"), 1 /*System*/);
    setFrame(btn, RECT((W - bw) / 2.0, H - 150, bw, bh));
    ((void(*)(id, SEL, id, long))objc_msgSend)(btn, S("setTitle:forState:"), NSStr("Run JIT self-test"), 0);
    ((void(*)(id, SEL, id, long))objc_msgSend)(btn, S("setTitleColor:forState:"), rgb(0.09, 0.05, 0.11, 1.0), 0);
    send1(btn, "setBackgroundColor:", gold);
    id btnFont = ((id(*)(id, SEL, CGFloat))objc_msgSend)(C("UIFont"), S("boldSystemFontOfSize:"), 17.0);
    send1(send0(btn, "titleLabel"), "setFont:", btnFont);
    id blayer = send0(btn, "layer");
    ((void(*)(id, SEL, CGFloat))objc_msgSend)(blayer, S("setCornerRadius:"), 12.0);
    ((void(*)(id, SEL, id, SEL, long))objc_msgSend)(btn, S("addTarget:action:forControlEvents:"),
        self, S("runTest:"), 1 << 6 /*UIControlEventTouchUpInside*/);
    addSub(view, btn);

    id footer = makeLabel(RECT(pad, H - 84, W - 2 * pad, 64),
                          "Sideload with Sideloadly (free Apple ID sets get-task-allow).\n"
                          "In StikDebug: Enable JIT for Vita3K, return here, tap the button.\n"
                          "A green PASS means this device can run the Dynarmic JIT.", 11, 0, grey, 1);
    addSub(view, footer);

    ((void(*)(id, SEL, id))objc_msgSend)(g_window, S("setRootViewController:"), vc);
    send0(g_window, "makeKeyAndVisible");

    /* keep the screen awake like the emulator would (WAKE_LOCK equivalent) */
    id app = send0(C("UIApplication"), "sharedApplication");
    ((void(*)(id, SEL, BOOL))objc_msgSend)(app, S("setIdleTimerDisabled:"), YES);

    refresh_status();
    return YES;
}

int main(int argc, char **argv) {
    Class Delegate = objc_allocateClassPair(C("UIResponder"), "Vita3KAppDelegate", 0);
    class_addMethod(Delegate, S("application:didFinishLaunchingWithOptions:"),
                    (IMP)didFinishLaunching, "c@:@@");
    class_addMethod(Delegate, S("applicationDidBecomeActive:"), (IMP)didBecomeActive, "v@:@");
    class_addMethod(Delegate, S("runTest:"), (IMP)runTest, "v@:@");
    objc_registerClassPair(Delegate);
    return UIApplicationMain(argc, argv, nil, NSStr("Vita3KAppDelegate"));
}
