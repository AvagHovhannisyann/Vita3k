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
| FFmpeg / OpenSSL / boost::filesystem / curl (arm64-ios) | ⬜ |
| SDL3 (iOS/UIKit) | ⬜ (upstream supports iOS) |
| MoltenVK (Vulkan→Metal) | ✅ prebuilt ios-arm64 available (34 MB) |
| SPIRV-Cross / glslang / SPIR-V shaders | ⬜ (shaders reusable from APK) |
| Vita3K core static lib | ⬜ |
| Headless "core boots" on device | ⬜ |
| iOS front-end (touch UI, game loading, controls) | ⬜ (~40k lines; neither Qt nor Kotlin UI reusable) |

## Reproduce

```bash
ios-port/build-dynarmic.sh     # builds libdynarmic.a for arm64-ios
```

## Honest assessment

This is a real, multi-session engineering project. The CPU/JIT core — assumed
to be the hard part — now builds for iOS, which is the biggest single
de-risking step. The remaining cost is dependency bring-up and, above all, a
new iOS front-end. iOS 26 additionally penalizes JIT reliability (it revokes
execute on idle JIT pages), so even a complete port may be imperfect on the
newest iOS. "Boots and plays" is the goal; Uncharted: Golden Abyss specifically
is a hard title even on desktop Vita3K.
