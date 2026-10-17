#!/usr/bin/env bash
# Emit the LLVM IR rustc generates for a reproducer, before code
# generation, so it can be read or fed to llc.
#
#   ./llvm/emit-ir.sh                     # src/lib.rs -> llvm/repro-from-rust.ll
#   ./llvm/emit-ir.sh king-cape/src/lib.rs llvm/king-cape-from-rust.ll
#
# TARGET and OPT override the target triple and optimisation level
# (default x86_64-pc-windows-msvc and 3; the crash needs OPT >= 1).
# Runs rustc directly rather than through cargo, which would skip the
# compile when the crate is already built. Debug info is left out to keep
# the IR readable.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${1:-src/lib.rs}"
OUT="${2:-llvm/repro-from-rust.ll}"
TARGET="${TARGET:-x86_64-pc-windows-msvc}"
OPT="${OPT:-3}"
rustc --edition 2024 --crate-type lib --target "$TARGET" \
    -C opt-level="$OPT" -C panic=abort -C debuginfo=0 \
    --emit=llvm-ir "$SRC" -o "$OUT"
echo "wrote $OUT ($TARGET, opt-level $OPT)"
# The function the crash is in, for a quick look:
sed -n '/^define.*@\(repro\|pose_cape\)(/,/^}/p' "$OUT"
