#!/bin/bash
# Usage: archive_module.sh <module_name>
# Archives all .o files for a module into build/lib/lib<module>.a using
# llvm-libtool-darwin (produces a real Mach-O static archive, unlike GNU ar).
set -u
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTDIR/env.sh"
export PATH=/home/user/iosbin:$PATH

MOD="$1"
OBJDIR="$SCRATCH/build/obj/$MOD"
LIBDIR="$SCRATCH/build/lib"
mkdir -p "$LIBDIR"

objs=$(find "$OBJDIR" -name "*.o" 2>/dev/null | sort)
if [ -z "$objs" ]; then
  echo "ARCHIVE $MOD: NO_OBJECTS"
  exit 2
fi

libtool -static -o "$LIBDIR/lib${MOD}.a" $objs 2>&1
if [ $? -eq 0 ]; then
  n=$(echo "$objs" | wc -l)
  echo "ARCHIVE $MOD: OK ($n objects) -> lib${MOD}.a"
else
  echo "ARCHIVE $MOD: FAILED"
fi
