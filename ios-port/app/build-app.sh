#!/usr/bin/env bash
# Build the Vita3K iOS front-end app -> Vita3K.ipa, cross-compiled on Linux with
# the real iPhoneOS SDK + clang/lld. Ad-hoc signed with get-task-allow so
# Sideloadly can install it and StikDebug can enable JIT.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SDK="${IOS_SDK:-/home/user/theos/sdks/iPhoneOS16.5.sdk}"
IOSBIN="${IOSBIN:-/home/user/iosbin}"
OUT="$HERE/out"
APP="$OUT/Payload/Vita3K.app"
CONV="$REPO/ios-conversion"   # reuse icons + signer + entitlements

[ -d "$SDK" ] || { echo "iOS SDK missing: $SDK"; exit 1; }
mkdir -p "$IOSBIN"; ln -sf /usr/bin/lld "$IOSBIN/ld64.lld"

echo "==> compile Objective-C sources (arm64-apple-ios14.0)"
rm -rf "$OUT"; mkdir -p "$OUT/obj" "$APP"
OBJS=()
for m in "$HERE"/src/*.m; do
  o="$OUT/obj/$(basename "${m%.m}").o"
  echo "    CC $(basename "$m")"
  clang -target arm64-apple-ios14.0 -isysroot "$SDK" -fobjc-arc -fmodules \
        -Wall -Wno-unused -O2 -I"$HERE/src" -c "$m" -o "$o"
  OBJS+=("$o")
done
# C sources (e.g. the core stub for UI-preview builds; omit when linking the real core)
for c in "$HERE"/src/*.c; do
  [ -e "$c" ] || continue
  o="$OUT/obj/$(basename "${c%.c}").o"
  echo "    CC $(basename "$c")"
  clang -target arm64-apple-ios14.0 -isysroot "$SDK" -Wall -O2 -c "$c" -o "$o"
  OBJS+=("$o")
done

echo "==> link Vita3K executable"
PATH="$IOSBIN:$PATH" clang -target arm64-apple-ios14.0 -isysroot "$SDK" \
  -fuse-ld=lld -Wl,-adhoc_codesign \
  -framework UIKit -framework Foundation -framework CoreGraphics \
  -framework QuartzCore -framework Metal -framework GameController \
  -framework UniformTypeIdentifiers -framework CoreHaptics \
  -lz \
  "${OBJS[@]}" -o "$OUT/Vita3K"

echo "==> ad-hoc sign with get-task-allow (JIT/StikDebug)"
python3 "$CONV/codesign_adhoc.py" "$OUT/Vita3K" org.vita3k.emulator \
  "$CONV/entitlements.plist" "$HERE/Info.plist"

echo "==> assemble Vita3K.app"
cp "$OUT/Vita3K" "$APP/Vita3K"; chmod 755 "$APP/Vita3K"
cp "$HERE/Info.plist" "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"
cp "$CONV/icons/AppIcon120.png" "$CONV/icons/AppIcon152.png" \
   "$CONV/icons/AppIcon167.png" "$CONV/icons/AppIcon180.png" "$APP/"

echo "==> package Vita3K.ipa"
( cd "$OUT" && rm -f Vita3K.ipa && zip -q -r -X Vita3K.ipa Payload )
cp "$OUT/Vita3K.ipa" "$REPO/Vita3K.ipa"
echo "done -> $REPO/Vita3K.ipa"
file "$APP/Vita3K"
