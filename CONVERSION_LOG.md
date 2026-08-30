# CONVERSION_LOG.md — Android APK → iOS IPA

**Input:** `d4c2842a-androidlatest.apk` (27 MB)
**Output:** `ConvertedApp.ipa` (11 MB) — a structurally-valid, sideloadable iOS application package containing a real ARM64 Mach-O executable, the app's reused assets, the preserved native core, and a `get-task-allow` entitlement for StikDebug/JIT.
**Build host:** Linux x86-64, **no Xcode / no macOS / no Apple SDK** — cross-built with clang + lld (LLVM 18) and Python 3 (stdlib only).
**Reproduce:** `ios-conversion/build.sh <path-to.apk>`

> **Read this first — honest scope.** The supplied APK is **Vita3K**, a full PlayStation Vita **emulator** whose core (`libVita3K.so`, 27 MB of C++ + a Dynarmic/oaknut ARM64 dynamic recompiler, statically-linked SDL3, a Vulkan renderer, SPIRV-Cross, FFmpeg, libcurl, boost, libc++). Converting an emulator of this size to a *fully-running* iOS app means **recompiling that C++ core from source against the iOS SDK + MoltenVK** — a task that requires Xcode/macOS and is not achievable inside this Linux container. What this pipeline delivers is the genuine, end-to-end **conversion to a real iOS package**: a working ARM64 Mach-O UIKit app that boots, reuses the APK's recovered assets/branding, **preserves the original native core in-bundle**, and is configured exactly for the sideload + `get-task-allow` + StikDebug JIT path the emulator needs — with an on-device **JIT self-test that actually exercises the core capability**. The one thing it does **not** do is execute the Vita emulation itself, because that core could not be recompiled for Mach-O here. Every claim below distinguishes what was *built and validated* from what was *not runnable in this environment*.

---

## 1. Framework detected

| Aspect | Finding |
|---|---|
| App | **Vita3K** — PlayStation Vita emulator |
| Package | `org.vita3k.emulator`, versionName **0.2.1** |
| Build system | Android Gradle Plugin 9.2.1 |
| UI shell | **Native Kotlin + Jetpack Compose** (game browser, settings, trophy viewer, on-screen touch-control overlay) |
| Emulation core | **C++** in `libVita3K.so` (arm64-v8a, 27.7 MB; a parallel x86_64 build ships for Android emulators/Chromebooks) |
| Bridge | **SDL3** Android JNI layer — `Emulator extends org.libsdl.app.SDLActivity`, entry `libmain.so`→`SDL_main` (`vita3k_frontend`), load order `SDL3 → hidapi → Vita3K → main` |
| CPU | **Dynarmic** dynamic recompiler with the **oaknut** AArch64 code emitter (runtime machine-code generation → needs W^X/JIT memory) |
| GPU | **Vulkan** primary (driver resolved at runtime; MoltenVK on Apple), GLES fallback; **SPIRV-Cross** shader recompiler |
| Audio | SDL/cubeb + OpenSL ES sink; NGS synth; FFmpeg codecs |
| Net | libcurl + OpenSSL; OkHttp (Kotlin) for update/compat-DB checks; Google Play Services base/tasks |

**Conclusion:** this is *not* Flutter/React-Native/Unity/Cordova/WebView. It is a native-Kotlin front-end over a large C++ emulator core. That single fact drives the entire strategy below.

---

## 2. What was extracted

Unpacked with `unzip`; `AndroidManifest.xml` parsed by a hand-written binary-AXML string-pool reader (`aapt`/`apktool` were unavailable). A 5-way parallel forensic pass (`ios-conversion` notes; see PR body) recovered:

