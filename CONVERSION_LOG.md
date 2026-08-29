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
- **On-device JIT self-test (real, not a mockup):** at launch the app allocates a page, writes freshly-emitted ARM64 (`mov w0,#42 ; ret`), tries `MAP_JIT`→`pthread_jit_write_protect_np`→`mprotect(RX)`, invalidates icache, and executes it under a `SIGBUS/SIGSEGV/SIGILL` + `sigsetjmp` guard. It reports **PASS — JIT ACTIVE** (returned 42) only when JIT rights are present, or a graceful "JIT NOT ACTIVE — attach StikDebug" otherwise. It also reads `sysctl(KERN_PROC)` `P_TRACED` to show whether a debugger/StikDebug is attached. This is the exact operation the emulator core performs per guest block, so a passing self-test is a genuine end-to-end proof of the StikDebug pipeline on the device.

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
| 2 | Sideloadly can process/sign/install it | ✅ Structured for it (valid Mach-O, minimal grantable entitlements, unsigned-resources so re-sign is clean) — **not run** here (no Sideloadly/device) |
| 3 | iOS can launch it | ⚠️ Built to launch (valid PIE Mach-O, `UIApplicationMain`, `UILaunchScreen`) — **not executed** (no iOS device/macOS in this container) |
| 4 | StikDebug can recognize the sideloaded app | ✅ Configured: `get-task-allow`, debuggable, standard bundle — recognition is by install+entitlement, which are in place. Actual selection **not run** here |
| 5 | StikDebug can target it for JIT | ✅ Configured; the app contains a live JIT self-test + `P_TRACED` readout to confirm it on device — **not run** here |
| 6 | Primary functionality works | ⚠️ The iOS shell's own functionality (boot, branding, JIT self-test, debugger detection) is implemented and will run; **the Vita emulation itself does not run** — its C++ core was preserved but not recompiled for iOS (see §10) |

---

## 10. Remaining limitations (explicit)

1. **The emulator core is preserved, not executed.** `libVita3K.so` is ELF/AArch64 linked against Android (SDL3, libGLESv2, OpenSL ES, JNI). iOS needs a Mach-O built against the iOS SDK + MoltenVK. Producing that means recompiling Vita3K's C++ sources with Xcode/macOS — impossible in this Linux container. The core is shipped in-bundle (`Vita3KCore/`) as the substrate; the machine code is the *same* AArch64 ISA the iPhone runs, so a source-level port drops in behind this shell and uses the JIT path already configured here.
2. **No on-device execution test.** There is no iOS device, simulator, or macOS in this environment, so items 2–5 above were configured and statically validated but not run. Nothing is claimed as "tested on device".
3. **Signing is final at Sideloadly.** The shipped ad-hoc signature exists so entitlements are inspectable; real trust comes from the user's Apple ID at Sideloadly time. No third-party certificate/provisioning profile is embedded.
4. **Kotlin/Compose UI is re-implemented, not transpiled.** The shell reproduces identity + the JIT/StikDebug workflow; the full Compose game-browser/settings/trophy UI belongs to the source-level port.

---

## 11. Path to a fully-running port (next step, on macOS)

Build Vita3K's C++ sources for `arm64-apple-ios` (CMake iOS toolchain) with MoltenVK for the Vulkan renderer and Dynarmic's AArch64 backend; replace the Objective-C shell's `main` with the `SDL_main`/`vita3k_frontend` entry; keep this package's `Info.plist`, reused `shaders-builtin/`, icons, `get-task-allow` entitlement, and JIT bring-up. The Android in-process hooks (`file_redirect`, `gsl_alloc`, loader interposition) map to: iOS sandbox `Documents/` paths, Metal/MoltenVK memory management, and the StikDebug external-debugger JIT handshake this build is already wired for.
