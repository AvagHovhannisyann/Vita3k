#!/bin/bash
# apply_tracy_fix.sh — produce patched copies of libkernel.a / librenderer.a /
# libmodules.a with the 5 objects that leak real tracy:: symbols replaced.
#
# ROOT CAUSE: env.sh's COMMON_FLAGS passed `-DTRACY_ENABLE=0` to every module
# compile. That DEFINES the macro (with value 0) rather than leaving it
# undefined, so every `#ifdef TRACY_ENABLE` guard in the tree (kernel.cpp,
# renderer/src/batch.cpp, modules/SceAppMgr, modules/SceAVConfig,
# modules/SceDisplay) evaluated true and pulled in real
# `#include <tracy/Tracy.hpp>` / tracy::* calls, even though the intent was
# "tracy disabled". Since we don't build/link the real Tracy client, those 5
# objects were left with undefined tracy::GetProfiler/rpmalloc/SetThreadName/...
#
# FIX: recompile just those 5 translation units with TRACY_ENABLE left
# undefined (not =0), so the #ifdef correctly takes the disabled branch, then
# splice the fixed .o over the original archive member. This script
# reproduces that splice from the checked-in fixed objects in
# ios-port/patches/tracy-fix-objects/ against the original prebuilt libs in
# /home/user/ios-deps/lib/vita3k-core, writing patched copies to $OUT (does
# NOT touch the ios-deps originals).
#
# For a from-scratch recompile instead of splicing prebuilt .o's, see the
# `FIXED_FLAGS` trick in this repo's link report: take env.sh's COMMON_FLAGS
# and strip `-DTRACY_ENABLE=0` before invoking clang++ on the 5 files below,
# and fix env.sh itself (drop that define) before any future full rebuild.
set -euo pipefail
export PATH=/home/user/iosbin:$PATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXOBJ="$HERE/../patches/tracy-fix-objects"
CORE=/home/user/ios-deps/lib/vita3k-core
OUT="${1:-$HERE/../../build/lib-patched}"
mkdir -p "$OUT"

cp "$CORE/libkernel.a" "$CORE/librenderer.a" "$CORE/libmodules.a" "$OUT/"
chmod u+w "$OUT"/*.a

llvm-ar d "$OUT/libkernel.a" src_kernel.o
llvm-ar q "$OUT/libkernel.a" "$FIXOBJ/src_kernel.o"
llvm-ranlib "$OUT/libkernel.a"

llvm-ar d "$OUT/librenderer.a" src_batch.o
llvm-ar q "$OUT/librenderer.a" "$FIXOBJ/src_batch.o"
llvm-ranlib "$OUT/librenderer.a"

llvm-ar d "$OUT/libmodules.a" SceAppMgr_SceAppMgr.o SceAVConfig_SceAVConfig.o SceDisplay_SceDisplay.o
llvm-ar q "$OUT/libmodules.a" \
  "$FIXOBJ/SceAppMgr_SceAppMgr.o" "$FIXOBJ/SceAVConfig_SceAVConfig.o" "$FIXOBJ/SceDisplay_SceDisplay.o"
llvm-ranlib "$OUT/libmodules.a"

echo "patched libs written to $OUT (libkernel.a, librenderer.a, libmodules.a)"
for f in libkernel.a librenderer.a libmodules.a; do
  n=$(llvm-ar t "$OUT/$f" | wc -l)
  echo "  $f: $n members"
done

# SUPERSEDED NOTE: mid-investigation this only covered 5 of the 8 affected
# objects (missed modules/SceGxm/SceGxm.cpp, modules/SceGpuEs4/
# SceGpuEs4ForUser.cpp, modules/SceLibft2/SceFt2.cpp -- TRACY_FUNC(), the
# macro every HLE export wraps itself in, turned out to be the real vector,
# not just the 5 files with a literal "#ifdef TRACY_ENABLE" in them). The
# authoritative fix is a full recompile of all 38 modules with env.sh's
# corrected COMMON_FLAGS (TRACY_ENABLE no longer defined) -- see the link
# report. This script and its 5 checked-in objects are kept for the
# splice-only workflow (patching a couple of objects in an already-built
# archive without a full recompile) but a full rebuild is what was actually
# used for the final verified-clean link.
