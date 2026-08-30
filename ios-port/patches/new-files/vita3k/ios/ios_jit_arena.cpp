// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

// ios_jit_arena.cpp — implementation. See ios_jit_arena.h for the design
// rationale; this file is deliberately self-contained (only libc/libSystem/
// Mach + <mutex>/<vector>/<atomic>/<cstdio>), so it has no dependency on the
// rest of the vita3k source tree and no dependency the other direction from
// oaknut/dynarmic either. It is compiled once into the iOS app/core link
// (see ios-port/build-scripts/) as a plain .cpp -- it deliberately does NOT
// import Foundation (this file may end up in the same link as vita3k core
// translation units that define their own `class Ptr`, which collides with
// MacTypes.h's `typedef char *Ptr`; see ios_bridge_apple.mm's header comment
// for the existing precedent of keeping Apple-framework code in its own .mm).
//
// This is plain C++ + POSIX + Mach (libSystem, no Foundation, no
// libdispatch needed): naked-asm brk handshake, sigsetjmp-guarded
// execution, a std::thread worker + condition-variable timeout so a hung
// brk cannot hang the caller, and a small address-ordered free-list
// allocator for the per-thread slots.
#include "ios_jit_arena.h"

#if defined(__APPLE__)
#    include <TargetConditionals.h>
#endif

#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <vector>

#if defined(__APPLE__) && TARGET_OS_IPHONE

#    include <chrono>
#    include <condition_variable>
#    include <thread>

// Plain C headers (not <csetjmp>/<csignal>) to match exactly what
// ios-port/app/src/Vita3KCore.m includes -- that combination is the one
// actually verified to compile and behave correctly in this cross
// toolchain for the same brk/sigsetjmp/siglongjmp pattern.
#    include <setjmp.h>
#    include <signal.h>

#    include <libkern/OSCacheControl.h>
#    include <mach/mach.h>
#    include <sys/mman.h>
#    include <sys/types.h>
#    include <unistd.h>

// Deliberately NOT <dispatch/dispatch.h>: this file is compiled as plain
// C++ (not Objective-C++) by a Linux-hosted clang cross toolchain, where
// Apple Blocks (the `^{ ... }` syntax dispatch_async's block-taking
// overload needs) are not guaranteed to be enabled without -fblocks. The
// worker-thread + timeout below uses only <thread>/<condition_variable>,
// which is standard C++ and already known to work in this toolchain.

