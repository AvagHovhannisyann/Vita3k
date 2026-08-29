#!/bin/bash
# link_ios_core_final.sh — the exact, verified-clean link recipe for the
# Vita3K iOS core + bridge (arm64-apple-ios14.0). Produces a Mach-O
# executable with the real emulator core linked in and NO undefined symbols
# beyond the 4 explicitly allowed via -Wl,-U (see the comment above them).
#
# Prerequisites (see the link report for how each was produced):
#   - PATH has ld64.lld + cctools shims (ar/ranlib/libtool/nm/...)
#   - The 38 vita3k-core module libs, REBUILT with this repo's env.sh (the
#     TRACY_ENABLE fix -- see env.sh's comment -- and creation.cpp's iOS
#     OpenGL-case guard both need to be in effect). Reproduce with:
#       for m in app audio camera codec compat config cpu ctrl display \
#                emuenv gdbstub glutil gxm http ime input io kernel lang \
#                mem module modules motion net ngs nids np overlay \
#                packages patch regmgr renderer rtc shader touch updater \
#                util vkutil; do
#         bash compile_module_par.sh "$m" 4 && bash archive_module.sh "$m"
#       done
#     (output lands in $SCRATCH/build/lib/lib<module>.a per env.sh)
#   - The small cross-built/compat libs in ios-port/patches/prebuilt-extra-libs/
#     (or rebuild them from ios-port/build-scripts/extra-libs/ + the ext/
#     source trees named in the link report)
#   - /home/user/ios-deps/lib/*.a (28 third-party libs) EXCEPT libyaml-cpp.a,
#     which is ABI-mismatched against the headers this build compiles
#     against (see report) -- libyaml-cpp-fixed.a replaces it.
#
# Usage: set CORE_LIB_DIR to wherever the 38 rebuilt module libs live (see
# above), EXTRA_LIB_DIR to wherever the small compat libs live, then run.
set -euo pipefail

SDK="${IOS_SDK:-/home/user/theos/sdks/iPhoneOS16.5.sdk}"
DEPS=/home/user/ios-deps/lib
CORE_LIB_DIR="${CORE_LIB_DIR:?set to the directory holding the 38 rebuilt lib<module>.a files}"
EXTRA_LIB_DIR="${EXTRA_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../patches/prebuilt-extra-libs" && pwd)}"
OUT="${1:-./vita3k_ios_core_test}"

export PATH=/home/user/iosbin:$PATH

MODULES="app audio camera codec compat config cpu ctrl display emuenv gdbstub glutil gxm http ime input io kernel lang mem module modules motion net ngs nids np overlay packages patch regmgr renderer rtc shader touch updater util vkutil"
CORELIBS=()
for m in $MODULES; do CORELIBS+=("$CORE_LIB_DIR/lib$m.a"); done

