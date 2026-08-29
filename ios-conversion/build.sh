#!/usr/bin/env bash
#
# Reproducible APK -> iOS IPA conversion for Vita3K (org.vita3k.emulator).
#
# Runs entirely on Linux with clang + lld (LLVM 18) + Python 3 (stdlib only).
# No Xcode, no macOS, no Apple SDK required. Produces ConvertedApp.ipa with a
# real ARM64 Mach-O executable, the app's reused assets, a get-task-allow
# entitlement, and an embedded ad-hoc code signature.
#
# Usage:  ./build.sh /path/to/androidlatest.apk
#
set -euo pipefail

APK="${1:?usage: build.sh <path-to.apk>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out"
SDK="$HERE/iossdk-stub"
APP="$OUT/Payload/ConvertedApp.app"

echo "==> [1/7] unpack APK"
rm -rf "$OUT"; mkdir -p "$OUT/extracted"
unzip -o -q "$APK" -d "$OUT/extracted"

echo "==> [2/7] recover launcher icon + generate iOS icon sizes"
mkdir -p "$OUT/icons"
python3 "$HERE/pngtool.py" "$OUT/extracted/res/GX.png" \
    120:"$OUT/icons/AppIcon120.png" \
    152:"$OUT/icons/AppIcon152.png" \
    167:"$OUT/icons/AppIcon167.png" \
    180:"$OUT/icons/AppIcon180.png" \
    1024:"$OUT/icons/AppIcon1024.png"

# Prefer a real Apple iPhoneOS SDK when one is present (genuine framework stubs,
# real headers); fall back to the hand-authored minimal TBD stubs otherwise.
REAL_SDK="${IOS_SDK:-/home/user/theos/sdks/iPhoneOS16.5.sdk}"
if [ -d "$REAL_SDK" ]; then
    echo "==> using real iOS SDK: $REAL_SDK"
    SYSROOT_ARGS=(-isysroot "$REAL_SDK")
    LINK_ARGS=(-syslibroot "$REAL_SDK" -lSystem -lobjc -framework UIKit -framework Foundation)
    SDK_VER=16.5
else
    echo "==> real iOS SDK not found; using minimal TBD stubs"
    SYSROOT_ARGS=()
    LINK_ARGS=(-L"$SDK/usr/lib" -lSystem -lobjc -F"$SDK/System/Library/Frameworks" -framework UIKit)
    SDK_VER=16.4
fi

echo "==> [3/7] compile iOS ARM64 objects (clang, Mach-O)"
clang -target arm64-apple-ios12.0 "${SYSROOT_ARGS[@]}" -fno-objc-arc -fobjc-runtime=ios-12.0 \
      -Wall -Wno-unused-function -Os -c "$HERE/src/main.m" -o "$OUT/main.o"

echo "==> [4/7] link Mach-O executable (lld darwin) with reserved code-signature"
lld -flavor darwin -arch arm64 -platform_version ios 12.0 "$SDK_VER" \
    -o "$OUT/ConvertedApp" "$OUT/main.o" \
    "${LINK_ARGS[@]}" \
    -e _main -pie -adhoc_codesign

echo "==> [5/7] ad-hoc sign with embedded get-task-allow entitlement"
python3 "$HERE/codesign_adhoc.py" "$OUT/ConvertedApp" \
    org.vita3k.emulator "$HERE/entitlements.plist" "$HERE/Info.plist"

echo "==> [6/7] assemble Payload/ConvertedApp.app"
rm -rf "$OUT/Payload"; mkdir -p "$APP/Vita3KCore"
cp "$OUT/ConvertedApp" "$APP/ConvertedApp"; chmod 755 "$APP/ConvertedApp"
cp "$HERE/Info.plist" "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"
cp "$OUT/icons/"*.png "$APP/"
cp -r "$OUT/extracted/assets/shaders-builtin" "$APP/shaders-builtin"
cp -r "$OUT/extracted/assets/data/gui-configs" "$APP/gui-configs"
# preserve original ARM64 native core (zipped so re-signers treat it as data)
TMP="$(mktemp -d)"; mkdir -p "$TMP/arm64-v8a"
cp "$OUT/extracted/lib/arm64-v8a/"*.so "$TMP/arm64-v8a/"
( cd "$TMP" && zip -q -r -X "$APP/Vita3KCore/native-payload-arm64.zip" arm64-v8a ); rm -rf "$TMP"

echo "==> [7/7] package ConvertedApp.ipa"
( cd "$OUT" && rm -f ConvertedApp.ipa && zip -q -r -X ConvertedApp.ipa Payload )
cp "$OUT/ConvertedApp.ipa" "$HERE/../ConvertedApp.ipa"
echo "done -> $HERE/../ConvertedApp.ipa"