namespace {

// ---------------------------------------------------------------------
// mach_vm.h is marked "unsupported" in the public iOS SDK, but the
// symbols themselves are exported by libSystem at runtime (same
// workaround as ios-port/app/src/Vita3KCore.m; keep both in sync).
// ---------------------------------------------------------------------
using mach_vm_address_t = unsigned long long;
using mach_vm_size_t = unsigned long long;
using mach_vm_offset_t = unsigned long long;
extern "C" kern_return_t mach_vm_remap(vm_map_t, mach_vm_address_t *, mach_vm_size_t, mach_vm_offset_t,
    int, vm_map_t, mach_vm_address_t, boolean_t,
    vm_prot_t *, vm_prot_t *, vm_inherit_t);
extern "C" kern_return_t mach_vm_protect(vm_map_t, mach_vm_address_t, mach_vm_size_t, boolean_t, vm_prot_t);
extern "C" kern_return_t mach_vm_deallocate(vm_map_t, mach_vm_address_t, mach_vm_size_t);
extern "C" int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

constexpr unsigned int kCsOpsStatus = 0;
constexpr unsigned int kCsDebugged = 0x10000000u;

// ---------------------------------------------------------------------
// The JIT26 `brk #0xf00d` handshake (StikDebug's iOS 26/27 protocol) and
// its legacy `brk #0x69` predecessor. Naked asm, exactly as verified
// working on-device and as used by ios-port/app/src/Vita3KCore.m -- do not
// "clean up" the calling convention here, StikDebug's debugger script
// matches this exact instruction sequence.
// ---------------------------------------------------------------------
__attribute__((noinline, naked)) void *JIT26PrepareRegion(void *addr, unsigned long len) {
    __asm__ volatile("mov x16, #1\n\t"
                      "brk #0xf00d\n\t"
                      "ret\n\t");
}
__attribute__((noinline, naked)) void JIT26Detach(void) {
    __asm__ volatile("mov x16, #0\n\t"
                      "brk #0xf00d\n\t"
                      "ret\n\t");
}
__attribute__((noinline, naked)) void *JITLegacyPrepare(void *addr, unsigned long len) {
    __asm__ volatile("mov x16, #1\n\t"
                      "brk #0x69\n\t"
                      "ret\n\t");
}

// A brk with no debugger script attached raises SIGTRAP (rather than
// hanging or being silently ignored) on the devices this was tested
// against, but the whole point of this module is that we cannot assume
// that on every StikDebug version/build -- hence *also* the outer
// thread-based timeout below. g_jmp_buf/g_last_signal/SigtrapHandler are
// file-static (internal linkage) so they cannot collide with
// Vita3KCore.m's own identically-named statics even though both end up in
// the same binary.
sigjmp_buf g_jmp_buf;
volatile int g_last_signal;

void SigtrapHandler(int sig) {
    g_last_signal = sig;
    siglongjmp(g_jmp_buf, 1);
}

// Runs `fn` (JIT26PrepareRegion/JITLegacyPrepare) on a detached worker
// thread under a SIGTRAP guard, and gives up after `seconds` if the brk
// never returns -- StikDebug's handshake can genuinely hang when no
// debugger script answers it, and a bare unguarded brk with nothing
// attached kills the process outright. Same shape as
// ios-port/app/src/Vita3KCore.m's prepare_region_guarded() (verified
// on-device), reimplemented with <thread>/<condition_variable> instead of
// libdispatch blocks: this file is plain C++ compiled by a Linux-hosted
// clang cross toolchain, where the `^{ ... }` block syntax GCD's
// block-taking APIs need is not guaranteed to be enabled without
// -fblocks, whereas std::thread is ordinary C++ already proven to work
// here.
//
// On timeout, the worker thread is detached and left running: it may
// still be parked inside the brk indefinitely. Leaking that one thread is
// preferable to blocking app startup forever, and the whole point of this
// module is that it runs at most once per process.
void *RunGuardedOnWorker(void *(*fn)(void *, unsigned long), unsigned long len, double seconds, bool *out_timed_out, bool *out_faulted) {
    *out_timed_out = false;
    *out_faulted = false;

    struct Shared {
        std::mutex mutex;
        std::condition_variable cv;
        bool done = false;
        void *result = nullptr;
        bool faulted = false;
    };
    // Heap-allocated and intentionally never freed on the timeout path --
    // the detached worker thread may still be writing to it arbitrarily
    // far in the future (or, if the brk truly hung, never returns at
    // all). Freeing it out from under that thread would be a use-after-
    // free; a few hundred bytes leaked once per process life is the
    // correct trade here, not a bug.
    auto *shared = new Shared();

    std::thread worker([shared, fn, len] {
        struct sigaction sa {};
        struct sigaction old_action {};
        sa.sa_handler = SigtrapHandler;
        sigaction(SIGTRAP, &sa, &old_action);
        g_last_signal = 0;

        void *result = nullptr;
        bool faulted = false;
        if (sigsetjmp(g_jmp_buf, 1) == 0) {
            result = fn(nullptr, len);
        } else {
            result = nullptr;
            faulted = true;
        }
        sigaction(SIGTRAP, &old_action, nullptr);

        std::lock_guard<std::mutex> lock(shared->mutex);
        shared->result = result;
        shared->faulted = faulted;
        shared->done = true;
        shared->cv.notify_all();
    });
    worker.detach();

    std::unique_lock<std::mutex> lock(shared->mutex);
    const bool finished = shared->cv.wait_for(lock, std::chrono::duration<double>(seconds), [shared] { return shared->done; });
    if (!finished) {
        *out_timed_out = true;
        return nullptr;
    }
    *out_faulted = shared->faulted;
    void *result = shared->result;
    lock.unlock();
    delete shared;  // safe: the worker already finished and will not touch it again
    return result;
}

void *PrepareRegionGuarded(unsigned long len, double seconds, bool legacy, bool *out_timed_out, bool *out_faulted) {
    void *(*trampoline)(void *, unsigned long) = legacy ? &JITLegacyPrepare : &JIT26PrepareRegion;
    return RunGuardedOnWorker(trampoline, len, seconds, out_timed_out, out_faulted);
}

void DetachGuarded() {
    struct sigaction sa {};
    struct sigaction old_action {};
    sa.sa_handler = SigtrapHandler;
    sigaction(SIGTRAP, &sa, &old_action);
    if (sigsetjmp(g_jmp_buf, 1) == 0) {
        JIT26Detach();
    }
    sigaction(SIGTRAP, &old_action, nullptr);
}

// Guarded execute of a tiny self-test placed at `mem` (an executable-view
// pointer). `bti c ; mov w0,#42 ; ret` -- the `bti c` landing pad decodes
// as a NOP on cores without ARMv8.5 BTI, and keeps this valid to branch to
// indirectly if BTI enforcement is ever on for this mapping.
bool GuardedExecuteProbe(void *rx) {
    struct sigaction sa {};
    struct sigaction old_bus {}, old_segv {}, old_ill {}, old_trap {};
    sa.sa_handler = SigtrapHandler;
    sigaction(SIGBUS, &sa, &old_bus);
    sigaction(SIGSEGV, &sa, &old_segv);
    sigaction(SIGILL, &sa, &old_ill);
    sigaction(SIGTRAP, &sa, &old_trap);

    bool ok = false;
    g_last_signal = 0;
    if (sigsetjmp(g_jmp_buf, 1) == 0) {
        using FnT = int (*)(void);
        auto fn = reinterpret_cast<FnT>(rx);
        ok = (fn() == 42);
    } else {
        ok = false;
    }

    sigaction(SIGBUS, &old_bus, nullptr);
    sigaction(SIGSEGV, &old_segv, nullptr);
    sigaction(SIGILL, &old_ill, nullptr);
    sigaction(SIGTRAP, &old_trap, nullptr);
    return ok;
}

// ---------------------------------------------------------------------
// Module state
// ---------------------------------------------------------------------
enum class InitState { NotStarted,
    Ready,
    Failed };

std::mutex g_init_mutex;
InitState g_init_state = InitState::NotStarted;
int g_init_result = V3K_JIT_NO_IMPL;

std::uint32_t *g_rx_base = nullptr;
std::uint32_t *g_rw_base = nullptr;
unsigned long g_arena_size = 0;

char g_status[320] = "not initialized";

void SetStatus(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void SetStatus(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(g_status, sizeof(g_status), fmt, ap);
    va_end(ap);
}

// ---------------------------------------------------------------------
// Slot allocator: address-ordered free list over [0, g_arena_size) with
// coalescing on free. Every oaknut::CodeBlock constructed on iOS draws one
// slot here instead of calling mmap; every CodeBlock destructor returns
// its slot here instead of calling munmap. Protected by its own mutex,
// independent of g_init_mutex (allocation happens continuously while the
// app runs; init happens exactly once at startup).
// ---------------------------------------------------------------------
struct FreeBlock {
    unsigned long offset;
    unsigned long size;
};

std::mutex g_slot_mutex;
std::vector<FreeBlock> g_free_list;  // kept sorted by offset, non-adjacent
std::atomic<unsigned long> g_used_bytes{ 0 };

constexpr unsigned long kSlotAlign = 64;  // arbitrary, cheap; not load-bearing

unsigned long AlignUp(unsigned long v, unsigned long a) {
    return (v + (a - 1)) & ~(a - 1);
}

void SlotFreeListReset() {
    std::lock_guard<std::mutex> lock(g_slot_mutex);
    g_free_list.clear();
    if (g_arena_size > 0) {
        g_free_list.push_back(FreeBlock{ 0, g_arena_size });
    }
    g_used_bytes.store(0, std::memory_order_relaxed);
}

bool SlotAllocLocked(unsigned long size, unsigned long *out_offset) {
    for (size_t i = 0; i < g_free_list.size(); ++i) {
        FreeBlock &b = g_free_list[i];
        if (b.size >= size) {
            *out_offset = b.offset;
            if (b.size == size) {
                g_free_list.erase(g_free_list.begin() + static_cast<long>(i));
            } else {
                b.offset += size;
                b.size -= size;
            }
            return true;
        }
    }
    return false;
}

void SlotFreeLocked(unsigned long offset, unsigned long size) {
    // Insert in address order, then coalesce with adjacent neighbours.
    size_t i = 0;
    while (i < g_free_list.size() && g_free_list[i].offset < offset) {
        ++i;
    }
    g_free_list.insert(g_free_list.begin() + static_cast<long>(i), FreeBlock{ offset, size });

    // Coalesce with the following block.
    if (i + 1 < g_free_list.size() && g_free_list[i].offset + g_free_list[i].size == g_free_list[i + 1].offset) {
        g_free_list[i].size += g_free_list[i + 1].size;
        g_free_list.erase(g_free_list.begin() + static_cast<long>(i) + 1);
    }
    // Coalesce with the preceding block.
    if (i > 0 && g_free_list[i - 1].offset + g_free_list[i - 1].size == g_free_list[i].offset) {
        g_free_list[i - 1].size += g_free_list[i].size;
        g_free_list.erase(g_free_list.begin() + static_cast<long>(i));
    }
}

// ---------------------------------------------------------------------
// One arena-preparation attempt at a given size. Returns true and fills
// in the module state on success. Never called more than once per
// process (guarded by g_init_mutex in v3k_ios_jit_init).
// ---------------------------------------------------------------------
bool DoInit(unsigned long requested_bytes) {
    unsigned int cs_flags = 0;
    if (csops(getpid(), kCsOpsStatus, &cs_flags, sizeof(cs_flags)) != 0 || !(cs_flags & kCsDebugged)) {
        SetStatus("not debugged (CS_DEBUGGED not set) -- enable JIT for this app in StikDebug first");
        return false;
    }

    unsigned long size = requested_bytes ? requested_bytes : vita3k::ios_jit::kDefaultArenaBytes;
    void *rx = nullptr;
    bool used_legacy = false;
    bool any_attempt_faulted = false;

    // Only the JIT26PrepareRegion attempt itself is retried at a smaller
    // size on decline/fault/timeout -- we are still attached at this
    // point (JIT26Detach has not been called yet), so repeating
    // PrepareRegion here is a normal part of the one attach window, not a
    // second attach. A remap/protect failure *after* a successful
    // PrepareRegion is a different kind of failure (the debugger side
    // worked; our own memory management didn't) and is not retried by
    // shrinking, since the size was never the problem.
    while (size >= vita3k::ios_jit::kMinArenaBytes) {
        bool timed_out = false, faulted = false;
        rx = PrepareRegionGuarded(size, 8.0, /*legacy=*/false, &timed_out, &faulted);
        if (rx && rx != reinterpret_cast<void *>(-1)) {
            break;
        }
        any_attempt_faulted = any_attempt_faulted || faulted;
        if (timed_out) {
            // A hung brk likely means no script is attached at all --
            // halving the request will not fix that, so stop retrying
            // JIT26 and fall through to the legacy probe once at the
            // original requested size instead of burning more time.
            break;
        }
        size /= 2;
    }

    if (!rx || rx == reinterpret_cast<void *>(-1)) {
        // Older StikDebug scripts answer a different immediate; try it
        // once, at a conservative fixed size, before giving up entirely.
        bool timed_out = false, faulted = false;
        size = vita3k::ios_jit::kMinArenaBytes;
        rx = PrepareRegionGuarded(size, 4.0, /*legacy=*/true, &timed_out, &faulted);
        used_legacy = rx && rx != reinterpret_cast<void *>(-1);
        any_attempt_faulted = any_attempt_faulted || faulted;
        if (!used_legacy) {
            SetStatus("JIT26 handshake did not yield executable memory (%s) -- "
                      "in StikDebug, long-press this app, Attach Script, universal.js",
                any_attempt_faulted ? "faulted" : "declined/timed out");
            return false;
        }
    }

    // We have a blessed RX region. From here on we always attempt
    // JIT26Detach() exactly once before returning, success or failure,
    // so the process is left in a consistent (detached) state rather
    // than holding the debugger attached indefinitely.
    mach_vm_address_t rw_addr = 0;
    vm_prot_t cur_prot = 0, max_prot = 0;
    const kern_return_t remap_kr = mach_vm_remap(mach_task_self(), &rw_addr, size, 0,
        VM_FLAGS_ANYWHERE, mach_task_self(), static_cast<mach_vm_address_t>(reinterpret_cast<uintptr_t>(rx)),
        /*copy=*/false, &cur_prot, &max_prot, VM_INHERIT_NONE);

    bool remap_ok = remap_kr == KERN_SUCCESS;
    bool protect_ok = false;
    if (remap_ok) {
        protect_ok = mach_vm_protect(mach_task_self(), rw_addr, size, /*set_maximum=*/false,
                         VM_PROT_READ | VM_PROT_WRITE)
            == KERN_SUCCESS;
    }

    bool probe_ok = false;
    if (remap_ok && protect_ok) {
        // bti c ; mov w0,#42 ; ret
        static const std::uint32_t kProbeCode[3] = { 0xD503245Fu, 0x52800540u, 0xD65F03C0u };
        std::memcpy(reinterpret_cast<void *>(static_cast<uintptr_t>(rw_addr)), kProbeCode, sizeof(kProbeCode));
        sys_icache_invalidate(rx, sizeof(kProbeCode));
        probe_ok = GuardedExecuteProbe(rx);
    }

    // Exactly one detach, now that every region we will ever prepare has
    // been prepared (there is only ever this one, whole-arena region).
    DetachGuarded();

    if (!remap_ok) {
        SetStatus("JIT26 prepared %luMB RX@%p but mach_vm_remap failed (kr=%d)", size >> 20, rx, remap_kr);
        return false;
    }
    if (!protect_ok) {
        mach_vm_deallocate(mach_task_self(), rw_addr, size);
        SetStatus("JIT26 prepared %luMB RX@%p, remap ok, but mach_vm_protect(RW) on the alias failed", size >> 20, rx);
        return false;
    }
    if (!probe_ok) {
        mach_vm_deallocate(mach_task_self(), rw_addr, size);
        SetStatus("JIT26 prepared %luMB RX@%p RW@%p but the execute self-test failed "
                  "(wrote via RW, executed via RX, did not get 42 back)",
            size >> 20, rx, reinterpret_cast<void *>(static_cast<uintptr_t>(rw_addr)));
        return false;
    }

    g_rx_base = reinterpret_cast<std::uint32_t *>(rx);
    g_rw_base = reinterpret_cast<std::uint32_t *>(static_cast<uintptr_t>(rw_addr));
    g_arena_size = size;
    SlotFreeListReset();

    SetStatus("arena %luMB ready @rx=%p rw=%p%s (slot size %luMB -> up to %lu concurrent threads)",
        size >> 20, rx, reinterpret_cast<void *>(static_cast<uintptr_t>(rw_addr)),
        used_legacy ? " [legacy brk #0x69]" : "",
        vita3k::ios_jit::kDefaultSlotBytes >> 20,
        vita3k::ios_jit::kDefaultSlotBytes ? (size / vita3k::ios_jit::kDefaultSlotBytes) : 0ul);
    return true;
}

}  // namespace

int v3k_ios_jit_init(unsigned long bytes) {
    std::lock_guard<std::mutex> lock(g_init_mutex);
    if (g_init_state != InitState::NotStarted) {
        // Idempotent: the handshake cannot succeed a second time in this
        // process (see the header comment), so a repeat call just reports
        // the outcome of the one real attempt instead of touching the brk
        // again.
        return g_init_result;
    }
    g_init_state = InitState::Ready;  // provisional; corrected below
    const bool ok = DoInit(bytes);
    g_init_state = ok ? InitState::Ready : InitState::Failed;
    g_init_result = ok ? 0 : -1;
    return g_init_result;
}

int v3k_ios_jit_ready(void) {
    return g_init_state == InitState::Ready ? 1 : 0;
}

void *v3k_ios_jit_rx(void) {
    return g_init_state == InitState::Ready ? g_rx_base : nullptr;
}

void *v3k_ios_jit_rw(void) {
    return g_init_state == InitState::Ready ? g_rw_base : nullptr;
}

unsigned long v3k_ios_jit_size(void) {
    return g_init_state == InitState::Ready ? g_arena_size : 0;
}

unsigned long v3k_ios_jit_used(void) {
    return g_used_bytes.load(std::memory_order_relaxed);
}

void v3k_ios_jit_flush(void) {
    if (g_init_state != InitState::Ready) {
        return;
    }
    SlotFreeListReset();
    sys_icache_invalidate(g_rx_base, g_arena_size);
}

const char *v3k_ios_jit_status(void) {
    return g_status;
}

int v3k_ios_jit_slot_alloc(unsigned long size, uint32_t **out_wptr, uint32_t **out_xptr) {
    if (g_init_state != InitState::Ready || size == 0) {
        return 0;
    }
    const unsigned long aligned = AlignUp(size, kSlotAlign);

    std::lock_guard<std::mutex> lock(g_slot_mutex);
    unsigned long offset = 0;
    if (!SlotAllocLocked(aligned, &offset)) {
        return 0;
    }
    g_used_bytes.fetch_add(aligned, std::memory_order_relaxed);
    *out_wptr = reinterpret_cast<std::uint32_t *>(reinterpret_cast<std::uint8_t *>(g_rw_base) + offset);
    *out_xptr = reinterpret_cast<std::uint32_t *>(reinterpret_cast<std::uint8_t *>(g_rx_base) + offset);
    return 1;
}

void v3k_ios_jit_slot_free(uint32_t *xptr, unsigned long size) {
    if (xptr == nullptr || g_init_state != InitState::Ready) {
        return;
    }
    const unsigned long aligned = AlignUp(size, kSlotAlign);
    const auto offset = static_cast<unsigned long>(reinterpret_cast<std::uint8_t *>(xptr) - reinterpret_cast<std::uint8_t *>(g_rx_base));
    if (offset >= g_arena_size || offset + aligned > g_arena_size) {
        // Not a pointer this allocator handed out -- ignore rather than
        // corrupt the free list.
        return;
    }

    std::lock_guard<std::mutex> lock(g_slot_mutex);
    SlotFreeLocked(offset, aligned);
    // fetch_sub is safe even if it races slightly with a concurrent
    // alloc/free of a different slot; it only feeds the UI/HUD counter.
    unsigned long prev = g_used_bytes.load(std::memory_order_relaxed);
    while (prev >= aligned && !g_used_bytes.compare_exchange_weak(prev, prev - aligned, std::memory_order_relaxed)) {
    }
}

#else  // !(defined(__APPLE__) && TARGET_OS_IPHONE)

// Non-iOS builds (desktop, Android, macOS, iOS Simulator) never call any
// of this -- oaknut::CodeBlock's non-iOS branches use ordinary mmap and
// never reference the arena. These definitions exist purely so a
// full-tree build (or a unit test) that happens to compile this file on
// another platform still links; they are not meant to ever be reached.
int v3k_ios_jit_init(unsigned long) { return V3K_JIT_NO_IMPL; }
int v3k_ios_jit_ready(void) { return 0; }
void *v3k_ios_jit_rx(void) { return nullptr; }
void *v3k_ios_jit_rw(void) { return nullptr; }
unsigned long v3k_ios_jit_size(void) { return 0; }
unsigned long v3k_ios_jit_used(void) { return 0; }
void v3k_ios_jit_flush(void) {}
const char *v3k_ios_jit_status(void) { return "not iOS -- arena not applicable on this platform"; }
int v3k_ios_jit_slot_alloc(unsigned long, uint32_t **, uint32_t **) { return 0; }
void v3k_ios_jit_slot_free(uint32_t *, unsigned long) {}

#endif  // defined(__APPLE__) && TARGET_OS_IPHONE