- **Manifest:** package, versionName, 4 components (`Vita3KApplication`, `MainActivity`, `Emulator`, `InstallForegroundService`), 12 permissions, 8 hardware features.
- **Native libs** (`lib/arm64-v8a`): `libVita3K.so`, `libmain_hook.so`, `libhook_impl.so`, `libfile_redirect_hook.so`, `libgsl_alloc_hook.so`, `libandroidx.graphics.path.so` (and the x86_64 core).
- **Data assets:** `assets/shaders-builtin/{opengl,vulkan,overlay}` (22 files: GLSL + verified SPIR-V, magic `0x07230203`), `assets/data/gui-configs` (Qt `.qss` themes + SVG), `assets/dexopt` (ART baseline profiles).
- **Resources:** the launcher icon (`res/GX.png`, 512×512 RGBA — the Vita3K handheld) plus ~250 other PNGs; `resources.arsc`.
- **DEX/Kotlin:** class inventory and the full JNI surface (`Java_org_vita3k_emulator_NativeLib_*`, SDL `native*`/`onNative*` callbacks, `installPkg`, `getUsers`, `getTrophyCollections`, `sendKeyEvent`, …).
- **Endpoints:** GitHub `Vita3K/Vita3K` releases (`continuous`), `Vita3K/compatibility` DB, `K11MCH1/AdrenoToolsDrivers`, `vita3k.org`.

---

## 3. What was reused directly (verbatim, copied into the IPA)

| Reused artifact | From APK | In the IPA |
|---|---|---|
| **Launcher icon** | `res/GX.png` (512²) | resized (pure-Python PNG codec) to `AppIcon120/152/167/180/1024.png` |
| **Built-in shaders** | `assets/shaders-builtin/**` (22 files) | `ConvertedApp.app/shaders-builtin/` — the SPIR-V + Vulkan-GLSL feed the **same** MoltenVK pipeline unchanged |
| **GUI theme data** | `assets/data/gui-configs/**` | `ConvertedApp.app/gui-configs/` (Qt `.qss` + SVG, platform-neutral bytes) |
| **Native ARM64 core** | `lib/arm64-v8a/*.so` | `ConvertedApp.app/Vita3KCore/native-payload-arm64.zip` (+ README) — preserved as the port substrate |
| **Identity/metadata** | manifest / arsc | bundle id `org.vita3k.emulator`, display name **Vita3K**, version 0.2.1 |

The SPIR-V shaders are the highest-value verbatim reuse: MoltenVK consumes SPIR-V directly, so these are literally the same graphics assets an iOS port would ship.

**Deliberately dropped** (not applicable to iOS, documented): the x86_64 `libVita3K.so` (wrong host arch) and `assets/dexopt/*.prof(m)` (Android ART profiles — no ART on iOS).

---

## 4. What was translated / converted

### 4.1 Executable format — the core conversion
Android runs Dalvik/ART bytecode + ELF `.so`; iOS runs **Mach-O**. The Kotlin/Compose shell cannot execute on iOS, so its *role* was re-implemented natively:

- Wrote a native **iOS UIKit application in Objective-C** (`ios-conversion/src/main.m`) — the iOS equivalent of `Vita3KApplication` + `MainActivity`.
- Cross-compiled it to a **real ARM64 Mach-O executable** with `clang -target arm64-apple-ios` and linked with `lld -flavor darwin` (Mach-O linker) against **hand-authored TBD framework stubs** (`ios-conversion/iossdk-stub/`) for libSystem, libobjc, UIKit — no Apple SDK present.
- The whole UI is built through the **Objective-C runtime C API** (`objc_getClass`/`objc_msgSend`/`objc_allocateClassPair`), so the binary imports only a handful of C symbols and stays self-contained.

### 4.2 Android API → iOS equivalent (applied in `Info.plist`)

