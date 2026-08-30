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

// vita3k/ios/ios_jit_arena.h — the single pre-prepared executable arena that
// makes dynarmic's JIT usable on a sideloaded iOS 26/27 build.
//
// WHY THIS EXISTS
// ----------------
// Since iOS 18.4 (and unconditionally on 26/27, where TXM/SPTM enforcement
// covers essentially all hardware) a sideloaded, ad-hoc-signed app cannot
// make its own pages executable: MAP_JIT is EPERM without the allow-jit
// entitlement, and mmap(PROT_EXEC) / mprotect(PROT_EXEC) / a naive
// vm_remap dual-map all SIGBUS on first execute, even with CS_DEBUGGED set
// (measured on-device, iPadOS 27.0.0). The only route that actually works
// is StikDebug's JIT26 `brk #0xf00d` handshake -- and it is a ONE-SHOT
// PER ATTACH protocol: JIT26PrepareRegion() only succeeds while the
// debugger is attached, and calling JIT26Detach() ends that window for
// good. A second PrepareRegion after Detach() reliably reports "no region
// (faulted)" -- also measured on-device, twice over.
//
// dynarmic, however, is written to allocate its JIT code cache on demand,
// and Vita3K constructs one dynarmic::A32::Jit (and therefore one
// oaknut::CodeBlock, i.e. one independent code cache) PER GUEST THREAD
// (kernel/src/thread.cpp -> cpu/src/cpu.cpp:init_cpu -> DynarmicCPU::make_jit).
// A Vita game can have dozens of live threads. Both of those are
// fundamentally incompatible with a one-shot, prepare-while-attached
// executable-memory source.
//
// THE FIX
// -------
// 1. Once, at startup, while still CS_DEBUGGED: prepare ONE big executable
//    region via JIT26PrepareRegion(NULL, bytes) (retrying at half the size
//    if the debugger declines/faults/times out), mach_vm_remap a writable
//    alias over the *same physical pages*, mach_vm_protect that alias
//    RW, run a tiny guarded execute self-test through it, then call
//    JIT26Detach() exactly once. See Init() / DoInit().
// 2. For the rest of the process's life, every oaknut::CodeBlock on iOS
//    (i.e. every guest thread's dynarmic code cache) draws a fixed-size
//    SLOT out of that single arena instead of calling mmap -- see
//    SlotAlloc()/SlotFree() below and the TARGET_OS_IPHONE branch of
//    oaknut::CodeBlock in externals/oaknut/include/oaknut/code_block.hpp.
//    No executable memory is ever requested again after step 1.
// 3. Within a slot, dynarmic already does the right thing on its own:
//    AddressSpace::Emit() resets (ClearCache(), a bump-pointer rewind) the
//    slot's own code once its remaining space drops below 1 MiB, rather
//    than asking for more memory. Nothing here needs to change that.
//
// The public v3k_ios_jit_* C ABI below is also declared, verbatim, in the
// front-end's ios-port/app/src/JitArena.h (and defined nowhere but here --
// see ios_jit_arena.cpp). Do not change these eight signatures without
// updating that header and jitarena_stub.c's fallback definitions too.
#pragma once

#include <cstddef>
#include <cstdint>

// ===========================================================================
// Public, process-wide arena ABI (mirrors ios-port/app/src/JitArena.h)
// ===========================================================================
#ifdef __cplusplus
extern "C" {
#endif

/// Sentinel v3k_ios_jit_init() cannot itself return (this translation unit
/// IS the implementation) -- kept here only so callers that pull in just
/// this header, rather than the app's JitArena.h, see the same constant.
#ifndef V3K_JIT_NO_IMPL
#    define V3K_JIT_NO_IMPL (-999)
#endif

/// Prepares the arena. MUST be called while StikDebug is attached (process
/// is CS_DEBUGGED). `bytes` == 0 selects the default size (see
/// vita3k::ios_jit::kDefaultArenaBytes below). Idempotent: once an attempt
/// has completed (success or failure) every later call returns that same
/// result immediately without touching the brk again -- the handshake
/// cannot succeed a second time in one process, so retrying it is not a
/// recovery path, only a second way to fail. Returns 0 on success, a
/// negative value on failure. Never crashes, even when not debugged at all.
int v3k_ios_jit_init(unsigned long bytes);

/// 1 once the arena is mapped AND a guarded execute self-test through it
/// passed; 0 otherwise (never debugged, brk declined/faulted/timed out,
/// remap/protect failed, or init() was never called).
int v3k_ios_jit_ready(void);

/// Base of the executable view of the arena. NULL if not ready. This is
/// the address JIT'd code actually runs from -- oaknut's CodePtr values,
/// dynarmic's block_entries, the fastmem exception handler's PC range
/// checks, and DumpDisassembly() all live in this address space.
void *v3k_ios_jit_rx(void);

/// Base of the writable alias of the *same physical pages*. NULL if not
/// ready. All code emission (oaknut's CodeGenerator::append) writes here;
/// nothing ever executes here, and this view's permissions never change.
void *v3k_ios_jit_rw(void);

/// Total usable arena size in bytes (whatever size actually got blessed,
/// after any halving retries -- may be less than what was requested).
unsigned long v3k_ios_jit_size(void);

/// Bytes currently handed out across all live per-thread slots. For the
/// UI/HUD; also a rough fill-level gauge for diagnosing thread-count vs.
/// slot-count pressure (see kDefaultSlotBytes below).
unsigned long v3k_ios_jit_used(void);

/// Resets the arena's slot free-list to a single free block spanning the
/// whole arena and invalidates the whole executable range's icache.
/// DANGEROUS: only safe to call when no oaknut::CodeBlock (i.e. no
/// DynarmicCPU / guest thread) currently holds a live slot -- e.g. between
/// unloading one title and booting the next, with all CPU threads torn
/// down. This is a manual, whole-arena reset for recovery/diagnostics; the
/// per-slot, per-thread cache reuse that happens continuously during
/// normal execution is entirely dynarmic's own AddressSpace::ClearCache()
/// (a bump-pointer rewind within a slot) and needs no help from here.
void v3k_ios_jit_flush(void);

/// Stable, NUL-terminated, single-line status string for the UI. Never
/// NULL. Describes exactly why init failed when it failed.
const char *v3k_ios_jit_status(void);

#ifdef __cplusplus
}  // extern "C"
#endif

