# RPCS3 (PS3) → iOS — port plan

Goal: a second, self-contained emulator inside the same app — one IPA, StikDebug
JIT, loads PS3 disc images (ISO), no external dependencies — mirroring the Vita3K
model. This plan is grounded in reading the **actual RPCS3 source** (cloned at
the pinned HEAD), not internet claims. Every structural claim cites a file.

## Why this is mechanically feasible (from the source, not blogs)

The popular framing is "no PS3 emulator on mobile." That is a statement about
*official support and performance*, not about whether the code can be built for
arm64-iOS. Three findings from the real tree say the port is tractable in the
same way Vita3K was:

1. **The ARM64 code generator already exists and is already exercised on Apple.**
   `Utilities/JIT.h:34-53` selects `asmjit::a64::Assembler` under `ARCH_ARM64`,
   and `Utilities/JITASM.cpp:238` carries an explicit
   `#if !(defined(ARCH_ARM64) && defined(__APPLE__))` guard — RPCS3 has already
   dealt with Apple-Silicon ARM64. We are not inventing a recompiler backend,
   exactly as Vita3K's dynarmic already targeted ARM64.

2. **The executable-memory model is centralized**, so the iOS JIT wall is
   localized surgery, not a tree-wide rewrite. All of it lives in:
   - `rpcs3/util/vm_native.cpp` — `memory_reserve` / `memory_commit` /
     `memory_protect` (lines ~225-424). On Apple this maps with `MAP_JIT`
     (`:258`, `:355`, `:385`).
   - the W^X toggle `pthread_jit_write_protect_np(...)` in `Utilities/JITASM.cpp`
     (`:315`,`:333`), `Utilities/JITLLVM.cpp` (`:71`,`:79`) and
     `Utilities/Thread.cpp` (`:2637`).
   `MAP_JIT` is `EPERM` for a sideloaded app with no JIT entitlement, and the
   `pthread_jit_write_protect_np` model is the macOS one iOS does not grant.
   This is the SAME wall we already climbed for oaknut/dynarmic — replace it
   with the StikDebug pre-prepared arena (`vita3k/ios/ios_jit_arena`).

3. **The GPU path is one we already solved.** RSX has GL and VK backends
   (`rpcs3/Emu/RSX/{GL,VK}`). VK → MoltenVK → Metal is exactly the pipeline the
   Vita3K port already builds and ships; `3rdparty/MoltenVK` is even vendored
   here too. GL is dropped, as it was for Vita3K.

## What is genuinely hard (no optimism)

- **JIT memory pressure is far higher than Vita3K.** RPCS3 recompiles the PPU
  (PowerPC) *and* six SPUs, continuously, across many threads
  (`Emu/Cell/PPUThread.cpp`, `SPULLVMRecompiler.cpp`, `SPUCommonRecompiler.cpp`).
  Our single fixed StikDebug arena, grabbed once at startup, must serve all of
  it. The Vita3K arena (128 MB, 4 MB per-thread slots) is a starting point but
  SPU recompilation alone can dwarf that. Adapting RPCS3's allocator to the
  arena — and making it *reclaim and reuse* rather than grow — is the central
  research risk, harder than the Vita3K version.
- **LLVM is the recompiler backend** (`Utilities/JITLLVM.cpp:97` —
  `InitializeNativeTarget`). A static `libLLVM` for arm64-iOS with only the
  AArch64 target is the long-pole dependency build (large, but a known quantity;
  we already ship LLVM host tooling).
- **Performance is unproven and may be the real ceiling.** Even desktop ARM
  (M-series) struggles with SPU-heavy titles; iOS silicon is below that. "Boots"
  and "plays at a good frame rate" are different claims. We build for the first
  and push toward the second; the second is not guaranteed for every title.

## Dependency reuse (large overlap with the Vita3K iOS deps)

From `3rdparty/`: MoltenVK, glslang, ffmpeg, cubeb, curl, zlib, zstd, libpng,
pugixml, yaml-cpp, SDL — **already cross-built for arm64-iOS** for Vita3K and
reusable. Genuinely new: **LLVM** (heavy), **asmjit** (small), **wolfssl**
(or retarget to the OpenSSL 3 already built), FAudio/OpenAL/SoundTouch (audio,
optional at first), protobuf (build config), opencv (only for camera — stub).

## Scale (honest)

RPCS3 tree excluding 3rdparty: ~635k lines. Of that, `Emu/Cell` (PPU+SPU) 254k,
`Emu/RSX` (GPU) 120k, `Emu/CPU` 18k, `Utilities` 25k, `Emu/Io` 17k; `rpcs3qt`
(desktop UI) 70k is **dropped**, as Qt was for Vita3K. So the core to bring up is
~430k lines — roughly 5-7× the Vita3K core — plus LLVM. This is not "80-100k
lines to author": the emulator already exists. Our new code is the iOS glue:
toolchain, the arena adaptation of the JIT allocator, an `RPCS3Core` bridge like
`Vita3KCore`, ISO mounting, and the second-emulator UI.

## Order of work

1. **Toolchain + deps.** Reuse the Vita3K arm64-ios toolchain. Build the long
   pole (`libLLVM`, AArch64-only, static) and `asmjit`. Reuse the shared deps.
2. **Compile the core per-module** (the Vita3K approach): Cell, RSX/VK, CPU,
   Utilities, Io — clang → arm64 Mach-O, fixing iOS portability as it arises.
3. **JIT arena adaptation.** Route `vm_native.cpp`'s executable reserve/commit
   and the `pthread_jit_write_protect_np` toggle through the StikDebug arena;
   this is the make-or-break step and gets its own design note.
4. **Headless boot** of a simple title; then RSX→Metal on screen.
5. **`RPCS3Core` bridge + UI**: a second emulator in the app, ISO import, its
   own game library, sharing the JIT-enable and diagnostics plumbing.

## Honest bottom line

The source says a build is achievable; the two open questions are whether the
JIT fits the iOS arena and whether real games are fast enough. Neither is
answerable from a desk — both need the device. We build toward "boots", prove
it, then chase speed. No step here depends on trusting anything but the code.
