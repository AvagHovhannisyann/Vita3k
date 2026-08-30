# RPCS3 → iOS: the JIT memory problem, and why it is tractable

This was the make-or-break question for the whole PS3 port: RPCS3 recompiles the
PPU **and** six SPUs continuously across many threads, while iOS grants a
sideloaded app exactly one window to obtain executable memory (the StikDebug
JIT26 handshake, one-shot per attach — see `ios-port/JIT_ARENA_DESIGN.md`).

I expected to have to rebuild RPCS3's allocator. **I was wrong, and in the good
direction.** Read against the real source, RPCS3's JIT allocator is *already*
the shape iOS needs.

## What RPCS3 actually does (`Utilities/JITASM.cpp`)

`get_jit_memory()` — reserves **once**, as a magic static:

- `utils::memory_reserve(0x80000000, true)` — one 2 GB reservation, made a
  single time for the process.
- Split into two subranges: **code** at offset `0`, **data** at offset
  `0x40000000`. Each capped at 1 GB.

`add_jit_memory<Off, Prot>(size, align)` — a **bump allocator** over that
reservation:

- `Ctr.atomic_op(...)` bumps a counter; low 32 bits are the current position,
  high 32 bits the committed watermark.
- Pages are **committed on demand** in 2 MB steps as the bump pointer advances
  (`utils::memory_commit(pointer + olda, newa - olda, Prot)`).
- Overflow past `0x40000000` fails permanently rather than growing.

`jit_runtime::finalize()` — **resets rather than grows**: decommits the region
and sets `s_code_pos`/`s_data_pos` back to 0.

And critically, `Utilities/JITLLVM.cpp:415-422` — LLVM's own JIT memory manager
(`MemoryManager2::allocateCodeSection` / `allocateDataSection`) funnels straight
into `jit_runtime::alloc(size, align, ...)`. So the LLVM recompiler path and the
asmjit path share **one** allocator. There is one place to adapt, not many.

## Why that matters

Reserve-once + bump + reset-instead-of-grow is precisely the model the iOS
one-shot arena requires, and precisely what we already built for Vita3K's
dynarmic/oaknut. RPCS3 arrived at it independently for its own reasons.

## The four changes iOS needs

1. **Size.** The 1 GB code cap is virtual reservation, not committed memory —
   but StikDebug will not bless anything near it. The arena becomes whatever we
   are granted (Vita3K asks 128 MB and halves on refusal), and the
   `0x40000000` cap becomes the arena size. The bump allocator then simply
   reaches `finalize()` sooner and recycles. Behaviour degrades to "flushes the
   code cache more often", not "fails".

2. **Only the code half needs blessing.** The data subrange at `0x40000000` is
   `protection::rw` — ordinary memory. It can be a plain anonymous mapping,
   completely outside the arena. That halves the demand on the scarce resource,
   and I had not expected that going in.

3. **W^X.** `protection::wx` (simultaneously writable and executable) does not
   exist on iOS. Same fix as oaknut: the arena is mapped twice — RX for
   execution, a `mach_vm_remap` RW alias for writing — and the `std::memcpy`
   that copies emitted sections (`JITASM.cpp`, in `_alloc`'s caller) writes
   through the alias while callers keep the RX address. `pthread_jit_write_protect_np`
   (`JITASM.cpp:315,333`, `JITLLVM.cpp:71,79`, `Thread.cpp:2637`) becomes a
   no-op — it is the macOS model, and iOS does not grant it.

4. **Commit becomes a no-op.** `memory_commit` as the bump pointer advances
   cannot work after detach — but it does not need to: the whole arena is
   already blessed up front. This *simplifies* the path.

## Honest remaining risk

- **How much executable memory a real PS3 game actually needs is unmeasured.**
  RPCS3 reserves 1 GB for code and commits on demand; nobody has published what
  the steady-state committed figure is for a given title, and it will be far
  more than Vita3K's. If a game's working set exceeds our arena, it still runs —
  it thrashes, recompiling more often. Whether that is playable or a slideshow
  is an empirical question I cannot answer from here.
- `MemoryManager1` (`JITLLVM.cpp:220`) is a *second* manager using its own
  `protection::wx` allocations and is chosen in some configurations
  (`JITLLVM.cpp:719,729`). It must be routed to the arena too, or that mode
  disabled on iOS.
- None of this is proven on device. It is a design derived from the source.

## Bottom line

The thing most likely to have made a PS3 port impossible on iOS — an allocator
that demands fresh executable pages while the game runs — turns out not to be
how RPCS3 works. It reserves once and recycles, which is exactly what iOS
permits. That does not make the port easy, and it says nothing about speed, but
it removes the categorical blocker.
