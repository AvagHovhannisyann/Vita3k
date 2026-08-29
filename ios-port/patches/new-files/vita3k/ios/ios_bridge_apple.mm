// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

// ios_bridge_apple.mm — the ONLY Objective-C++ file in this bridge. It talks
// to Foundation/QuartzCore and nothing else, and is deliberately kept free of
// any vita3k core header.
//
// WHY THE SPLIT: <Foundation/Foundation.h> drags in (via CoreFoundation)
// <MacTypes.h>, which unconditionally does `typedef char *Ptr;` at global
// scope on this SDK. vita3k's mem/include/mem/ptr.h declares its own
// `template <class T> class Ptr` at global scope too (see mem/ptr.h) --
// there is no include order that makes both visible in the same translation
// unit, it's a hard redefinition error either way. So Apple-framework code
// and vita3k-core-header code are kept in separate .mm/.cpp files here, each
// exposing a small extern "C" surface to the other -- vita3k_ios_bridge.cpp
// (the file that actually drives app::init/AppSessionController/etc, and
// therefore must include mem/ptr.h transitively) never sees Foundation.h,
// and this file never sees a vita3k header.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#include <cstdlib>
#include <cstring>

extern "C" {

// Caller-owned: the returned pointer is heap-allocated (strdup) and must be
// freed by the caller. These are each called once, at one-time bridge init,
// so that's a non-issue in practice.
char *ios_bridge_copy_documents_vita3k_path(void) {
    @autoreleasepool {
        NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = dirs.firstObject;
        if (docs.length == 0)
            return nullptr;
        // MUST match Vita3KCore.m's -dataRoot exactly (see e.g.
        // GameDetailViewController, which scans ux0:/app under this same
        // path) so the front end's idea of "where titles live" and the
        // core's idea of what ux0:/ resolves to are the same directory.
        NSString *root = [docs stringByAppendingPathComponent:@"vita3k"];
        return strdup(root.UTF8String);
    }
}

char *ios_bridge_copy_bundle_resource_path(void) {
    @autoreleasepool {
        NSString *path = [[NSBundle mainBundle] resourcePath];
        if (path.length == 0)
            return nullptr;
        return strdup(path.UTF8String);
    }
}

// Fills *out_w / *out_h with the CAMetalLayer's drawable size in pixels
// (falling back to its bounds * contentsScale, then to the PS Vita's native
// 960x544 if metal_layer is null or isn't a CAMetalLayer yet). metal_layer
// is the same opaque pointer vita3k_ios_boot() receives from
// Vita3KCore.m's `(__bridge void *)layer`.
void ios_bridge_metal_drawable_size(void *metal_layer, int *out_w, int *out_h) {
    int width = 960, height = 544;
    if (metal_layer) {
        CALayer *layer = (__bridge CALayer *)metal_layer;
        if ([layer isKindOfClass:[CAMetalLayer class]]) {
            CAMetalLayer *ml = (CAMetalLayer *)layer;
            CGSize size = ml.drawableSize;
            if (size.width > 0 && size.height > 0) {
                width = (int)size.width;
                height = (int)size.height;
            }
        }
        if (width == 960 && height == 544) {
            CGSize bounds_size = layer.bounds.size;
            CGFloat scale = layer.contentsScale > 0 ? layer.contentsScale : 1.0;
            if (bounds_size.width > 0 && bounds_size.height > 0) {
                width = (int)(bounds_size.width * scale);
                height = (int)(bounds_size.height * scale);
            }
        }
    }
    if (out_w)
        *out_w = width;
    if (out_h)
        *out_h = height;
}

} // extern "C"
