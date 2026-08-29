#!/usr/bin/env bash
# Cross-compile dynarmic (Vita3K's ARM dynamic recompiler — the JIT core) for
# arm64 iOS, from Linux, using the real iPhoneOS SDK + clang/lld. No Xcode.
#
# This proves the single hardest/riskiest component of the Vita3K iOS port
# builds for the target. Produces libdynarmic.a (arm64 Mach-O).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-/home/user/vita3k-ios-work}"
SDK="${IOS_SDK:-/home/user/theos/sdks/iPhoneOS16.5.sdk}"
IOSBIN="${IOSBIN:-/home/user/iosbin}"
DEPS="${IOS_DEPS:-/home/user/ios-deps}"

[ -d "$SDK" ] || { echo "iOS SDK not found at $SDK"; exit 1; }

echo "==> ensure ld64.lld shim + isolated boost headers"
mkdir -p "$IOSBIN" "$DEPS/include"
ln -sf /usr/bin/lld "$IOSBIN/ld64.lld"
if [ ! -e "$DEPS/include/boost" ]; then
  if [ -d /usr/include/boost ]; then ln -sfn /usr/include/boost "$DEPS/include/boost"
  else echo "Boost headers missing: apt-get install -y libboost-dev"; exit 1; fi
fi

echo "==> fetch Vita3K's pinned dynarmic (with submodules) if absent"
mkdir -p "$WORK"
if [ ! -d "$WORK/dynarmic/.git" ]; then
  git clone --recursive --depth 1 https://github.com/Vita3K/dynarmic "$WORK/dynarmic"
fi

echo "==> configure dynarmic for arm64-apple-ios (A32 frontend, no tests)"
rm -rf "$WORK/dynarmic-ios-build"; mkdir -p "$WORK/dynarmic-ios-build"
cd "$WORK/dynarmic-ios-build"
PATH="$IOSBIN:$PATH" cmake "$WORK/dynarmic" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$HERE/toolchain/ios-arm64.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DDYNARMIC_TESTS=OFF \
  -DDYNARMIC_FRONTENDS=A32 \
  -DBoost_INCLUDE_DIR="$DEPS/include"

echo "==> build"
PATH="$IOSBIN:$PATH" ninja dynarmic

LIB="$WORK/dynarmic-ios-build/src/dynarmic/libdynarmic.a"
echo "==> result:"; file "$LIB"
echo "done -> $LIB"