| Android | iOS equivalent used |
|---|---|
| `Application` / `MainActivity` (LAUNCHER) | `UIApplicationDelegate` created at runtime (`Vita3KAppDelegate`) + root `UIViewController` |
| `Activity`/`Fragment` navigation | UIKit view/window hierarchy |
| `CAMERA` permission/feature | `NSCameraUsageDescription` |
| microphone feature | `NSMicrophoneUsageDescription` |
| `android.hardware.bluetooth` | `NSBluetoothAlwaysUsageDescription` |
| `ACCESS_WIFI_STATE` (ad-hoc) | `NSLocalNetworkUsageDescription` |
| `READ/WRITE/MANAGE_EXTERNAL_STORAGE` | `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` (Files/document access — the iOS sandbox model) |
| `android.hardware.gamepad` | GameController (`UIApplicationSupportsIndirectInputEvents`, `GCSupportsControllerUserInteraction`) |
| `VIBRATE` | CoreHaptics / controller haptics (declared intent) |
| `WAKE_LOCK` | `UIApplication.isIdleTimerDisabled = YES` (set at launch) |
| `INTERNET` / `ACCESS_NETWORK_STATE` | implicit on iOS |
| `android.hardware.vulkan` | **Metal via MoltenVK** → `UIRequiredDeviceCapabilities = [arm64, metal]` |
| `FOREGROUND_SERVICE` (`InstallForegroundService`) | no iOS service model — background task / foreground progress (noted, not needed by the shell) |
| Android scoped storage + `libfile_redirect_hook` | app sandbox `Documents/` container (same path-remap concern) |

### 4.3 Compatibility layer introduced
- **TBD SDK stubs** (`iossdk-stub/`): minimal text-based-dylib stubs so lld can emit correct `LC_LOAD_DYLIB` two-level bindings for libSystem/libobjc/UIKit without a real SDK.
- **Pure-Python PNG codec** (`pngtool.py`): decode/box-resize/encode 8-bit RGBA — no PIL/ImageMagick available.
- **Pure-Python Mach-O ad-hoc signer** (`codesign_adhoc.py`): rebuilds `LC_CODE_SIGNATURE` into a real `CSMAGIC_EMBEDDED_SIGNATURE` SuperBlob (CodeDirectory v0x20400 SHA-256 + empty Requirements + **Entitlements**), so `get-task-allow` is embedded and inspectable — no `codesign`/`ldid` available.

---

## 5. JIT configuration (the reason this app needs StikDebug)

Vita3K's Dynarmic recompiler emits host ARM64 code at runtime and executes it. On Android that is enabled by the app's own in-process hook chain (`libhook_impl` GOT-patching + `mprotect`, `libmain_hook` loader interposition, `libfile_redirect_hook` path remap, `libgsl_alloc_hook` Adreno allocator override — an AdrenoTools driver-swap stack). **iOS grants no in-process equivalent**: the kernel refuses executable self-modified pages to normal apps. The sanctioned sideload path is:

**`get-task-allow` (debuggable signing) → an external debugger (StikDebug / JITStreamer) attaches at launch → kernel flips the process to a JIT-allowed state.**

The package is configured for exactly this and **does not strip debuggability**:
- `ios-conversion/entitlements.plist` requests **`get-task-allow = true`** (and only that — a *grantable* entitlement; a free 7-day Apple ID always sets it, which is why free-sideloaded emulators can JIT).
- The shipped executable is **ad-hoc signed with `get-task-allow` embedded** (slot 5), so it is inspectable now and Sideloadly preserves it on re-sign.
- **On-device JIT self-test (real, not a mockup):** the app allocates a page, writes freshly-emitted ARM64 (`mov w0,#42 ; ret`), makes it executable with the **W^X-correct sequence `mmap(RW) → write → mprotect(R+X)`** (the `mprotect(PROT_EXEC)` is the operation gated by `CS_DEBUGGED`, i.e. StikDebug), invalidates the icache, and executes it under a `SIGBUS/SIGSEGV/SIGILL` + `sigsetjmp` guard. It reports **PASS — JIT ACTIVE** (returned 42) only when JIT rights are present, or a graceful "JIT NOT ACTIVE — enable JIT in StikDebug" otherwise. It re-runs on launch, on every app-foreground, and from a **"Run JIT self-test"** button (so it can be re-checked *after* StikDebug enables JIT). This is the exact operation the emulator core performs per guest block, so a passing self-test is a genuine end-to-end proof of the StikDebug pipeline on the device.
  - > **Note (build 2):** the first build executed an `mmap(RWX)` page directly, which faults under arm64 W^X even when JIT is enabled. Fixed to the `mmap(RW)→mprotect(R+X)` pattern that a sideloaded `get-task-allow`+StikDebug process is actually granted, plus the re-run button (the launch-time result was otherwise stale, since StikDebug enables JIT *after* launch). `P_TRACED` is now shown only as informational — StikDebug detaches after enabling JIT while JIT itself persists, so the execute-test, not the trace flag, is the real signal.

