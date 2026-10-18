#!/usr/bin/env bash
# Build the LLVM bug report's test case from src/lib.rs, following LLVM's
# guide for a code generator crash:
#
#   1. rustc's bitcode for src/lib.rs                    -> repro.bc
#   2. the guide's three llc commands, which must crash
#   3. opt -O3, which must not
#   4. llvm-reduce with reduce-test.sh                    -> repro.reduced.bc
#   5. llvm-dis                                           -> repro.reduced.ll
#
# Needs rustc 1.95.0 with the x86_64-pc-windows-msvc target (the repo's
# rust-toolchain.toml installs both) and an LLVM build with assertions and
# without the fix, for llc, opt, llvm-reduce, llvm-dis and not:
#
#   LLVM_BIN=/path/to/llvm-build/bin ./make-testcase.sh
#
# LLC overrides the llc used (default $LLVM_BIN/llc).
set -euo pipefail
cd "$(dirname "$0")"
: "${LLVM_BIN:?set LLVM_BIN to the bin directory of an LLVM build with assertions, without the fix}"
export LLC="${LLC:-$LLVM_BIN/llc}" NOT="$LLVM_BIN/not"

# 1. The equivalent of clang's -emit-llvm -c, at opt-level 3 as --release.
rustc --edition 2024 --crate-type lib --target x86_64-pc-windows-msvc \
    -C opt-level=3 -C panic=abort -C debuginfo=0 \
    --emit=llvm-bc ../src/lib.rs -o repro.bc

# 2. The bitcode carries its triple, so no -mtriple is needed.
# Each in a subshell with stderr closed, so bash's own "Aborted" notice
# stays out of the output.
for rm in "" -relocation-model=pic -relocation-model=static; do
    rc=$(exec 2>/dev/null; "$LLC" repro.bc $rm -o /dev/null; echo $?)
    if [[ $rc == 0 ]]; then
        echo "llc repro.bc $rm: compiled, expected a crash" >&2
        exit 1
    fi
    echo "llc repro.bc $rm: crashed (exit $rc)"
done

# 3. Not a middle-end crash.
"$LLVM_BIN/opt" -O3 repro.bc -disable-output
echo "opt -O3 repro.bc -disable-output: ok"

# 4 and 5.
"$LLVM_BIN/llvm-reduce" -j "$(nproc)" --test=./reduce-test.sh repro.bc -o repro.reduced.bc
"$LLVM_BIN/llvm-dis" repro.reduced.bc -o repro.reduced.ll
rm -f ./*.err
echo "wrote repro.bc, repro.reduced.bc, repro.reduced.ll"
