#!/usr/bin/env bash
# Run the IR reproducers through the llc that ships with the active Rust
# toolchain (`rustup component add llvm-tools`), or $LLC if set.
set -u
cd "$(dirname "$0")"
LLC="${LLC:-$(rustc --print sysroot)/lib/rustlib/$(rustc -vV | sed -n 's/^host: //p')/bin/llc}"
if [[ ! -x "$LLC" ]]; then
    echo "no llc at $LLC: run 'rustup component add llvm-tools' or set LLC" >&2
    exit 2
fi
"$LLC" --version | sed -n 's/^ *LLVM version /LLVM /p'
check() {
    local file=$1 triple=$2
    # In a subshell with stderr closed, so bash's own "Segmentation fault"
    # job notice does not land between the results.
    local rc
    rc=$(exec 2>/dev/null; "$LLC" -O3 -mtriple="$triple" -filetype=obj -o /dev/null "$file" >/dev/null; echo $?)
    local what=ok
    if (( rc >= 128 || rc == 134 )); then what="CRASH (exit $rc)"; elif (( rc != 0 )); then what="error (exit $rc)"; fi
    printf '%-20s %-28s %s\n' "$file" "$triple" "$what"
}
check repro.ll         x86_64-pc-windows-msvc
check repro.ll         x86_64-pc-windows-gnu
check repro.ll         x86_64-unknown-linux-gnu
check repro.ll         i686-pc-windows-msvc
check repro-win64cc.ll x86_64-unknown-linux-gnu
