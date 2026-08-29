#!/bin/bash
# Extract .cpp/.mm source paths listed in a module's CMakeLists.txt (heuristic: any token ending in .cpp/.mm)
mod_dir="$1"
grep -oE '[A-Za-z0-9_./-]+\.(cpp|mm)' "$mod_dir/CMakeLists.txt" | sort -u | grep -v '^tests/'
