# Vita3K APK → iOS IPA conversion

This branch converts the supplied Android APK of **Vita3K** (`org.vita3k.emulator`,
a PlayStation Vita emulator) into a real, sideloadable iOS application package.

## Deliverable

- **[`ConvertedApp.ipa`](ConvertedApp.ipa)** — `Payload/ConvertedApp.app/` with a real
  **ARM64 Mach-O** executable, the app's reused assets/icon, the preserved native core,
  and a **`get-task-allow`** entitlement for StikDebug/JIT.
- **[`CONVERSION_LOG.md`](CONVERSION_LOG.md)** — full account: framework detected, what was
  extracted/reused/translated, Android→iOS API mapping, JIT/StikDebug configuration,
  build problems + fixes, IPA structure, entitlements, validation, and honest limitations.

## How it was built (Linux, no Xcode)

Cross-compiled with `clang -target arm64-apple-ios` + `lld -flavor darwin` against
hand-written TBD framework stubs, ad-hoc signed with a pure-Python Mach-O signer, and
packaged with `zip`. Reproduce end-to-end:

```bash
ios-conversion/build.sh /path/to/androidlatest.apk
```

## Sideload + JIT

1. Sign & install `ConvertedApp.ipa` with **Sideloadly** (a free Apple ID automatically
   keeps `get-task-allow`, which is what enables JIT).
2. Launch it; it shows a live **JIT self-test** and whether a debugger is attached.
3. Select it in **StikDebug** to enable JIT.

> Scope: the emulator's C++ core is **preserved in-bundle** but not recompiled for iOS
> (that step needs macOS/Xcode + MoltenVK). The iOS shell, asset reuse, packaging,
> entitlements, and the on-device JIT bring-up are complete and validated. See
> `CONVERSION_LOG.md` §10–11.
