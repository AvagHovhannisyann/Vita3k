export PATH=/home/user/iosbin:$PATH
SCRATCH=/tmp/claude-0/-home-user-Vita3k/714537f3-3984-5f62-85cc-535c1056dc02/scratchpad
SRC="$SCRATCH/v3ksrc"
V3K="$SRC/vita3k"
EXT="$SCRATCH/ext"
IOSDEPS=/home/user/ios-deps
SDK=/home/user/theos/sdks/iPhoneOS16.5.sdk

# All vita3k module include dirs (public headers)
MODULE_INCLUDES=$(find "$V3K" -maxdepth 2 -type d -name include)

INCLUDE_FLAGS="-I$V3K"
for d in $MODULE_INCLUDES; do
  INCLUDE_FLAGS="$INCLUDE_FLAGS -I$d"
done

INCLUDE_FLAGS="$INCLUDE_FLAGS \
-I$EXT/ffmpeg/include \
-I$IOSDEPS/include \
-I$EXT/fmt/include \
-I$EXT/spdlog/include \
-I$EXT/yaml-cpp/include \
-I$EXT/pugixml/src \
-I$EXT/sdl/include \
-I$EXT/capstone/include \
-I$EXT/dynarmic/externals/mcl/include \
-I$EXT/dynarmic/externals/oaknut/include \
-I$EXT/xxHash \
-I$EXT/stb \
-I$EXT/concurrentqueue \
-I$EXT/VulkanMemoryAllocator-Hpp/include \
-I$EXT/VulkanMemoryAllocator-Hpp/VulkanMemoryAllocator/include \
-I$EXT/VulkanMemoryAllocator-Hpp/Vulkan-Headers/include \
-I$EXT/LibAtrac9/C/src \
-I$EXT/substitute \
-I$EXT/printf \
-I$EXT/libfat16/include \
-I$EXT/cubeb/include \
-I$SCRATCH/build/gen/cubeb_exports \
-I$EXT/psvpfstools/psvpfsparser \
-I$EXT/psvpfstools/libzrif/include \
-I$EXT/psvpfstools/libb64/include \
-I$EXT/dlmalloc \
-I$SCRATCH/mvk/MoltenVK/MoltenVK/include \
-I$EXT/tracy/public \
-I$EXT/SPIRV-Cross \
-I$EXT/glslang \
-I$EXT/vita-toolchain/src \
-I$SRC/external/CppCommon/include \
-I$SRC/external/ddspp \
-I$SRC/external/miniz \
-I$SRC/external/cli11 \
-I$SRC/external/glad/include \
-I$SRC/external/GPUOpen \
-I$SCRATCH/build/gen \
-I$SCRATCH/build/gen/lang_generated"

# NOTE: deliberately NOT defining TRACY_ENABLE below (not even =0). The tree
# guards tracy usage with `#ifdef TRACY_ENABLE`, so defining it to ANY value
# (this used to say -DTRACY_ENABLE=0) makes that guard true and pulls in real
# tracy::* calls with nothing to satisfy them at link time, since we don't
# build/link the real Tracy client. See apply_tracy_fix.sh and the link
# report for the 5 objects (kernel.cpp, renderer/src/batch.cpp,
# modules/SceAppMgr, modules/SceAVConfig, modules/SceDisplay) that were
# compiled with the old broken flag and need recompiling (or patching, via
# apply_tracy_fix.sh) if reusing prebuilt libs from before this fix.
COMMON_FLAGS="-std=c++23 -stdlib=libc++ -isysroot $SDK -target arm64-apple-ios14.0 \
-w -DIOS=1 \
-DSPDLOG_FMT_EXTERNAL -DSPDLOG_NO_THREAD_ID -DSPDLOG_WCHAR_FILENAMES \
-DBOOST_ASIO_DISABLE_STD_COROUTINE -DONLY_MSPACES=1 -DUSE_LOCK=0"
