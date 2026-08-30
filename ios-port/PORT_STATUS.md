# Vita3K → iOS port — status

Goal: a real, native Vita3K PlayStation Vita emulator running on iOS/iPadOS,
sideloaded, JIT-enabled via StikDebug — able to boot and play games.

Everything here is cross-built **on Linux** with a real iPhoneOS 16.5 SDK +
clang 18 / lld. No Xcode, no macOS. See `toolchain/ios-arm64.cmake`.

## The JIT reality (foundation — must hold or nothing runs)

The target iPad runs **iPadOS 27** (A15+/M-series, TXM/SPTM). Since iOS 18.4,
`CS_DEBUGGED` alone no longer lets an app execute self-written pages; iOS 27
widened TXM-class enforcement to essentially all hardware (StikDebug PR #416,
3.1.6, 2026-06-17), which is why "26.6 and 27 only work with a few apps".

**Root cause of the SIGBUS we measured on device:** StikDebug looks up a JIT
*script* for the target bundle id when enabling JIT. With none attached it does
a BARE attach — the process gets `CS_DEBUGGED` (we measured `0x32003005`) and
nothing else, so no executable region is ever prepared and every execute faults.
Vita3K is not in StikDebug's `AutoScriptAssignments`, so no script was bound.
The user-assigned script map is consulted first, so binding `universal.js`
manually (or via `stikdebug://enable-jit?...&script-name=universal.js`, which
the app now does in one tap) works with no upstream change.

The surviving mechanism is StikDebug's **JIT26 `brk #0xf00d` handshake**
(protocol unchanged for 27): wait for `CS_DEBUGGED`, `JIT26PrepareRegion` every
RX region **while attached**, dual-map a writable alias, `JIT26Detach`, then
write via RW and execute via RX. A `brk` with no script attached crashes the
process, and it can *hang*, so the app runs it on a worker thread under a
SIGTRAP guard with an 8 s timeout and a legacy `brk #0x69` fallback.

**Consequence for the emulator:** regions created *after* detach can never be
made executable. dynarmic allocates its code cache on demand, which is
incompatible with that — so the JIT allocator has been reworked to a **single
fixed, pre-prepared arena** taken while StikDebug is attached. That is done; see
`JIT_ARENA_DESIGN.md`. The load-bearing detail is that it is one code cache per
**guest thread**, not one per process, so the arena is sub-allocated into 4 MB
per-thread slots (32 of them in 128 MB).

## Progress

