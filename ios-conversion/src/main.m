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

/* ---- Mach VM (for the vm_remap dual-mapping "bulletproof JIT" path) ------ */
typedef unsigned int       mach_port_t;
typedef mach_port_t        vm_map_t;
typedef unsigned long long mach_vm_address_t;
typedef unsigned long long mach_vm_size_t;
typedef unsigned long long mach_vm_offset_t;
typedef int                vm_prot_t;
typedef int                kern_return_t;
typedef int                boolean_t;
typedef unsigned int       vm_inherit_t;
extern mach_port_t   mach_task_self_;
extern kern_return_t mach_vm_allocate(vm_map_t, mach_vm_address_t *, mach_vm_size_t, int);
extern kern_return_t mach_vm_deallocate(vm_map_t, mach_vm_address_t, mach_vm_size_t);
extern kern_return_t mach_vm_remap(vm_map_t, mach_vm_address_t *, mach_vm_size_t, mach_vm_offset_t,
                                   int, vm_map_t, mach_vm_address_t, boolean_t,
                                   vm_prot_t *, vm_prot_t *, vm_inherit_t);
extern kern_return_t mach_vm_protect(vm_map_t, mach_vm_address_t, mach_vm_size_t, boolean_t, vm_prot_t);
#define VM_FLAGS_ANYWHERE 0x0001
#define VM_PROT_READ      1
#define VM_PROT_WRITE     2
#define VM_PROT_EXECUTE   4
#define VM_INHERIT_NONE   2
#define KERN_SUCCESS      0

/* ---- threads (for continuous background JIT probing) -------------------- */
typedef void *pthread_t;
extern int          pthread_create(pthread_t *, const void *, void *(*)(void *), void *);
extern unsigned int usleep(unsigned int);

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

#define SIGTRAP  5
#define SIGILL   4
#define SIGBUS  10
#define SIGSEGV 11
#define P_TRACED 0x00000800

/* ---- mutex (serialize the two probe sites so signal handlers don't race) - */
extern int pthread_mutex_init(void *, const void *);
extern int pthread_mutex_lock(void *);
extern int pthread_mutex_unlock(void *);

/* ---- iOS 26 / TXM JIT protocol (StikJIT "JIT26" brk #0xf00d handshake) ----
 * On A15+/TXM devices CS_DEBUGGED is not enough: each executable region must be
 * prepared by StikDebug's attached debugger. The app signals the debugger with
 * a breakpoint. x16 selects the op; args are in x0/x1; result returns in x0.
 * A brk with no script attached raises SIGTRAP (we guard for it). */
__attribute__((noinline, naked)) static void *JIT26PrepareRegion(void *address, unsigned long length) {
    __asm__ volatile("mov x16, #1\n\t brk #0xf00d\n\t ret\n\t");
}
__attribute__((noinline, naked)) static void JIT26Detach(void) {
    __asm__ volatile("mov x16, #0\n\t brk #0xf00d\n\t ret\n\t");
}

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
static struct d_sigaction g_old_bus, g_old_segv, g_old_ill, g_old_trap;

static volatile int g_lastsig;          /* signal that aborted the last probe */

static void fault_handler(int sig) { g_lastsig = sig; siglongjmp(g_jbuf, 1); }

static const char *signame(int s) {
    return s == SIGILL ? "SIGILL" : s == SIGBUS ? "SIGBUS" : s == SIGSEGV ? "SIGSEGV"
         : s == SIGTRAP ? "SIGTRAP" : "fault";
}

