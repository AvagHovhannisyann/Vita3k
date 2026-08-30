// JitArena.h — the C ABI of the single pre-prepared executable arena.
//
// WHY THIS EXISTS
// ---------------
// On iOS 18.4+ (and universally on 26/27, where TXM/SPTM enforcement covers all
// hardware) a sideloaded app cannot make its own pages executable. The only
// surviving route is StikDebug's JIT26 `brk #0xf00d` handshake, and that route
// is ONE-SHOT: the debugger blesses regions only while it is attached, and the
// app must call JIT26Detach() to resume — after which no further region can ever
// be prepared. We measured exactly this on device (iPadOS 27.0.0): the first
// handshake passes and executes emitted code; a second one in the same process
// reports "no region (faulted)".
//
// dynarmic, however, allocates its code cache on demand while a game runs. That
// is fundamentally incompatible. So the emulator instead grabs ONE large
// executable arena up front, while StikDebug is still attached, dual-maps a
// writable alias of it, detaches once, and then sub-allocates every block of
// recompiled ARM code out of that arena for the rest of the process lifetime.
// When it fills up, the JIT cache is flushed and reused — never re-allocated.
//
// The real implementation lives in the native core (vita3k/ios/ios_jit_arena).
// jitarena_stub.c provides a last-resort definition so the UI-preview build
// links and reports honestly that no arena is available.
#ifndef V3K_JIT_ARENA_H
#define V3K_JIT_ARENA_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Sentinel returned by v3k_ios_jit_init() when no arena implementation is
/// linked in at all (i.e. the stub answered). Distinct from a real failure.
#define V3K_JIT_NO_IMPL (-999)

/// Prepare the arena. MUST be called while StikDebug is attached (the process
/// is CS_DEBUGGED). `bytes` == 0 selects the default size. Idempotent: returns
/// 0 immediately if the arena is already up. Returns 0 on success, a negative
/// value on failure, V3K_JIT_NO_IMPL if no implementation is linked.
int           v3k_ios_jit_init(unsigned long bytes);
/// 1 once rx/rw are valid and the built-in execute self-test passed.
int           v3k_ios_jit_ready(void);
void         *v3k_ios_jit_rx(void);      ///< executable base, NULL if not ready
void         *v3k_ios_jit_rw(void);      ///< writable alias base, NULL if not ready
unsigned long v3k_ios_jit_size(void);    ///< usable bytes
unsigned long v3k_ios_jit_used(void);    ///< bytes handed out so far
void          v3k_ios_jit_flush(void);   ///< reset the bump allocator + icache
/// Stable NUL-terminated one-liner for the UI (never NULL).
const char   *v3k_ios_jit_status(void);

// --- Core-internal: the slot allocator dynarmic's oaknut::CodeBlock calls ---
// The UI never uses these; they are declared here so the fallback definitions
// live beside the rest of the ABI. Each guest thread gets one slot out of the
// single arena (Vita3K builds a recompiler per thread — see
// ios-port/JIT_ARENA_DESIGN.md), with `size` bytes of executable memory at
// *out_xptr and a writable alias of the same bytes at *out_wptr.
/// Returns 0 on success, negative when the arena is absent or exhausted.
int  v3k_ios_jit_slot_alloc(unsigned long size, uint32_t **out_wptr, uint32_t **out_xptr);
/// Return a slot to the free list. `xptr` is the value from slot_alloc.
void v3k_ios_jit_slot_free(uint32_t *xptr, unsigned long size);

#ifdef __cplusplus
}
#endif
#endif
