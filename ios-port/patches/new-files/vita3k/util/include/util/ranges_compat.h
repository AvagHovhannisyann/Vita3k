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

#pragma once

// Apple's shipped libc++ (frozen to the Xcode/SDK release used to build the app) does not
// yet implement several C++23 <ranges> algorithms/adaptors that upstream libc++/libstdc++
// already ship (std::ranges::contains among them, as of the iOS 16.5 SDK / Xcode 14 libc++).
// This header provides a drop-in VITA3K_RANGES_CONTAINS(range, value) that falls back to a
// std::find-based implementation on Apple platforms, and simply forwards to
// std::ranges::contains everywhere else.
#include <algorithm>
#include <iterator>

#if defined(__APPLE__)
namespace vita3k::compat {
template <typename Range, typename T>
constexpr bool ranges_contains(Range &&r, const T &value) {
    return std::find(std::begin(r), std::end(r), value) != std::end(r);
}
} // namespace vita3k::compat
#define VITA3K_RANGES_CONTAINS(range, value) ::vita3k::compat::ranges_contains((range), (value))
#else
#include <ranges>
#define VITA3K_RANGES_CONTAINS(range, value) std::ranges::contains((range), (value))
#endif