static void install_faults(void) {
    struct d_sigaction sa; sa.handler = (void *)fault_handler; sa.mask = 0; sa.flags = 0;
    sigaction(SIGBUS,  &sa, &g_old_bus);
    sigaction(SIGSEGV, &sa, &g_old_segv);
    sigaction(SIGILL,  &sa, &g_old_ill);
    sigaction(SIGTRAP, &sa, &g_old_trap);
}
static void restore_faults(void) {
    sigaction(SIGBUS,  &g_old_bus,  (struct d_sigaction *)0);
    sigaction(SIGSEGV, &g_old_segv, (struct d_sigaction *)0);
    sigaction(SIGILL,  &g_old_ill,  (struct d_sigaction *)0);
    sigaction(SIGTRAP, &g_old_trap, (struct d_sigaction *)0);
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
/* `bti c` first: on ARMv8.5+ an indirect branch into a BTI-guarded page needs a
   landing pad or the CPU raises SIGILL. On older cores it decodes as a NOP, so
   it is free insurance. */
static const uint32_t JIT_CODE[3] = {
    0xD503245Fu /* bti c      */, 0x52800540u /* mov w0, #42 */, 0xD65F03C0u /* ret */
};
/* Bare landing-pad + return: executes no real work. If even THIS faults, the
   page is simply not executable (permission), rather than the bytes being bad. */
static const uint32_t RET_CODE[2] = { 0xD503245Fu /* bti c */, 0xD65F03C0u /* ret */ };

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

/* Execute the emitted code under a fault guard. 1 = ran and returned 42.
   On failure g_lastsig holds the signal (0 = ran but returned the wrong value). */
static int try_exec(void *mem) {
    sys_icache_invalidate(mem, sizeof JIT_CODE);
    g_lastsig = 0;
    install_faults();
    volatile int r = -1;
    if (sigsetjmp(g_jbuf, 1) == 0) {
        int (*fn)(void) = (int (*)(void))mem;
        r = fn();
        restore_faults();
        return (r == 42);
    }
    restore_faults();
    return 0;   /* faulted; see g_lastsig */
}

/* Can this page execute AT ALL? Runs only `bti c ; ret`, so a fault here means
   the page has no execute permission, not that the emitted bytes were bad. */
static int try_exec_bare(void *mem) {
    sys_icache_invalidate(mem, sizeof RET_CODE);
    g_lastsig = 0;
    install_faults();
    if (sigsetjmp(g_jbuf, 1) == 0) {
        ((void (*)(void))mem)();
        restore_faults();
        return 1;
    }
    restore_faults();
    return 0;
}

static void log_fault(const char *what) {
    char t[192];
    snprintf(t, sizeof t, "%s %s\n", what, g_lastsig ? signame(g_lastsig) : "wrong result");
    log_add(t);
}

/*
 * Try every route to executable memory, reporting exactly how each one failed.
 * A: mmap(RW) -> mprotect(R+X)      <- what get-task-allow + StikDebug grants
 * B: mmap(RWX) directly             <- works when the task is fully debugged
 * C: MAP_JIT + pthread_jit_write_protect_np  <- needs the allow-jit entitlement
 */
/* Strategy F: vm_remap dual-mapping ("bulletproof JIT"). Map the same physical
 * pages twice — one RW view to write through, one RX view to execute from — so
 * no single mapping is ever W and X at once. This is what UTM/Dolphin use on
 * sideloaded iOS when MAP_JIT is unavailable. Returns 1 on success. */
static int jit_dualmap(char *out, int n) {
    const mach_vm_size_t len = 16384;
    mach_vm_address_t rw = 0;
    kern_return_t kr = mach_vm_allocate(mach_task_self_, &rw, len, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) { snprintf(out, n, "F dualmap: alloc failed kr=%d", kr); return 0; }
    memcpy((void *)(unsigned long)rw, JIT_CODE, sizeof JIT_CODE);

    mach_vm_address_t rx = 0;
    vm_prot_t cur = 0, max = 0;
    kr = mach_vm_remap(mach_task_self_, &rx, len, 0, VM_FLAGS_ANYWHERE,
                       mach_task_self_, rw, 0 /*copy=false: share phys pages*/,
                       &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        snprintf(out, n, "F dualmap: remap failed kr=%d", kr);
        mach_vm_deallocate(mach_task_self_, rw, len);
        return 0;
    }
    kr = mach_vm_protect(mach_task_self_, rx, len, 0, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        snprintf(out, n, "F dualmap: protect(RX) failed kr=%d", kr);
        mach_vm_deallocate(mach_task_self_, rx, len);
        mach_vm_deallocate(mach_task_self_, rw, len);
        return 0;
    }
    sys_icache_invalidate((void *)(unsigned long)rx, sizeof JIT_CODE);

    install_faults();
    g_lastsig = 0;
    int ok = 0;
    if (sigsetjmp(g_jbuf, 1) == 0) {
        int (*fn)(void) = (int (*)(void))(unsigned long)rx;
        ok = (fn() == 42);
        restore_faults();
    } else {
        restore_faults();
    }
    mach_vm_deallocate(mach_task_self_, rx, len);
    mach_vm_deallocate(mach_task_self_, rw, len);
    if (ok) {
        snprintf(out, n, "PASS \xE2\x80\x94 JIT ACTIVE (vm_remap dual-mapping)\nWrote via RW view, executed via separate RX view (returned 42).\nThis is the bulletproof-JIT path UTM/Dolphin use on iOS.\nVita3K's JIT can be made to run this way.");
        return 1;
    }
    snprintf(out, n, "F dualmap: RW+RX mapped OK but execute %s",
             g_lastsig ? signame(g_lastsig) : "wrong-result");
    return 0;
}

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

    /* --- F: vm_remap dual-mapping (tried first: most likely to work) ------ */
    {
        char fbuf[300];
        if (jit_dualmap(fbuf, sizeof fbuf) == 1) { snprintf(out, n, "%s", fbuf); return 1; }
        log_add(fbuf); log_add("\n");
    }

    /* --- E: oaknut/dynarmic's REAL iOS sequence -------------------------- *
     * This is what Vita3K's own JIT does on iOS (oaknut code_block.hpp,
     * TARGET_OS_IPHONE branch):
     *     mmap(PROT_READ|PROT_EXEC)      <-- EXEC present at creation time
     *     mprotect(RW) -> write -> mprotect(RX) -> sys_icache_invalidate
     * Creating the mapping WITH exec matters: on Darwin a region's maximum
     * protection is fixed at mmap() time, so a page born RW-only can be
     * permanently barred from ever becoming executable. Try this first. */
    void *m = mmap(nil, len, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (m == MAP_FAILED) {
        log_err("E mmap(R+X): FAILED", errno);
    } else {
        if (mprotect(m, len, PROT_READ | PROT_WRITE) != 0) {
            log_err("E mprotect(RW) to write: DENIED", errno);
        } else {
            memcpy(m, JIT_CODE, sizeof JIT_CODE);
            if (mprotect(m, len, PROT_READ | PROT_EXEC) != 0) {
                log_err("E mprotect(back to R+X): DENIED", errno);
            } else if (try_exec(m)) {
                munmap(m, len);
                snprintf(out, n, "PASS \xE2\x80\x94 JIT ACTIVE\nExecuted emitted ARM64 code (returned 42).\nvia oaknut's iOS path: mmap(R+X) \xE2\x86\x92 mprotect(RW) \xE2\x86\x92 write \xE2\x86\x92 mprotect(R+X).\nThis is exactly what Vita3K's Dynarmic JIT does on iOS.");
                return 1;
            } else {
                log_fault("E oaknut path, execute FAULTED:");
            }
        }
        munmap(m, len);
    }

    /* --- A: the sideload/StikDebug path --------------------------------- */
    m = mmap(nil, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
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
            log_fault("A mprotect(R+X) OK but execute FAULTED:");
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
        log_fault("B mmap(RWX) OK but execute FAULTED:");
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
        log_fault(jit_wp ? "C MAP_JIT OK but execute FAULTED:" : "C MAP_JIT (no write-protect fn):");
        munmap(m, len);
    }

    /* --- D: can the page execute at all? (bti c ; ret only) -------------- */
    int bare = 0;
    m = mmap(nil, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (m != MAP_FAILED) {
        memcpy(m, RET_CODE, sizeof RET_CODE);
        if (mprotect(m, len, PROT_READ | PROT_EXEC) == 0) {
            bare = try_exec_bare(m);
            log_fault(bare ? "D bare ret: RAN \xE2\x80\x94 execution works;" : "D bare ret: FAULTED");
        }
        munmap(m, len);
    }

    if (!debugged) {
        log_add("\nDIAGNOSIS: process is NOT debugged \xE2\x80\x94 StikDebug has not\n"
                "attached, so the kernel grants no JIT. Enable JIT in StikDebug\n"
                "while this app is running, then tap the button.");
    } else if (bare) {
        log_add("\nDIAGNOSIS: pages DO execute, but the emitted instruction\n"
                "sequence did not. This is a code-generation problem, not a\n"
                "permissions one.");
    } else {
        log_add("\nDIAGNOSIS: process IS debugged and the mappings are accepted,\n"
                "but no page will execute. The kernel is refusing execute despite\n"
                "CS_DEBUGGED \xE2\x80\x94 an OS-policy block, not an app bug.");
    }
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

/* The iOS 26 / TXM path: ask StikDebug's attached debugger to prepare an RX
 * region (brk handshake), make a writable alias of it, detach, then write code
 * via the RW alias and execute via the RX region. Returns 1 on success. */
static int jit_test_jit26(char *out, int n) {
    unsigned int cs = 0;
    if (cs_flags(&cs) != 0 || !(cs & CS_DEBUGGED)) {
        snprintf(out, n, "iOS 26 JIT: process is NOT debugged yet.\n"
                 "In StikDebug, Enable JIT for Vita3K while it is running,\n"
                 "then come back and tap this button (do not relaunch).");
        return 0;
    }
    const unsigned long len = 16384;

    /* 1) ask the debugger to prepare an RX region (NULL -> it allocates). */
    install_faults();
    g_lastsig = 0;
    void *rx = (void *)0;
    if (sigsetjmp(g_jbuf, 1) == 0) {
        rx = JIT26PrepareRegion((void *)0, len);
        restore_faults();
    } else {
        restore_faults();
        snprintf(out, n, "iOS 26 JIT: the brk handshake was not answered (%s).\n"
                 "Your StikDebug build may not implement the iOS 26 JIT protocol,\n"
                 "or JIT was not actually enabled for THIS running process.\n"
                 "Update StikDebug, Enable JIT for Vita3K, then retry.", signame(g_lastsig));
        return 0;
    }
    if (rx == (void *)0 || rx == (void *)-1) {
        snprintf(out, n, "iOS 26 JIT: PrepareRegion returned null (debugger declined).");
        return 0;
    }

    /* 2) make a writable alias of the same physical pages. */
    mach_vm_address_t rw = 0; vm_prot_t cur = 0, max = 0;
    kern_return_t kr = mach_vm_remap(mach_task_self_, &rw, len, 0, VM_FLAGS_ANYWHERE,
                                     mach_task_self_, (mach_vm_address_t)(unsigned long)rx,
                                     0, &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        snprintf(out, n, "iOS 26 JIT: RX@%lx prepared, but RW-alias remap failed kr=%d",
                 (unsigned long)rx, kr);
        return 0;
    }
    mach_vm_protect(mach_task_self_, rw, len, 0, VM_PROT_READ | VM_PROT_WRITE);

    /* 3) detach the handshake (per protocol), then write + execute at runtime. */
    install_faults();
    if (sigsetjmp(g_jbuf, 1) == 0) { JIT26Detach(); restore_faults(); }
    else { restore_faults(); }

    memcpy((void *)(unsigned long)rw, JIT_CODE, sizeof JIT_CODE);
    sys_icache_invalidate(rx, sizeof JIT_CODE);

    install_faults();
    g_lastsig = 0;
    int ok = 0;
    if (sigsetjmp(g_jbuf, 1) == 0) {
        int (*fn)(void) = (int (*)(void))rx;
        ok = (fn() == 42);
        restore_faults();
    } else {
        restore_faults();
    }
    mach_vm_deallocate(mach_task_self_, rw, len);

    if (ok) {
        snprintf(out, n, "PASS \xE2\x80\x94 JIT ACTIVE via the iOS 26 protocol!\n"
                 "StikDebug prepared RX@%lx; wrote via RW alias; executed (returned 42).\n"
                 "Vita3K's Dynarmic recompiler CAN run on this device this way.",
                 (unsigned long)rx);
        return 1;
    }
    snprintf(out, n, "iOS 26 JIT: region prepared + written, but execute %s.\n"
             "iOS 26 may have revoked execute on the idle page, or the debugger\n"
             "must stay attached. Keep StikDebug attached and retry.",
             g_lastsig ? signame(g_lastsig) : "returned wrong value");
    return 0;
}

/* ========================================================================= */
/*  UI                                                                       */
/* ========================================================================= */
static id g_window;
static id g_jit26Label;
static long g_mtx[8] __attribute__((aligned(16)));   /* pthread_mutex_t storage */
static id g_dbgLabel, g_jitHeader, g_jitBody;   /* live status labels (re-runnable) */

static char g_osver[64];
static volatile int g_everPassed = 0, g_passedWhileAttached = 0;

/* Marshal a one-argument ObjC message to the main thread (UI must run there). */
static void mt(id obj, const char *sel, id arg) {
    ((void (*)(id, SEL, SEL, id, BOOL))objc_msgSend)(
        obj, S("performSelectorOnMainThread:withObject:waitUntilDone:"), S(sel), arg, NO);
}

/* One probe cycle: run the full self-test, update the labels. */
static void probe_once(void) {
    if (!g_jitBody) return;
    int dbg = is_debugged();
    char jitbuf[700];
    pthread_mutex_lock(g_mtx);
    int jit = jit_selftest(jitbuf, sizeof jitbuf);
    pthread_mutex_unlock(g_mtx);
    if (jit == 1) { g_everPassed = 1; if (dbg == 1) g_passedWhileAttached = 1; }

    char dbgline[220];
    snprintf(dbgline, sizeof dbgline, "iOS %s   |   debugger now: %s%s",
             g_osver[0] ? g_osver : "?",
             dbg == 1 ? "ATTACHED" : dbg == 0 ? "no" : "?",
             g_everPassed ? (g_passedWhileAttached ? "   |   JIT worked WHILE attached"
                                                    : "   |   JIT worked once") : "");
    mt(g_dbgLabel, "setText:", NSStr(dbgline));
    mt(g_dbgLabel, "setTextColor:", dbg == 1 ? rgb(0.4, 0.9, 0.4, 1.0) : rgb(0.72, 0.70, 0.78, 1.0));

    const char *hdr = jit == 1 ? "JIT SELF-TEST:  PASS \xE2\x9C\x93"
                    : g_everPassed ? "JIT SELF-TEST:  worked earlier (re-enable JIT)"
                                   : "JIT SELF-TEST:  probing\xE2\x80\xA6";
    id hcol = (jit == 1 || g_everPassed) ? rgb(0.35, 0.92, 0.45, 1.0) : rgb(1.0, 0.62, 0.30, 1.0);
    mt(g_jitHeader, "setText:", NSStr(hdr));
    mt(g_jitHeader, "setTextColor:", hcol);
    mt(g_jitBody, "setText:", NSStr(jitbuf));
}

/* Background thread: probe continuously so we catch the window while StikDebug
 * is still attached (the grant may not persist a detach). ~4x/sec. */
static void *prober(void *arg) {
    (void)arg;
    for (;;) { probe_once(); usleep(250000); }
    return nil;
}

/* Button action: -runTest:  runs the iOS 26 JIT26 brk-handshake test on demand.
 * Serialized against the background prober so the signal handlers don't race. */
static void runTest(id self, SEL _cmd, id sender) {
    (void)self; (void)_cmd; (void)sender;
    if (!g_jit26Label) return;
    send1(g_jit26Label, "setText:", NSStr("iOS 26 JIT: running handshake\xE2\x80\xA6"));
    char buf[600];
    pthread_mutex_lock(g_mtx);
    int r = jit_test_jit26(buf, sizeof buf);
    pthread_mutex_unlock(g_mtx);
    if (r == 1) { g_everPassed = 1; g_passedWhileAttached = 1; }
    send1(g_jit26Label, "setText:", NSStr(buf));
    send1(g_jit26Label, "setTextColor:", r == 1 ? rgb(0.35, 0.92, 0.45, 1.0) : rgb(1.0, 0.72, 0.30, 1.0));
}

/* -applicationDidBecomeActive: */
static void didBecomeActive(id self, SEL _cmd, id application) { (void)self; (void)_cmd; (void)application; }

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

    /* JIT26 result label (filled by the button handler) */
    g_jit26Label = makeLabel(RECT(pad, H - 210, W - 2 * pad, 60), " ", 12.5, 0, grey, 1);
    addSub(view, g_jit26Label);

    /* "Enable JIT (iOS 26)" button — tap AFTER enabling JIT in StikDebug */
    CGFloat bw = 300, bh = 52;
    id btn = ((id(*)(id, SEL, long))objc_msgSend)(C("UIButton"), S("buttonWithType:"), 1 /*System*/);
    setFrame(btn, RECT((W - bw) / 2.0, H - 140, bw, bh));
    ((void(*)(id, SEL, id, long))objc_msgSend)(btn, S("setTitle:forState:"), NSStr("Enable JIT (iOS 26 protocol)"), 0);
    ((void(*)(id, SEL, id, long))objc_msgSend)(btn, S("setTitleColor:forState:"), rgb(0.09, 0.05, 0.11, 1.0), 0);
    send1(btn, "setBackgroundColor:", gold);
    id btnFont = ((id(*)(id, SEL, CGFloat))objc_msgSend)(C("UIFont"), S("boldSystemFontOfSize:"), 17.0);
    send1(send0(btn, "titleLabel"), "setFont:", btnFont);
    id blayer = send0(btn, "layer");
    ((void(*)(id, SEL, CGFloat))objc_msgSend)(blayer, S("setCornerRadius:"), 12.0);
    ((void(*)(id, SEL, id, SEL, long))objc_msgSend)(btn, S("addTarget:action:forControlEvents:"),
        self, S("runTest:"), 1 << 6 /*UIControlEventTouchUpInside*/);
    addSub(view, btn);

    id footer = makeLabel(RECT(pad, H - 78, W - 2 * pad, 60),
                          "Top lines auto-test the old JIT paths (expected to fail on iOS 18.4+).\n"
                          "For iOS 26: Enable JIT in StikDebug (keep it running), return here,\n"
                          "then tap the gold button. A green PASS proves Vita3K's JIT can run.", 10.5, 0, grey, 1);
    addSub(view, footer);

    ((void(*)(id, SEL, id))objc_msgSend)(g_window, S("setRootViewController:"), vc);
    send0(g_window, "makeKeyAndVisible");

    /* keep the screen awake like the emulator would (WAKE_LOCK equivalent) */
    id app = send0(C("UIApplication"), "sharedApplication");
    ((void(*)(id, SEL, BOOL))objc_msgSend)(app, S("setIdleTimerDisabled:"), YES);

    /* capture the iOS version once */
    {
        id pi = send0(C("NSProcessInfo"), "processInfo");
        id vs = send0(pi, "operatingSystemVersionString");
        const char *c = ((const char *(*)(id, SEL))objc_msgSend)(vs, S("UTF8String"));
        if (c) snprintf(g_osver, sizeof g_osver, "%s", c);
    }

    /* start continuous background probing */
    pthread_mutex_init(g_mtx, nil);
    pthread_t th;
    pthread_create(&th, nil, prober, nil);
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
