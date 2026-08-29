#!/bin/bash
# Usage: compile_module.sh <module_name>
# Compiles all .cpp sources declared in vita3k/<module>/CMakeLists.txt for arm64-iOS.
set -u
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTDIR/env.sh"

MOD="$1"
MODDIR="$V3K/$MOD"
LOGDIR="$SCRATCH/build/logs/$MOD"
OBJDIR="$SCRATCH/build/obj/$MOD"
mkdir -p "$LOGDIR" "$OBJDIR"

sources=$(bash "$SCRIPTDIR/list_sources.sh" "$MODDIR")

if [ -z "$sources" ]; then
  echo "MODULE $MOD: NO_SOURCES"
  exit 2
fi

ok=0
fail=0
failed_files=()
for src in $sources; do
  srcpath="$MODDIR/$src"
  if [ ! -f "$srcpath" ] && [ "$MOD" = "config" ] && [ "$(basename "$src")" = "version.cpp" ]; then
    srcpath="$SCRATCH/build/gen/config/version.cpp"
  fi
  if [ ! -f "$srcpath" ] && [ "$MOD" = "lang" ] && [ "$(basename "$src")" = "generated_catalog.cpp" ]; then
    srcpath="$SCRATCH/build/gen/lang_generated/generated_catalog.cpp"
  fi
  if [ ! -f "$srcpath" ]; then
    echo "  [skip-missing] $src"
    continue
  fi
  objname=$(echo "$src" | tr '/' '_')
  objpath="$OBJDIR/${objname%.cpp}.o"
  logpath="$LOGDIR/${objname%.cpp}.log"
  if clang++ $COMMON_FLAGS $INCLUDE_FLAGS -I"$MODDIR" -c "$srcpath" -o "$objpath" > "$logpath" 2>&1; then
    ok=$((ok+1))
  else
    fail=$((fail+1))
    failed_files+=("$src")
  fi
done

echo "MODULE $MOD: ok=$ok fail=$fail"
if [ "$fail" -gt 0 ]; then
  echo "  failed: ${failed_files[*]}"
fi
