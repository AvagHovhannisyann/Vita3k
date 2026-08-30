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
FRESH_CLONE=0
if [ ! -d "$WORK/dynarmic/.git" ]; then
  git clone --recursive --depth 1 https://github.com/Vita3K/dynarmic "$WORK/dynarmic"
  FRESH_CLONE=1
fi

# The iOS JIT-arena patch (task #9 / PORT_STATUS.md's "biggest remaining
# runtime risk") makes oaknut::CodeBlock draw memory from
# vita3k/ios/ios_jit_arena.cpp's pre-prepared arena instead of mmap'ing its
# own, on iOS only -- every other platform is untouched. See
# JIT_ARENA_DESIGN.md for the full rationale. Only apply it once: a
# freshly cloned tree needs it; a $WORK/dynarmic left over from a previous
# run of this script already has it (re-applying would fail with
# "already applied" / reject noise, not silently double-patch).
PATCH="$HERE/patches/0002-dynarmic-ios-jit-arena.patch"
if [ "$FRESH_CLONE" = "1" ] && [ -f "$PATCH" ]; then
  echo "==> applying iOS JIT-arena patch to the freshly cloned tree"
  git -C "$WORK/dynarmic" apply --verbose "$PATCH"
elif [ -f "$PATCH" ] && ! grep -q "v3k_ios_jit_slot_alloc" "$WORK/dynarmic/externals/oaknut/include/oaknut/code_block.hpp" 2>/dev/null; then
  echo "==> applying iOS JIT-arena patch to the existing tree (was not yet applied)"
  git -C "$WORK/dynarmic" apply --verbose "$PATCH"
else
  echo "==> iOS JIT-arena patch already applied (or patch file missing) -- skipping"
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
echo
echo "NOTE: on iOS this library now has two undefined externs,"
echo "  _v3k_ios_jit_slot_alloc / _v3k_ios_jit_slot_free,"
echo "that only vita3k/ios/ios_jit_arena.cpp defines (see"
echo "patches/new-files/vita3k/ios/ and JIT_ARENA_DESIGN.md). Nothing"
echo "resolves them at this point -- that .cpp is compiled and linked"
echo "separately, as part of the vita3k core / final app link, the same"
echo "way vita3k_ios_bridge.cpp and ios_bridge_apple.mm already are (see"
echo "ios-port/build-scripts/link_ios_core_final.sh). A link that never"
echo "reaches that stage (e.g. archiving this .a alone) will not surface"
echo "the missing symbols; the final app link will refuse to link"
echo "without them."
