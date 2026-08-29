/* speexdsp_types.h — minimal stand-in for the header speexdsp's build system
 * normally generates from speexdsp_types.h.in via autoconf/CMake type
 * detection. That generation step is absent from this vendored
 * subprojects/speex/ checkout (bundled into cubeb), so this hand-written
 * replacement supplies the same fixed-width typedefs directly via <stdint.h>
 * — equivalent on any platform with a C99 stdint.h, which iOS/Clang has. */
#ifndef SPEEXDSP_TYPES_H
#define SPEEXDSP_TYPES_H

#include <stdint.h>

typedef int16_t spx_int16_t;
typedef uint16_t spx_uint16_t;
typedef int32_t spx_int32_t;
typedef uint32_t spx_uint32_t;

#endif