DEPLIBS=()
for f in "$DEPS"/*.a; do
  [ "$(basename "$f")" = "libyaml-cpp.a" ] && continue # see libyaml-cpp-fixed.a above
  DEPLIBS+=("$f")
done

# Cross-built/compat libs -- see the link report for what each replaces:
#   libios_bridge.a     a convenience prebuilt snapshot of THIS test's two
#                       bridge source files (patches/new-files/vita3k/ios/
#                       vita3k_ios_bridge.cpp + ios_bridge_apple.mm) --
#                       rebuild it from source rather than trusting this
#                       snapshot once the bridge changes.
#   libvitainterface.a  vita3k/interface.cpp (load_app/run_app) -- lives in
#                       the vita3k/ root, outside every module's own
#                       CMakeLists.txt, so the per-module compile pass never
#                       reached it.
#   libfmt10compat.a    fmt 10.x (inline namespace v10) + mcl's
#                       assert_terminate_impl, satisfying libdynarmic.a
#                       (vendors its own older fmt) without disturbing the
#                       fmt 12.x (v12) everything else compiles against.
#   libdlmalloc.a / libminiz.a / libatrac9.a / libfat16.a
#                       single/few-file third-party C sources vita3k's
#                       CMake builds as their own targets (dlmalloc,
#                       miniz, libatrac9, FAT16) rather than as part of
#                       any vita3k/<module>, so the per-module compile
#                       pass never reached them either.
#   libSPIRV.a          glslang's SPIRV/*.cpp (glslang::SPIRV, glslang's
#                       sibling CMake target -- only glslang itself and its
#                       resource-limits helper were prebuilt).
#   libosveccompat.a    __isOSVersionAtLeast/__isPlatformVersionAtLeast --
#                       this Linux/LLVM cross-toolchain has no Apple
#                       libclang_rt.ios.a to supply the @available(...)
#                       runtime helpers that MoltenVK's iOS17-optional-
#                       feature checks compile down to.
#   libcubeb.a          cubeb's core dispatch (cubeb.c) + its always-linked
#                       support objects, WITHOUT the AudioUnit backend
#                       (cubeb_audiounit.cpp isn't iOS-clean in this
#                       checkout -- see report). cubeb_init() simply finds
#                       no working backend and returns an error; harmless
#                       since Config::CurrentConfig::audio_backend defaults
#                       to "SDL", not "Cubeb".
#   libyaml-cpp-fixed.a rebuilt from this build's OWN yaml-cpp headers/
#                       source (ext/yaml-cpp) -- the prebuilt libyaml-cpp.a
#                       in ios-deps has an incompatible insert_map_pair()
#                       signature (built from a different yaml-cpp
#                       revision than the headers used everywhere else).
#   libgladstub.a       ~110 no-op glad_gl*/gladLoadGLLoader stubs. The
#                       renderer's per-draw-call GL/Vulkan dispatch (scene.cpp,
#                       shaders.cpp, renderer.cpp, state_set.cpp, sync.cpp,
#                       batch.cpp) still references gl:: symbols even though
#                       creation.cpp's one-time factory switch no longer
#                       constructs a GLState on iOS -- so these are provably
#                       dead code (current_backend is always Vulkan) but
#                       still need *something* at link time. Also: this glad
#                       build targets desktop OpenGL, not GLES, so there was
#                       never a "just build it for iOS" option anyway.
#   libzrifcompat.a     libb64 + libzrif's keyflate.c + psvpfsparser's
#                       rif2zrif.cpp/zrif2rif.cpp (zRIF<->RIF license-key
#                       conversion) -- only the leaf pieces; the deeper
#                       NoPayStation decoder they can call into
#                       (decode_license_np) is NOT built (see the 4th -U
#                       below).
#   libsdlioscompat.a   SDL_DestroyTray/SDL_UpdateTrays/
#                       SDL_SYS_ShowFileDialogWithProperties -- this
#                       libSDL3.a build has no "dummy" tray/dialog backend
#                       for iOS (SDL ships one; it just wasn't compiled in
#                       here). vita3k never calls the public tray/dialog
#                       APIs itself; these dispatcher objects get pulled in
#                       regardless.
EXTRALIBS=(
  "$EXTRA_LIB_DIR/libios_bridge.a"
  "$EXTRA_LIB_DIR/libvitainterface.a"
  "$EXTRA_LIB_DIR/libdlmalloc.a"
  "$EXTRA_LIB_DIR/libminiz.a"
  "$EXTRA_LIB_DIR/libatrac9.a"
  "$EXTRA_LIB_DIR/libfat16.a"
  "$EXTRA_LIB_DIR/libSPIRV.a"
  "$EXTRA_LIB_DIR/libosveccompat.a"
  "$EXTRA_LIB_DIR/libcubeb.a"
  "$EXTRA_LIB_DIR/libyaml-cpp-fixed.a"
  "$EXTRA_LIB_DIR/libgladstub.a"
  "$EXTRA_LIB_DIR/libzrifcompat.a"
  "$EXTRA_LIB_DIR/libsdlioscompat.a"
)
# libfmt10compat.a is listed on both sides of CORELIBS/DEPLIBS deliberately:
# ld64.lld resolves archives close to a single left-to-right pass rather
# than ld64's full iterative rescan, so a lib whose symbols are needed by
# something appearing AFTER it in the command line needs a second mention
# after that consumer (here: dynarmic, inside DEPLIBS) to actually be
# re-scanned. Repeating it is the standard workaround.
FMT10="$EXTRA_LIB_DIR/libfmt10compat.a"

# The iOS bridge itself (ios-port/patches/new-files/vita3k/ios/*), built
# separately per the link report and passed in as $2 if you have it; the
# core-only link above already proves everything below it resolves.
BRIDGE_OBJ="${2:-}"

clang++ -std=c++23 -stdlib=libc++ -isysroot "$SDK" -target arm64-apple-ios14.0 \
  -fuse-ld=lld -Wl,--error-limit=0 \
  ${BRIDGE_OBJ:+"$BRIDGE_OBJ"} \
  "${EXTRALIBS[@]}" \
  "${CORELIBS[@]}" \
  "$FMT10" \
  "${DEPLIBS[@]}" \
  "$FMT10" \
  -framework Foundation -framework UIKit -framework Metal -framework QuartzCore \
  -framework CoreGraphics -framework AudioToolbox -framework AVFoundation \
  -framework GameController -framework CoreHaptics -framework CoreMedia \
  -framework CoreVideo -framework Security -framework SystemConfiguration \
  -framework IOSurface -framework CoreBluetooth -framework CoreMotion \
  -framework OpenGLES -framework VideoToolbox \
  -Wl,-U,'_OBJC_CLASS_$_MTLResidencySetDescriptor' \
  -Wl,-U,__Z17decode_license_npNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEE \
  -Wl,-U,_transform_dis_main \
  -Wl,-U,__Z7executeRNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEES6_S6_18F00DEncryptorTypesS6_NS_8functionIFvyyRKS5_EEE \
  -lz -lc++ -liconv -lcompression -lbz2 \
  -o "$OUT"

echo "linked -> $OUT"
file "$OUT"
