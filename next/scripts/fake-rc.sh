#!/bin/sh
# A stand-in for llvm-rc, for `cargo check` against Windows from the Mac only: it writes an
# empty resource file where the real compiler would put one. Nothing is linked by a check, and a
# real Windows build runs on Windows with rc.exe. It answers "/?" the way llvm-rc does, which is
# how the build recognizes a resource compiler.
for a in "$@"; do
  if [ "$a" = "/?" ]; then
    echo "OVERVIEW: LLVM Resource Converter (stand-in; supports /no-preprocess)"
    exit 0
  fi
done
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    /fo|-fo|/FO|-FO) out="$2"; shift ;;
  esac
  shift
done
[ -n "$out" ] && : > "$out"
exit 0
