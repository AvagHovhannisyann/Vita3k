#!/usr/bin/env bash
# Build Vita3K.ipa with the REAL emulator core linked in (not CoreStub.c).
#
# Front-end objects (which provide main) + the 38 Vita3K core libs + the 28
# third-party libs + the compat libs + the iOS bridge -> one arm64 iOS app.
set -euo pipefail
BUILD_ID="${BUILD_ID:-$(date -u +%Y%m%d-%H%M%S)}"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SDK="${IOS_SDK:-/home/user/theos/sdks/iPhoneOS16.5.sdk}"
export PATH=/home/user/iosbin:$PATH

DEPS=/home/user/ios-deps/lib
CORE_LIB_DIR="${CORE_LIB_DIR:-/home/user/ios-deps/lib/vita3k-core}"
EXTRA_LIB_DIR="${EXTRA_LIB_DIR:-$REPO/ios-port/patches/prebuilt-extra-libs}"
CONV="$REPO/ios-conversion"
OUT="$HERE/out-full"; APP="$OUT/Payload/Vita3K.app"

echo "==> compile front-end (main lives here); CoreStub is EXCLUDED"
rm -rf "$OUT"; mkdir -p "$OUT/obj" "$APP"
OBJS=()
for m in "$HERE"/src/*.m; do
  o="$OUT/obj/$(basename "${m%.m}").o"
  clang -target arm64-apple-ios14.0 -isysroot "$SDK" -fobjc-arc -fmodules \
        -Wall -Wno-unused -O2 -DV3K_BUILD_ID=\"$BUILD_ID\" -I"$HERE/src" -c "$m" -o "$o"
  OBJS+=("$o")
done

# Objective-C++ sources (the std::terminate reporter needs the C++ ABI).
for mm in "$HERE"/src/*.mm; do
  [ -e "$mm" ] || continue
  o="$OUT/obj/$(basename "${mm%.mm}").o"
  clang++ -target arm64-apple-ios14.0 -isysroot "$SDK" -std=c++17 -stdlib=libc++ \
        -fobjc-arc -Wall -Wno-unused -O2 -DV3K_BUILD_ID=\"$BUILD_ID\" -I"$HERE/src" -c "$mm" -o "$o"
  OBJS+=("$o")
done

# NOTE: src/*.c (CoreStub.c) deliberately not compiled — the real bridge provides those symbols.

# The JIT-arena fallback goes into its own archive, linked LAST. A linker only
# pulls an archive member to resolve a still-undefined symbol, so the core's
# real v3k_ios_jit_* implementation always wins when it is present; if it is
# absent the app links anyway and says so on screen instead of silently
# pretending JIT is available. (A plain weak definition would NOT work here: it
# satisfies the reference outright and the real one is never pulled in.)
clang -target arm64-apple-ios14.0 -isysroot "$SDK" -Wall -O2 \
      -c "$HERE/src/jitarena_stub.c" -o "$OUT/obj/jitarena_stub.o"
llvm-ar rcs "$OUT/libjitarenastub.a" "$OUT/obj/jitarena_stub.o"

MODULES="app audio camera codec compat config cpu ctrl display emuenv gdbstub glutil gxm http ime input io kernel lang mem module modules motion net ngs nids np overlay packages patch regmgr renderer rtc shader touch updater util vkutil"
CORELIBS=(); for m in $MODULES; do CORELIBS+=("$CORE_LIB_DIR/lib$m.a"); done
DEPLIBS=(); for f in "$DEPS"/*.a; do
  [ "$(basename "$f")" = "libyaml-cpp.a" ] && continue
  DEPLIBS+=("$f")
done
EXTRALIBS=(
  # First: the JIT arena. dynarmic's oaknut::CodeBlock and the front-end both
  # reference v3k_ios_jit_*, and this must resolve them before the fallback
  # archive at the end of the link does.
  "$EXTRA_LIB_DIR/libiosjitarena.a"
  "$EXTRA_LIB_DIR/libios_bridge.a"   "$EXTRA_LIB_DIR/libvitainterface.a"
  "$EXTRA_LIB_DIR/libdlmalloc.a"     "$EXTRA_LIB_DIR/libminiz.a"
  "$EXTRA_LIB_DIR/libatrac9.a"       "$EXTRA_LIB_DIR/libfat16.a"
  "$EXTRA_LIB_DIR/libSPIRV.a"        "$EXTRA_LIB_DIR/libosveccompat.a"
  "$EXTRA_LIB_DIR/libcubeb.a"        "$EXTRA_LIB_DIR/libyaml-cpp-fixed.a"
  "$EXTRA_LIB_DIR/libgladstub.a"     "$EXTRA_LIB_DIR/libpsvpfs.a"
  "$EXTRA_LIB_DIR/libsubstitute.a"
  "$EXTRA_LIB_DIR/libsdlioscompat.a"
)
FMT10="$EXTRA_LIB_DIR/libfmt10compat.a"

echo "==> link app + real Vita3K core"
clang++ -std=c++23 -stdlib=libc++ -isysroot "$SDK" -target arm64-apple-ios14.0 \
  -fuse-ld=lld -Wl,--error-limit=0 -Wl,-adhoc_codesign \
  "${OBJS[@]}" \
  "${EXTRALIBS[@]}" "${CORELIBS[@]}" "$FMT10" "${DEPLIBS[@]}" "$FMT10" \
  "$OUT/libjitarenastub.a" \
  -framework Foundation -framework UIKit -framework Metal -framework QuartzCore \
  -framework CoreGraphics -framework AudioToolbox -framework AVFoundation \
  -framework GameController -framework CoreHaptics -framework CoreMedia \
  -framework CoreVideo -framework Security -framework SystemConfiguration \
  -framework IOSurface -framework CoreBluetooth -framework CoreMotion \
  -framework VideoToolbox -framework UniformTypeIdentifiers \
  -Wl,-U,'_OBJC_CLASS_$_MTLResidencySetDescriptor' \
  -lz -lc++ -liconv -lcompression -lbz2 \
  -o "$OUT/Vita3K"

echo "==> ad-hoc sign with get-task-allow"
python3 "$CONV/codesign_adhoc.py" "$OUT/Vita3K" org.vita3k.emulator \
  "$CONV/entitlements.plist" "$HERE/Info.plist"

echo "==> package"
cp "$OUT/Vita3K" "$APP/Vita3K"; chmod 755 "$APP/Vita3K"
cp "$HERE/Info.plist" "$APP/Info.plist"
printf 'APPL????' > "$APP/PkgInfo"
cp "$CONV/icons/AppIcon120.png" "$CONV/icons/AppIcon152.png" \
   "$CONV/icons/AppIcon167.png" "$CONV/icons/AppIcon180.png" "$APP/"
# Vita3K's builtin shaders, reused verbatim from the original APK
SH="$REPO/ios-conversion/out/extracted/assets/shaders-builtin"
[ -d "$SH" ] && cp -r "$SH" "$APP/shaders-builtin" || true
( cd "$OUT" && rm -f Vita3K-full.ipa && zip -q -r -X Vita3K-full.ipa Payload )
cp "$OUT/Vita3K-full.ipa" "$REPO/Vita3K-full.ipa"
echo "done -> $REPO/Vita3K-full.ipa"
file "$APP/Vita3K"; du -h "$REPO/Vita3K-full.ipa" | cut -f1
