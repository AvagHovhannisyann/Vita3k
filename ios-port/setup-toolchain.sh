#!/usr/bin/env bash
# One-time setup for the Linux->iOS cross toolchain used by the Vita3K port.
# Creates the /home/user/iosbin shims that clang/CMake expect for a Darwin
# target: the Mach-O linker (ld64.lld) and the Apple cctools, mapped onto their
# LLVM equivalents. Also ensures the isolated Boost headers exist.
set -euo pipefail
BIN="${IOSBIN:-/home/user/iosbin}"
DEPS="${IOS_DEPS:-/home/user/ios-deps}"
mkdir -p "$BIN" "$DEPS/include"

ln -sf /usr/bin/lld                       "$BIN/ld64.lld"
ln -sf /usr/bin/llvm-install-name-tool-18 "$BIN/install_name_tool"
ln -sf /usr/bin/llvm-otool-18             "$BIN/otool"
ln -sf /usr/bin/llvm-libtool-darwin-18    "$BIN/libtool"
ln -sf /usr/bin/llvm-lipo-18              "$BIN/lipo"

if [ ! -e "$DEPS/include/boost" ] && [ -d /usr/include/boost ]; then
  ln -sfn /usr/include/boost "$DEPS/include/boost"
fi

echo "iosbin ready: $BIN"
ls -l "$BIN"
echo "Add to PATH for all iOS builds:  export PATH=$BIN:\$PATH"
