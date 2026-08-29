# Vita3K → iOS port — status

Goal: a real, native Vita3K PlayStation Vita emulator running on iOS/iPadOS,
sideloaded, JIT-enabled via StikDebug — able to boot and play games.

Everything here is cross-built **on Linux** with a real iPhoneOS 16.5 SDK +
clang 18 / lld. No Xcode, no macOS. See `toolchain/ios-arm64.cmake`.

## The JIT reality (foundation — must hold or nothing runs)

The target iPad is an A15+/M-series (TXM/SPTM) device on iOS 18.4–26. Apple
removed the classic sideload-JIT model there: `CS_DEBUGGED` alone no longer
lets an app execute self-written pages. The surviving path is StikDebug's
**JIT26 `brk #0xf00d` handshake** — the app asks the attached debugger to
prepare each executable region (see `../ios-conversion/src/main.m`, build 7).
Confirming this executes on the user's device is the gate for the whole port.

Consequence for the emulator: dynarmic allocates its code cache on demand,
which is incompatible with the "prepare-while-attached, then detach" model.
The JIT allocator must be reworked to a **fixed, pre-prepared code arena**
allocated while StikDebug is attached (task: patch oaknut/dynarmic).

## Progress

| Component | Status |
|---|---|
| iOS cross-toolchain (clang + lld + real SDK) | ✅ compiles & links real C++ (libc++/STL) to arm64 Mach-O |
| **dynarmic (ARM dynamic recompiler — the JIT core)** | ✅ **cross-compiles to `libdynarmic.a` (arm64 Mach-O, 119 objects)** — the hardest, riskiest piece builds |
| oaknut ARM64 emitter | ✅ builds (bundled in dynarmic) |
| Boost (header-only, for dynarmic) | ✅ isolated headers wired |
| JIT allocator patched for iOS 26 (JIT26 + pre-prepared arena) | ⬜ next |
| **FFmpeg (avcodec/avformat/avutil/swscale/swresample)** | ✅ **cross-built from source, n6.1, H.264/AAC/MP3** (no iOS prebuilt exists — done the hard way) |
| **OpenSSL 3.3.2 (libssl/libcrypto)** | ✅ built |
| **libcurl 8.11.0** | ✅ built (Apple Secure Transport TLS, self-contained) |
| **boost::filesystem + system** | ✅ compiled from source |
| SDL3 (iOS/UIKit) | ⬜ (upstream supports iOS) |
| MoltenVK (Vulkan→Metal) | ✅ prebuilt ios-arm64 `libMoltenVK.a` + Vulkan headers staged |
| **SPIRV-Cross (shader translation, incl. MSL→Metal backend)** | ✅ **cross-compiles to 8 arm64 Mach-O libs (core/glsl/hlsl/msl/cpp/reflect/util/c)** |
| **glslang (GLSL→SPIR-V front-end)** | ✅ builds (libglslang.a + resource-limits) |
| **SDL3 (windowing/input/audio)** | ✅ **builds with the real UIKit/iOS backend** (uikitappdelegate/video/metalview/vulkan + Metal renderer) |
| **capstone (disassembler)** | ✅ builds (needs CAPSTONE_BUILD_MACOS_THIN=ON to avoid a universal2 build) |
| **fmt / spdlog / yaml-cpp / pugixml** | ✅ all build for arm64-ios |
| builtin SPIR-V shaders | ✅ reusable verbatim from APK |
| **Dependency tree (all 28 libs)** | ✅ **COMPLETE — every Vita3K dependency cross-compiles for arm64-iOS** (staged in `/home/user/ios-deps`) |
| Vita3K core static lib (`libVita3K`) | ⬜ next: make Vita3K's own CMake iOS-aware, then compile |
| Headless "core boots" on device | ⬜ |
| **iOS front-end (touch UI, game loading, controls)** | 🟡 **scaffold builds & runs**: `Vita3K.ipa` — Library/Settings/About tabs, .vpk/.pkg import, full on-screen Vita gamepad, Enable-JIT button, core-bridge with weak core hook. Emulator core not yet wired. |

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
new iOS front-end. iOS 26 additionally penalizes JIT reliability (it revokes
execute on idle JIT pages), so even a complete port may be imperfect on the
newest iOS. "Boots and plays" is the goal; Uncharted: Golden Abyss specifically
is a hard title even on desktop Vita3K.
