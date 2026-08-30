# CMake toolchain: cross-compile to arm64 iOS from Linux using a real iPhoneOS
# SDK + clang/lld. No Xcode, no macOS. Used for the Vita3K iOS port.
set(CMAKE_SYSTEM_NAME Darwin)          # Mach-O conventions without the iOS module's xcrun dependency
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(IOS TRUE)
set(APPLE TRUE)

if(NOT DEFINED IOS_SDK)
  set(IOS_SDK "/home/user/theos/sdks/iPhoneOS16.5.sdk")
endif()
if(NOT DEFINED IOS_DEPLOYMENT_TARGET)
  set(IOS_DEPLOYMENT_TARGET "14.0")
endif()
set(CMAKE_OSX_SYSROOT "${IOS_SDK}" CACHE STRING "")
set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "")
set(CMAKE_OSX_DEPLOYMENT_TARGET "${IOS_DEPLOYMENT_TARGET}" CACHE STRING "")

set(_triple "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}")
set(CMAKE_C_COMPILER      clang)
set(CMAKE_CXX_COMPILER    clang++)
set(CMAKE_ASM_COMPILER    clang)
set(CMAKE_OBJC_COMPILER   clang)
set(CMAKE_OBJCXX_COMPILER clang++)
set(CMAKE_C_COMPILER_TARGET      "${_triple}")
set(CMAKE_CXX_COMPILER_TARGET    "${_triple}")
set(CMAKE_ASM_COMPILER_TARGET    "${_triple}")
# Objective-C/C++ need the triple too, else their probe compiles for the host
# (SDL and other UIKit-using deps enable OBJC and would misdetect otherwise).
set(CMAKE_OBJC_COMPILER_TARGET   "${_triple}")
set(CMAKE_OBJCXX_COMPILER_TARGET "${_triple}")

# Real Apple stubs live in the SDK; drive linking through clang + lld (Mach-O).
add_compile_options(-isysroot "${IOS_SDK}")
add_link_options(-isysroot "${IOS_SDK}" -fuse-ld=lld -Wl,-platform_version,ios,${IOS_DEPLOYMENT_TARGET},16.5)
set(CMAKE_CXX_FLAGS_INIT "-stdlib=libc++")

# Cross-compile find behaviour: programs from host, libs/headers from SDK.
set(CMAKE_FIND_ROOT_PATH "${IOS_SDK}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# We cannot run iOS binaries on the Linux host.
set(CMAKE_CROSSCOMPILING TRUE)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)  # try_compile can't run; just link a lib
