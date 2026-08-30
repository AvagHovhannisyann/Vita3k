#!/usr/bin/env bash
# Cross-build LLVM 22 for arm64-iOS — the long pole of the RPCS3 iOS port.
#
# RPCS3 links LLVM statically as its PPU/SPU recompiler backend
# (Utilities/JITLLVM.cpp). Its own CMake requires LLVM 22.1
# (3rdparty/llvm/CMakeLists.txt), and RPCS3's Android config already proves the
# AArch64-only shape we use here.
#
# The host toolchain is LLVM 18, four majors behind, so the host llvm-tblgen
# CANNOT be reused: TableGen output must match the tree being built. So this is a
# TWO-STAGE build: stage 1 builds tblgen for the HOST from this same LLVM 22
# source, stage 2 cross-builds the libraries for iOS pointing at those binaries.
#
# Relying on LLVM's automatic NATIVE sub-build did not work here: it still tried
# to link llvm-min-tblgen for arm64-ios and failed on -lrt. That -lrt is itself a
# consequence of our toolchain setting CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
# (it cannot run target binaries), which makes CMake's check_library_exists()
# succeed without ever linking — so LLVM concluded Linux's librt existed on iOS.
# Hence the explicit HAVE_LIBRT=0 below; any other host-only library LLVM probes
# for needs the same treatment.
set -euo pipefail

SCRATCH="${SCRATCH:-/tmp/claude-0/-home-user-Vita3k/714537f3-3984-5f62-85cc-535c1056dc02/scratchpad}"
SRC="$SCRATCH/llvm-project/llvm"
BUILD="$SCRATCH/llvm-ios-build"
HOSTBUILD="$SCRATCH/llvm-host-tblgen"
PREFIX="${PREFIX:-/home/user/ios-deps-ps3}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLCHAIN="$HERE/../toolchain/ios-arm64.cmake"

[ -d "$SRC" ] || { echo "LLVM source missing at $SRC"; exit 1; }
export PATH=/home/user/iosbin:$PATH

# ---- stage 1: tblgen for the host, from the same source tree ----------------
if [ ! -x "$HOSTBUILD/bin/llvm-tblgen" ]; then
  cmake -S "$SRC" -B "$HOSTBUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD=AArch64 \
    -DLLVM_BUILD_TOOLS=OFF -DLLVM_BUILD_RUNTIME=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_LIBPFM=OFF
  ninja -C "$HOSTBUILD" -j"${JOBS:-4}" llvm-tblgen llvm-min-tblgen
fi

# ---- stage 2: the iOS libraries --------------------------------------------
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DLLVM_TABLEGEN="$HOSTBUILD/bin/llvm-tblgen" \
  -DLLVM_MIN_TBLGEN="$HOSTBUILD/bin/llvm-min-tblgen" \
  -DHAVE_LIBRT=0 \
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
