# The iOS JIT arena — design notes

Every claim here cites a file and line so it can be checked independently
against the sources rather than taken on trust.

## What the device actually told us

On the user's iPad (iPadOS 27.0.0, 2026-08-30 14:35) the in-app JIT test
reported **"JIT WORKS ✓ — JIT26 handshake: PASS — executed emitted code"**.
Two minutes later the same test reported `no region (faulted)`.

That is not a regression, it is the protocol. StikDebug's JIT26 handshake
blesses regions only while the debugger is attached, and `JIT26Detach()`
(`mov x16, #0; brk #0xf00d`) ends that window permanently. Everything below
follows from that one fact:

> **All executable memory this process will ever have must be obtained in a
> single burst, before detach.**

## Why dynarmic cannot be left as-is

`oaknut::CodeBlock`'s iOS branch maps its own memory:

```
externals/oaknut/include/oaknut/code_block.hpp
    m_memory = mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
```

That is exactly the page that SIGBUSes on iOS 18.4+ — and we measured it. It
must instead come from the pre-blessed arena.

## The trap: it is one CodeBlock **per guest thread**, not one

This is the constraint that decides the whole design.

| Fact | Where |
|---|---|
| Vita3K creates a CPU state per guest thread | `vita3k/kernel/src/thread.cpp:74` → `init_cpu(...)` |
| ...which builds a `Dynarmic::A32::Jit` | `vita3k/cpu/src/cpu.cpp:41`, `vita3k/cpu/src/dynarmic_cpu.cpp:335` `make_jit()` |
| ...which builds an `A32AddressSpace` | `dynarmic/backend/arm64/a32_address_space.cpp:158` |
| ...which builds a `CodeBlock(conf.code_cache_size)` | `dynarmic/backend/arm64/address_space.cpp:25` |
| ...and that default is **128 MiB** | `dynarmic/interface/A32/config.h:239` |

A Vita game has on the order of 10–30 live threads. On desktop this is
lazily-committed virtual memory and costs nothing. Against a single blessed
arena it is fatal, because only the first block could ever be blessed.

**So the iOS `CodeBlock` must sub-allocate a fixed slot from the one arena,
with a free list so a destroyed block returns its slot**, and Vita3K must set
`conf.code_cache_size` to the slot size on iOS (`dynarmic_cpu.cpp` ~line 348).

Sizing: arena 128 MB, slot 4 MB → 32 concurrent guest threads. 128 MB is also
the natural ceiling — dynarmic asserts a single code cache cannot exceed it
(`address_space.cpp:28`) because intra-cache branches are `B`/`BL` (±128 MB).

## The good news: only three write sites

oaknut **already** supports a split writable/executable base —
`CodeGenerator(std::uint32_t* wmem, std::uint32_t* xmem)`
(`externals/oaknut/include/oaknut/oaknut.hpp:307`), and `set_xptr`/`xptr`
translate writes from the executable pointer to the writable one. Nothing needs
to be invented; the RX pointer is merely passed twice today:

```
backend/arm64/address_space.cpp:26    , code(mem.ptr(), mem.ptr())
backend/arm64/address_space.cpp:139   CodeGenerator c{mem.ptr(), mem.ptr()};   // Link
backend/arm64/address_space.cpp:279   CodeGenerator c{mem.ptr(), mem.ptr()};   // RelinkForDescriptor
```

Give `CodeBlock` a `wptr()` and pass `{mem.wptr(), mem.ptr()}` at all three.

Also:

* `CodeBlock::protect()` / `unprotect()` `mprotect` the whole block and are
  called on every `Emit` (`address_space.h:54,60`). They must be no-ops on
  `TARGET_OS_IPHONE` — arena memory cannot be re-protected.
* `DumpDisassembly` (`address_space.cpp:101`) only *reads* through `mem.ptr()`;
  RX is readable, so leave it.
* `exception_handler.Register(mem, code_cache_size)` (`address_space.cpp:31`) —
  check it does not assume ownership of the mapping. Fastmem is only enabled
  when the page table is off (`dynarmic_cpu.cpp:343`).

## Already correct, do not "fix"

* **Flush rather than allocate** is dynarmic's existing behaviour:
  `AddressSpace::Emit` calls `ClearCache()` when `GetRemainingSize() < 1 MB`,
  and `ClearCache()` is just `code.set_offset(prelude_info.end_of_prelude)` —
  a bump-pointer reset (`address_space.cpp:92-104,110-112`). No new flush path
  is needed in dynarmic; it only must never *allocate*.
* **Host calls are absolute.** Calls out to the runtime go through trampolines
  emitted into the block itself using `MOVP2R` + `BLR`
  (`a32_address_space.cpp:24-60`), so the arena's distance from the main binary
  is irrelevant.

## The app-facing ABI

Declared in `ios-port/app/src/JitArena.h`, with a last-resort definition in
`jitarena_stub.c` that is linked from its own archive **last** — a linker only
pulls an archive member to resolve a still-undefined symbol, so the core's real
implementation always wins. (A plain weak definition would not work: it
satisfies the reference outright and the real member is never pulled in.)

```
int v3k_ios_jit_init(unsigned long bytes);   // idempotent; 0 ok, V3K_JIT_NO_IMPL if stubbed
int v3k_ios_jit_ready(void);
void *v3k_ios_jit_rx(void), *v3k_ios_jit_rw(void);
unsigned long v3k_ios_jit_size(void), v3k_ios_jit_used(void);
void v3k_ios_jit_flush(void);
const char *v3k_ios_jit_status(void);
```

`v3k_ios_jit_init` must do the whole sequence in one call, while attached:
prepare the arena, `mach_vm_remap` a writable alias, `JIT26Detach()` **once**,
then self-test by executing `mov w0,#42; ret` through the alias. The `brk` runs
on a worker thread under a `SIGTRAP` guard with a timeout, because an
unanswered `brk` can hang or kill the process (the same shape as
`prepare_region_guarded` in `app/src/Vita3KCore.m`). On refusal, halve the
request: 128 → 96 → 64 → 32 MB, and record which size won in the status string.

## What the front-end already does

* Asks for 128 MB via `v3k_ios_jit_init` (`Vita3KCore.m`, `kV3KArenaBytes`).
* Never re-runs the handshake once `v3k_ios_jit_ready()` is 1 — every entry
  point is idempotent.
* Auto-prepares on `applicationDidBecomeActive`, which is the moment the user
  returns from StikDebug and the only window the arena exists in.
* Refuses to boot a title without a ready arena, offering a one-tap Enable JIT
  rather than faulting into a black screen.
* The JIT diagnostics screen prepares and reports the *real* arena. Running a
  throwaway probe region there is what burned the attach and produced the
  second-run failure described at the top.