// ===========================================================================
// Internal per-CodeBlock slot ABI, consumed by oaknut's iOS CodeBlock branch
// ===========================================================================
//
// oaknut/dynarmic are an independent, standalone-buildable external project
// (see ios-port/build-dynarmic.sh) and must not gain a build-time dependency
// on the vita3k source tree, so externals/oaknut/include/oaknut/code_block.hpp
// does NOT include this header -- it forward-declares these two functions
// itself, with an identical extern "C" signature, and only vita3k/ios's own
// build links a definition (from ios_jit_arena.cpp) in. Both declarations
// must be kept in sync by hand; a signature mismatch is a silent ABI bug
// that only shows up as a linker- or runtime-level crash, not a compile
// error, since C linkage does no argument-type checking across translation
// units. This header's copy is authoritative; treat any drift in
// code_block.hpp's copy as a bug in code_block.hpp.
#ifdef __cplusplus
extern "C" {
#endif

/// Carves a `size`-byte slot out of the arena for one oaknut::CodeBlock.
/// On success returns nonzero and fills *out_wptr / *out_xptr with the
/// writable-alias / executable-view base of that slot (both point to
/// exactly `size` usable bytes, at the *same* offset in their respective
/// views). Returns 0 (leaving both pointers untouched) if the arena was
/// never readied, or has no `size`-byte contiguous run left in its free
/// list. Thread-safe. Never mmaps, never mprotects -- pure bookkeeping
/// over memory obtained once in Init().
int v3k_ios_jit_slot_alloc(unsigned long size, uint32_t **out_wptr, uint32_t **out_xptr);

/// Returns a slot obtained from v3k_ios_jit_slot_alloc (identified by the
/// xptr it returned, plus the same size) to the free list, coalescing with
/// neighbouring free blocks. Safe to call with xptr == NULL (no-op) so a
/// CodeBlock whose constructor never got a slot can destruct unconditionally.
void v3k_ios_jit_slot_free(uint32_t *xptr, unsigned long size);

#ifdef __cplusplus
}  // extern "C"
#endif

// ===========================================================================
// C++ convenience surface for Vita3K core code (cpu/src/*.cpp)
// ===========================================================================
#ifdef __cplusplus
namespace vita3k::ios_jit {

/// Default whole-arena size if v3k_ios_jit_init(0) is used. Matches the
/// front end's own kV3KArenaBytes (ios-port/app/src/Vita3KCore.m) so the
/// two constants stay in one conceptual place even though they currently
/// live in two files -- the app always passes its constant explicitly, so
/// this default only matters for callers (tests, tools) that pass 0.
inline constexpr unsigned long kDefaultArenaBytes = 128ul << 20;  // 128 MiB

/// Smallest arena Init() will settle for before giving up (halving retries
/// stop here). Below this a handful of guest threads would immediately
/// exhaust the arena, so failing outright and surfacing a clear status
/// string is more useful than "succeeding" into an unusable arena.
inline constexpr unsigned long kMinArenaBytes = 16ul << 20;  // 16 MiB

/// Per-thread dynarmic code_cache_size DynarmicCPU::make_jit() requests on
/// iOS (see cpu/src/dynarmic_cpu.cpp's TARGET_OS_IPHONE branch). At the
/// default 128 MiB arena this allows 32 concurrently-JIT-ing guest threads
/// before slot allocation starts failing; a game with more live CPU-bound
/// threads than that will fail to create further CPU contexts (see
/// cpu.cpp's init_cpu(), which now catches that and refuses cleanly rather
/// than crashing) rather than silently corrupting or growing the arena.
/// Intra-cache B/BL relocations are +-128 MiB per oaknut's encoding, so
/// this is nowhere near that ceiling -- the constraint here is arena
/// capacity divided by thread count, not branch reach.
inline constexpr unsigned long kDefaultSlotBytes = 4ul << 20;  // 4 MiB

/// Thin, inline wrappers around the C ABI above for call sites that would
/// rather not spell out v3k_ios_jit_* directly. Behave identically.
inline bool Init(unsigned long bytes = 0) { return v3k_ios_jit_init(static_cast<unsigned long>(bytes)) == 0; }
inline bool Ready() { return v3k_ios_jit_ready() != 0; }
inline void *ExecBase() { return v3k_ios_jit_rx(); }
inline void *WriteBase() { return v3k_ios_jit_rw(); }
inline size_t Size() { return static_cast<size_t>(v3k_ios_jit_size()); }
inline size_t Used() { return static_cast<size_t>(v3k_ios_jit_used()); }
inline const char *Status() { return v3k_ios_jit_status(); }

}  // namespace vita3k::ios_jit
#endif