| Component | Status |
|---|---|
| iOS cross-toolchain (clang + lld + real SDK) | ✅ compiles & links real C++ (libc++/STL) to arm64 Mach-O |
| **dynarmic (ARM dynamic recompiler — the JIT core)** | ✅ **cross-compiles to `libdynarmic.a` (arm64 Mach-O, 119 objects)** — the hardest, riskiest piece builds |
| oaknut ARM64 emitter | ✅ builds (bundled in dynarmic) |
| Boost (header-only, for dynarmic) | ✅ isolated headers wired |
| **JIT allocator reworked for iOS 26/27 (JIT26 + pre-prepared arena)** | ✅ **done** — `vita3k/ios/ios_jit_arena.{h,cpp}` + oaknut/dynarmic patches; per-thread slots; verified present in the linked binary. **Never run on a device.** |
| **FFmpeg (avcodec/avformat/avutil/swscale/swresample)** | ✅ **cross-built from source, n6.1, H.264/AAC/MP3** (no iOS prebuilt exists — done the hard way) |
| **OpenSSL 3.3.2 (libssl/libcrypto)** | ✅ built |
| **libcurl 8.11.0** | ✅ built (Apple Secure Transport TLS, self-contained) |
| **boost::filesystem + system** | ✅ compiled from source |
| MoltenVK (Vulkan→Metal) | ✅ prebuilt ios-arm64 `libMoltenVK.a` + Vulkan headers staged |
| **SPIRV-Cross (shader translation, incl. MSL→Metal backend)** | ✅ **cross-compiles to 8 arm64 Mach-O libs (core/glsl/hlsl/msl/cpp/reflect/util/c)** |
| **glslang (GLSL→SPIR-V front-end)** | ✅ builds (libglslang.a + resource-limits) |
| **SDL3 (windowing/input/audio)** | ✅ **builds with the real UIKit/iOS backend** (uikitappdelegate/video/metalview/vulkan + Metal renderer) |
| **capstone (disassembler)** | ✅ builds (needs CAPSTONE_BUILD_MACOS_THIN=ON to avoid a universal2 build) |
| **fmt / spdlog / yaml-cpp / pugixml** | ✅ all build for arm64-ios |
| builtin SPIR-V shaders | ✅ reusable verbatim from APK |
| **Dependency tree (all 28 libs)** | ✅ **COMPLETE — every Vita3K dependency cross-compiles for arm64-iOS** (staged in `/home/user/ios-deps`) |
| **Vita3K core modules (per-module clang compile, not full CMake yet)** | ✅ **all 38 non-Qt/non-Android core modules compile clean to arm64 Mach-O** (plus `interface.cpp`/`performance.cpp` and 3 header-only interface libs), incl. **renderer** (Vulkan/MoltenVK + GL backends, `.mm` Metal-layer glue), **cpu** (dynarmic integration), gxm, kernel, mem, audio, ctrl, np, packages, touch, and all 216 `modules/` Sce* HLE handlers — 403 objects total. Archived to `.a` in `/home/user/ios-deps/lib/vita3k-core/`. Only `gui-qt` (Qt desktop UI) and `android/jni` (Android bridge) are unbuilt, both out of scope for iOS. See `ios-port/build-scripts/` for the compile driver and `ios-port/patches/` for the source diffs. |
| Vulkan bring-up on iOS (static MoltenVK) | ✅ dispatcher seeded from the statically linked `vkGetInstanceProcAddr`; the `dlopen("libvulkan.dylib")` path that would have thrown on every device is gone |
| On-device diagnostics (crash reporter + log viewer) | ✅ fatal signals and uncaught exceptions are written to `crash.log` before the process dies, classified against the arena; readable and shareable in-app |
| Real top-level CMake iOS build (vs. per-module clang) | ⬜ next |
| Headless "core boots" on device | ⬜ **the current unknown** |
| **iOS front-end (touch UI, game loading, controls)** | 🟢 **builds & runs, feature-rich**: `Vita3K.ipa` — Library (real param.sfo titles, real VPK extraction), Game Detail (metadata, save data, play/delete), Settings, About, First-Run onboarding (JIT guide), Firmware install, Controller mapping (GameController), full on-screen Vita gamepad, Enable-JIT. 12 source files. Emulator core wires in behind the `Vita3KCore` bridge. |

## Reproduce

```bash
ios-port/build-dynarmic.sh     # builds libdynarmic.a for arm64-ios
```

Other deps use the same toolchain, e.g. SPIRV-Cross:
```bash
git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Cross
cmake -S SPIRV-Cross -B build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=$PWD/ios-port/toolchain/ios-arm64.cmake \
  -DSPIRV_CROSS_ENABLE_TESTS=OFF -DSPIRV_CROSS_CLI=OFF
PATH=/home/user/iosbin:$PATH ninja -C build   # -> libspirv-cross-*.a (arm64 Mach-O)
```

Two of the three hard core stacks — CPU/JIT (dynarmic) and graphics-shader
translation (SPIRV-Cross, incl. the Metal/MSL backend) — now build for iOS.
The third hard part (the front-end) is UI engineering, not a build-feasibility
question.

The front-end app:
```bash
ios-port/app/build-app.sh      # -> Vita3K.ipa (real arm64 iOS app you can sideload)
```
It builds all screens + the core bridge, ad-hoc signs with get-task-allow, and
packages an IPA. The emulator core links in behind `Vita3KCore` (the bridge)
via the `vita3k_ios_*` entry points; until then `CoreStub.c` provides
placeholders and the UI runs in "preview" mode.

## Honest assessment

This is a real, multi-session engineering project. The CPU/JIT core — assumed
to be the hard part — now builds for iOS, which is the biggest single
de-risking step. The remaining cost is dependency bring-up and, above all, a
new iOS front-end. On iOS 27 the JIT path is narrow but real: it works only for apps that ask the
attached debugger to bless each executable region up front, with a script bound
in StikDebug. iOS 27 is also still in beta, so this can change at GM. "Boots and plays" is the goal; Uncharted: Golden Abyss specifically
is a hard title even on desktop Vita3K.
