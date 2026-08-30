#!/usr/bin/env bash
# Cross-build LLVM 22 for arm64-iOS — the long pole of the RPCS3 iOS port.
#
# RPCS3 links LLVM statically as its PPU/SPU recompiler backend
# (Utilities/JITLLVM.cpp). Its own CMake requires LLVM 22.1
# (3rdparty/llvm/CMakeLists.txt), and RPCS3's Android config already proves the
# AArch64-only shape we use here.
#
# The host toolchain is LLVM 18, four majors behind, so the host llvm-tblgen
# CANNOT be reused: TableGen output must match the tree being built. LLVM solves
# this itself — when CMAKE_CROSSCOMPILING is true it configures a NATIVE
# sub-build and builds tblgen for the host from this same source. That costs
# extra build time but is the only correct route.
set -euo pipefail

SCRATCH="${SCRATCH:-/tmp/claude-0/-home-user-Vita3k/714537f3-3984-5f62-85cc-535c1056dc02/scratchpad}"
SRC="$SCRATCH/llvm-project/llvm"
BUILD="$SCRATCH/llvm-ios-build"
PREFIX="${PREFIX:-/home/user/ios-deps-ps3}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLCHAIN="$HERE/../toolchain/ios-arm64.cmake"

[ -d "$SRC" ] || { echo "LLVM source missing at $SRC"; exit 1; }
export PATH=/home/user/iosbin:$PATH

cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_CROSSCOMPILING=TRUE \
  -DLLVM_TARGETS_TO_BUILD=AArch64 \
  -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios14.0 \
  -DLLVM_HOST_TRIPLE=arm64-apple-ios14.0 \
  -DLLVM_BUILD_TOOLS=OFF \
  -DLLVM_BUILD_RUNTIME=OFF \
  -DLLVM_BUILD_UTILS=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_ENABLE_ASSERTIONS=OFF \
  -DLLVM_ENABLE_RTTI=ON \
  -DLLVM_ENABLE_THREADS=ON \
  -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_ENABLE_ZSTD=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_LIBEDIT=OFF \
  -DLLVM_ENABLE_LIBPFM=OFF \
  -DLLVM_ENABLE_PIC=ON \
  "$@"

# Only the static libraries; tools are off, so the default target is the libs.
ninja -C "$BUILD" -j"${JOBS:-4}"
