#!/bin/bash
# Usage: compile_module_par.sh <module_name> [jobs]
# Parallel version of compile_module.sh using xargs -P.
set -u
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTDIR/env.sh"

MOD="$1"
JOBS="${2:-4}"
MODDIR="$V3K/$MOD"
LOGDIR="$SCRATCH/build/logs/$MOD"
OBJDIR="$SCRATCH/build/obj/$MOD"
mkdir -p "$LOGDIR" "$OBJDIR"

sources=$(bash "$SCRIPTDIR/list_sources.sh" "$MODDIR")

if [ -z "$sources" ]; then
  echo "MODULE $MOD: NO_SOURCES"
  exit 2
fi

compile_one() {
  src="$1"
  srcpath="$MODDIR/$src"
  if [ ! -f "$srcpath" ] && [ "$MOD" = "config" ] && [ "$(basename "$src")" = "version.cpp" ]; then
    srcpath="$SCRATCH/build/gen/config/version.cpp"
  fi
  if [ ! -f "$srcpath" ] && [ "$MOD" = "lang" ] && [ "$(basename "$src")" = "generated_catalog.cpp" ]; then
    srcpath="$SCRATCH/build/gen/lang_generated/generated_catalog.cpp"
  fi
  if [ ! -f "$srcpath" ]; then
    echo "SKIP $src"
    return 0
  fi
  objname=$(echo "$src" | tr '/' '_')
  case "$src" in
    *.mm)
      objpath="$OBJDIR/${objname%.mm}.o"
      logpath="$LOGDIR/${objname%.mm}.log"
      extra_flags="-x objective-c++ -fobjc-arc"
      ;;
    *)
      objpath="$OBJDIR/${objname%.cpp}.o"
      logpath="$LOGDIR/${objname%.cpp}.log"
      extra_flags=""
      ;;
  esac
  if clang++ $COMMON_FLAGS $INCLUDE_FLAGS -I"$MODDIR" $extra_flags -c "$srcpath" -o "$objpath" > "$logpath" 2>&1; then
    echo "OK $src"
  else
    echo "FAIL $src"
  fi
}
export -f compile_one
export MOD MODDIR LOGDIR OBJDIR COMMON_FLAGS INCLUDE_FLAGS SCRATCH

echo "$sources" | xargs -P "$JOBS" -I{} bash -c 'compile_one "$@"' _ {} > "$SCRATCH/build/logs/${MOD}_summary.txt" 2>&1

ok=$(grep -c '^OK' "$SCRATCH/build/logs/${MOD}_summary.txt")
fail=$(grep -c '^FAIL' "$SCRATCH/build/logs/${MOD}_summary.txt")
skip=$(grep -c '^SKIP' "$SCRATCH/build/logs/${MOD}_summary.txt")
echo "MODULE $MOD: ok=$ok fail=$fail skip=$skip"
if [ "$fail" -gt 0 ]; then
  echo "  failed files:"
  grep '^FAIL' "$SCRATCH/build/logs/${MOD}_summary.txt" | sed 's/^FAIL /    /'
fi