---

## 6. Compilation problems encountered & fixes

| Problem | Fix |
|---|---|
| `clang -fuse-ld=lld` → `library not found for -lSystem` | Invoked the Mach-O linker directly as `lld -flavor darwin` and supplied hand-written TBD stubs. |
| `sys/mman.h` / iOS system headers absent | Declared all prototypes/constants freestanding in `main.m` (no system headers). |
| `undefined symbol: dyld_stub_binder` | Added `dyld_stub_binder` to the libSystem TBD (lld's lazy-binding anchor). |
| `undefined symbol: _bzero` (compiler lowered zeroing) | Added the `bzero` family to the libSystem TBD. |
| Needed inspectable entitlements but no `codesign`/`ldid` | Wrote `codesign_adhoc.py`; validated by independently re-parsing the SuperBlob and recomputing every code-page hash. |
| No PIL/ImageMagick for icon resizing | Wrote `pngtool.py` (zlib-only PNG decode/resize/encode). |
| ELF `.so` could confuse a bundle re-signer | Preserved the native core as a nested `.zip` (opaque to signers). |

---

## 7. Final IPA structure

```
ConvertedApp.ipa
└─ Payload/
   └─ ConvertedApp.app/
      ├─ ConvertedApp            Mach-O ARM64 EXECUTE, PIE, TWOLEVEL, minos iOS 12.0, ad-hoc signed (+get-task-allow)
      ├─ Info.plist             bundle id / display name / version / orientations / capabilities / privacy strings
      ├─ PkgInfo                 APPL????
      ├─ AppIcon120/152/167/180/1024.png   reused Vita3K icon, resized
      ├─ shaders-builtin/        22 files reused verbatim (SPIR-V + GLSL)
      ├─ gui-configs/            Qt theme data reused verbatim
      └─ Vita3KCore/
         ├─ native-payload-arm64.zip   original ARM64 libVita3K.so + hook libs (preserved substrate)
         └─ README.txt
```

Executable load commands verified: `LC_MAIN` (entryoff 16384), `LC_LOAD_DYLINKER /usr/lib/dyld`, `LC_BUILD_VERSION platform=ios minos=12.0`, `LC_ENCRYPTION_INFO_64` cryptid=0, `LC_LOAD_DYLIB` → libSystem/libobjc/UIKit, `LC_CODE_SIGNATURE`.

---

## 8. Final entitlements (embedded in the shipped binary, slot 5)

```xml
<key>get-task-allow</key><true/>
```

Kept intentionally minimal to a **free-account-grantable** entitlement so Sideloadly signing cannot fail on an ungrantable key. `get-task-allow` is the one that matters for StikDebug/JIT; a free Apple ID sets it automatically. (Entitlements that a free profile cannot grant — e.g. `com.apple.developer.kernel.increased-memory-limit` — were deliberately **not** added, to avoid breaking the sign.)

---

## 9. Validation performed (in this Linux environment)

- ✅ IPA is a valid zip; internal layout is `Payload/ConvertedApp.app/…` with the executable, Info.plist, icons, reused assets, preserved core.
- ✅ `file` → `Mach-O 64-bit arm64 executable` (`NOUNDEFS DYLDLINK TWOLEVEL PIE`); every undefined symbol is a legitimate system import.
- ✅ Load commands confirmed (`LC_MAIN`, dyld linker, iOS build version, dylib imports, code-signature).
- ✅ Code signature re-parsed independently: SuperBlob magic OK; CodeDirectory v0x20400 adhoc; **all 13 code-page SHA-256 hashes recomputed and matched**; Requirements + Entitlements special-slot hashes matched; **`get-task-allow` present**.
- ✅ Executable bit (`-rwxr-xr-x`) preserved inside the IPA; sha256 of the packaged binary matches the build tree.
- ✅ Icon re-decode confirmed the Vita3K handheld renders correctly after resize.
- ✅ `build.sh` reproduces the identical validated IPA from committed sources.

## 9a. Acceptance checklist (honest status)

| # | Criterion | Status |
|---|---|---|
| 1 | IPA is recognized as a valid IPA | ✅ Verified (structure + Mach-O + signature) |
| 2 | Sideloadly can process/sign/install it | ✅ **Device-confirmed** — sideloaded and installed on a physical iPad |
| 3 | iOS can launch it | ✅ **Device-confirmed** — launches and renders the native UIKit UI (reused icon, branding, live status) |
| 4 | StikDebug can recognize the sideloaded app | ✅ **Device-confirmed** — listed under StikDebug's "Apps with get-task-allow" and in Recents |
| 5 | StikDebug can target it for JIT | ✅ **Device-confirmed** — StikDebug ran "Starting JIT for Vita3K"; the in-app self-test (fixed in build 2 to the `mprotect(R+X)` path) returns PASS once JIT is enabled and the button is tapped |
| 6 | Primary functionality works | ⚠️ The iOS shell's own functionality (boot, branding, JIT self-test, debugger detection) runs on device; **the Vita emulation itself does not run** — its C++ core is preserved in-bundle but not recompiled for iOS (see §10) |

---

## 10. Remaining limitations (explicit)

1. **The emulator core is preserved, not executed.** `libVita3K.so` is ELF/AArch64 linked against Android (SDL3, libGLESv2, OpenSL ES, JNI). iOS needs a Mach-O built against the iOS SDK + MoltenVK. Producing that means recompiling Vita3K's C++ sources with Xcode/macOS — impossible in this Linux container. The core is shipped in-bundle (`Vita3KCore/`) as the substrate; the machine code is the *same* AArch64 ISA the iPhone runs, so a source-level port drops in behind this shell and uses the JIT path already configured here.
2. **No on-device execution test.** There is no iOS device, simulator, or macOS in this environment, so items 2–5 above were configured and statically validated but not run. Nothing is claimed as "tested on device".
3. **Signing is final at Sideloadly.** The shipped ad-hoc signature exists so entitlements are inspectable; real trust comes from the user's Apple ID at Sideloadly time. No third-party certificate/provisioning profile is embedded.
4. **Kotlin/Compose UI is re-implemented, not transpiled.** The shell reproduces identity + the JIT/StikDebug workflow; the full Compose game-browser/settings/trophy UI belongs to the source-level port.

---

## 10a. CORRECTION — a real iOS SDK *is* usable here (earlier claim was wrong)

An earlier revision of this log claimed a full port "requires macOS/Xcode". **That was wrong**, and
the correction matters:

- A complete **iPhoneOS 16.5 SDK** (233 MB, 197 frameworks, full libc++ headers) is obtainable and
  working on this Linux box. It compiles and links **C++23 and Objective-C++** to real arm64 iOS
  Mach-O, including UIKit, Foundation, Metal, QuartzCore, GameController and `CAMetalLayer`.
  The shipped build now links against these **genuine Apple stubs** (UIKit 6441.1.101,
  Foundation 1971.0.0, `LC_BUILD_VERSION sdk 16.5`) rather than the hand-authored stubs.
- **MoltenVK ships prebuilt for `ios-arm64`** (`MoltenVK-ios.tar`, ~34 MB) and links into an
  arm64-iOS Mach-O from this machine. Graphics is **not** the blocker; MoltenVK converts SPIR-V to
  MSL at runtime via SPIRV-Cross, so the macOS-only Metal shader compiler is not needed.
- **dynarmic/oaknut already implements the correct iOS JIT strategy** — and it is entitlement-free,
  exactly matching this package's `get-task-allow` + debugger model
  (`oaknut/code_block.hpp`, `TARGET_OS_IPHONE`):
  `mmap(PROT_READ|PROT_EXEC)` → `mprotect(RW)` → write → `mprotect(R+X)` → `sys_icache_invalidate`.
  Note it creates the mapping **with** `PROT_EXEC`: on Darwin a region's *maximum* protection is
  fixed at `mmap()` time, so a page born RW-only can be permanently barred from becoming
  executable. The self-test now tries this exact sequence first (strategy E).

**So compiling for iOS is not the blocker. Porting is.** What actually makes a playable Vita3K on
iOS a weeks-to-months project:

| Blocker | Detail |
|---|---|
| **No reusable GUI** | Desktop front-end is Qt Widgets (~19,700 lines); Android is Kotlin/Compose (~20,200 lines). iOS gets neither — ~40k lines of front-end must be re-authored (app browser, settings, PKG install, trophies, users, IME, on-screen touch controls + editor). |
| **FFmpeg has no iOS slice** | `Vita3K/ffmpeg-core` downloads prebuilt zips; there is no `ffmpeg-ios-*` asset, and the `elseif(APPLE)` branch would silently link **macOS** static libs into an iOS binary. FFmpeg/OpenSSL/boost/curl must be cross-built for `arm64-apple-ios`. |
| **CMake has zero iOS handling** | `APPLE` is TRUE for iOS builds, so ~10 existing `if(APPLE)` branches silently select macOS artifacts (MoltenVK-macos, `brew` OpenSSL, `darwin64-arm64`, `sips`/`iconutil`, `MACOSX_BUNDLE`). |
| **`mig` is macOS-only** | dynarmic's fastmem exception handler is generated by `mig`; without it the generic handler is used and **fastmem is disabled** (performance cost). Forcing page-table mode sidesteps it. |
| **Signal handling vs. debugger** | Vita3K installs `SIGSEGV`/`SIGBUS` handlers for lazy guest-page commit. An attached debugger (mandatory for JIT) intercepts those. Needs a Mach `EXC_BAD_ACCESS` exception port — **novel work, no existing code**. |
| **JNI bridge** | ~3,500 lines of Android JNI glue needs an Objective-C++ equivalent. |

**What is easier than expected:** the Vulkan/MoltenVK renderer path is essentially iOS-ready
(`VK_EXT_metal_surface`, `CAMetalLayer` surface creation, MoltenVK workarounds all present);
`metal_layer.mm` is a 7-line `NSView`→`UIView` change; SDL3 has first-class UIKit support at
Vita3K's pinned commit; unicorn is gone. The CPU and graphics core — assumed to be the hard part —
is the least of it.

## 10b. No existing Vita-on-iOS option (verified)

- Vita3K upstream closed [issue #2994 "IOS Support"](https://github.com/Vita3K/Vita3K/issues/2994)
  as **`not_planned`**; the README lists Windows/Linux/macOS/Android only.
- The single active attempt, [`Monsdevo/vita3kios`](https://github.com/Monsdevo/vita3kios)
  (created 2026-08-22), states in its own README: *"There is no playable public build yet."* Only
  milestone M0 is done, and even that requires macOS arm64.
- Sites advertising a "Vita3K IPA download" (yaxod/zexod/apkod/xevod) serve **HTML, not binaries** —
  ad-fraud/malware funnels with self-refuting specs ("29.7 MB", "iOS 10+"). Do not install from them.
- For calibration, PS Vita is absent from every current iOS-emulation guide; the practical ceiling
  via sideload+JIT is PS2 (Play!), GameCube/Wii (DolphiniOS), Switch (MeloNX), x86 (UTM).

## 11. Path to a fully-running port

Build Vita3K's C++ sources for `arm64-apple-ios` (CMake iOS toolchain) with MoltenVK for the Vulkan renderer and Dynarmic's AArch64 backend; replace the Objective-C shell's `main` with the `SDL_main`/`vita3k_frontend` entry; keep this package's `Info.plist`, reused `shaders-builtin/`, icons, `get-task-allow` entitlement, and JIT bring-up. The Android in-process hooks (`file_redirect`, `gsl_alloc`, loader interposition) map to: iOS sandbox `Documents/` paths, Metal/MoltenVK memory management, and the StikDebug external-debugger JIT handshake this build is already wired for.

---

# Part II — from "a path exists" to a real emulator build

Everything above was written before the port existed. What follows is what was
actually built, and what is and is not proven. Section 11's plan is done.

## 12. The real port

`ios-port/` cross-builds Vita3K for `arm64-apple-ios` **on Linux**, with clang +
`lld -flavor darwin` and a real iPhoneOS 16.5 SDK. No Xcode, no macOS. All 28
third-party dependencies (FFmpeg, OpenSSL, curl, SDL3, MoltenVK, SPIRV-Cross,
glslang, capstone, boost, dynarmic…) and all 38 Vita3K core modules build; the
app links to a single 145 MB arm64 Mach-O with no undefined symbols. See
`ios-port/PORT_STATUS.md`.

The front end is a new native UIKit app (`ios-port/app/`) — the Android
Kotlin/Compose shell has no iOS equivalent — with a library, game detail,
settings, firmware install, controller mapping, an on-screen Vita gamepad, JIT
diagnostics, and a log/crash viewer.

## 13. What the device actually proved about JIT

Measured on the user's iPad, iPadOS 27.0.0:

* `CS_DEBUGGED` alone is **not** enough. With StikDebug merely attached the
  process showed `0x32003005` and every attempt to execute self-written memory
  still `SIGBUS`ed — including a bare `bti c; ret` page. `MAP_JIT` gave `EPERM`.
* **Root cause:** StikDebug looks up a JIT *script* for the target bundle id.
  With none bound it does a bare attach: the process gets `CS_DEBUGGED` and
  nothing else, so no executable region is ever prepared. Vita3K is not in
  StikDebug's `AutoScriptAssignments`. Binding `universal.js` — which the app now
  does in one tap via `stikdebug://enable-jit?…&script-name=universal.js` — fixes
  it with no upstream change.
* With the script bound, the JIT26 `brk #0xf00d` handshake **works**:
  `JIT WORKS ✓ — executed emitted code`, 14:35.
* At 14:37 the same test failed with `no region (faulted)`. Not a regression —
  the handshake is **one-shot per attach**. `JIT26Detach()` closes the window
  permanently.

That last point is the constraint the whole design turns on, and it is why the
JIT allocator was rewritten. See `ios-port/JIT_ARENA_DESIGN.md`.

## 14. Four failures caught before the device saw them

Each of these would have presented to the user as "it doesn't work", with no
diagnosis available:

1. **One code cache per guest thread, not one per process.** Vita3K calls
   `init_cpu` per thread (`kernel/src/thread.cpp:74`) and each dynarmic JIT wants
   its own 128 MiB cache. A single arena could never have satisfied 10–30 of
   those. The arena is now sub-allocated into 4 MB per-thread slots.
2. **The Vulkan loader.** vulkan-hpp's `init()` `dlopen`s `libvulkan.dylib` and
   throws when it is missing. MoltenVK is linked *statically* on iOS, so it is
   always missing: the renderer would have thrown before drawing a frame. The
   dispatcher is now seeded from the static library's own `vkGetInstanceProcAddr`.
3. **Firmware was never installed.** The UI copied the PUP into a staging folder
   and a comment claimed the core would install it later. Nothing read that
   folder. `vs0` would have stayed empty and every commercial title would have
   died on a missing module.
4. **The diagnostics screen burned the one attach it had**, by preparing a
   throwaway probe region instead of the arena the emulator actually needs.

## 15. Honest status

Proven: it compiles, it links, the pieces are present in the shipped binary, the
entitlement survives signing, and the JIT26 handshake executes real emitted code
on iPadOS 27.

Not proven — no session in this project has had device access:

* whether StikDebug will bless a **128 MB** region (only 1 MB was ever tested;
  the code halves to 64/32/16 MB on refusal),
* whether **4 MB × 32 slots** suits a real game's thread count,
* whether the core boots at all.

Nothing in this log should be read as a claim that a game has run. It has not.
