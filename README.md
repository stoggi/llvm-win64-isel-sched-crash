# LLVM Win64 instruction scheduler crash

This is an investigation into a LLVM crash observed when compiling a rust program with `--target x86_64-pc-windows-msvc`. Generative coding model Claude Code (Opus 5.5) was used to help perform the investigation. This repo is used as a reference for raising an issue with llvm/llvm-project and rust-lang/rust.

All the following is as-is, without warrenty, may not work, may not be correct, may contain inaccuracies or inconsistencies.

---

A ten-line Rust function that crashes rustc (and LLVM's `llc`) when it is
compiled with optimisation for 64-bit Windows.

When a Win64 call passes a `bool` on the stack whose value comes from
comparing a loaded value, and `sin()` feeds another argument in the same
block, LLVM's X86 instruction scheduler (`ScheduleDAGRRList`) runs out of
ways to order the block. Its last-resort path then treats its internal
"call in progress" marker (`CallResource`) as a real register, and the
register lookup goes out of range.


| Toolchain | LLVM | Result |
|---|---|---|
| rustc 1.95.0 | 22.1.2 | SIGSEGV |
| rustc 1.101.0-nightly | 23.1.4 | `LLVM ERROR: SmallVector unable to grow` |
| LLVM main (793ff02cdb35), assertions on | 24.0.0git | `getMinimalPhysRegClass`: `Assertion 'Reg < ArrayRef(Mapping).size()' failed` |

## The reproducer

[`src/lib.rs`](src/lib.rs):

```rust
unsafe extern "C" {
    fn callee(a: *const u8, b: *const u8, c: *const u8, x: f32, flag: bool);
}

pub fn repro(p: &u64, c: bool, x: f32, y: f32, a: *const u8, b: *const u8, d: *const u8) {
    let flag = *p != 0;
    let sel = if c { 0.8 } else { x };
    let sum = y.sin() + sel;
    unsafe { callee(a, b, d, sum, flag) };
}
```

## Triggering it with Rust

```sh
cargo build --release --target x86_64-pc-windows-msvc
```

which runs `cargo build --release --target x86_64-pc-windows-msvc`. It
works from any host, since only a library is built, and
`rust-toolchain.toml` installs rustc 1.95.0 and the Windows target. On a
Windows host, plain `cargo build --release` is enough.

A debug build (`cargo build`) succeeds, and so does a release build for
Linux: there the call uses the System V convention, which passes the
`bool` in a register.

To crash on Linux too, change the ABI from `"C"` to `"win64"` (the Windows
x64 calling convention) and run `cargo build --release`.

## Triggering it with LLVM

```sh
llc llvm/repro.reduced.ll -o /dev/null
```

`llvm/repro.reduced.ll` is `llvm-reduce`'s output for rustc's bitcode
(`llvm/repro.bc`); both carry the `x86_64-pc-windows-msvc` triple, so no
other options are needed. LLVM 22 and later crash on either file, with or
without `-relocation-model=pic` or `-relocation-model=static`. An `llc`
comes with rustup's `llvm-tools` component (`rustup component add
llvm-tools`), under `$(rustc --print sysroot)/lib/rustlib/<host>/bin/`.

## Making the test case

[`llvm/make-testcase.sh`](llvm/make-testcase.sh) regenerates
`llvm/repro.bc`, `llvm/repro.reduced.bc` and `llvm/repro.reduced.ll` from
`src/lib.rs`, following LLVM's guide for a code generator crash:

```sh
LLVM_BIN=/path/to/llvm-build/bin ./llvm/make-testcase.sh
```

```sh
rustc --edition 2024 --crate-type lib --target x86_64-pc-windows-msvc \
    -C opt-level=3 -C panic=abort -C debuginfo=0 \
    --emit=llvm-bc ../src/lib.rs -o repro.bc

llc repro.bc -o /dev/null                              # each must crash
llc repro.bc -relocation-model=pic -o /dev/null
llc repro.bc -relocation-model=static -o /dev/null
opt -O3 repro.bc -disable-output                       # must not

llvm-reduce -j $(nproc) --test=./reduce-test.sh repro.bc -o repro.reduced.bc
llvm-dis repro.reduced.bc -o repro.reduced.ll
```

It needs an LLVM build with assertions (for `llvm-reduce`, `llvm-dis`,
`not` and an `llc` that stops at the assertion), without a fix.
[`llvm/reduce-test.sh`](llvm/reduce-test.sh) keeps a candidate only if
`llc` still fails with the `getMinimalPhysRegClass` assertion, so the
reduction cannot drift onto a different crash.

## Files

| Path | What |
|---|---|
| `src/lib.rs` | The Rust reproducer |
| `Cargo.toml`, `rust-toolchain.toml` | Library crate; pins rustc 1.95.0 with the Windows target and `llvm-tools` |
| `repro.sh` | Triggers the crash with cargo |
| `llvm/repro.bc` | rustc's bitcode for `src/lib.rs` |
| `llvm/repro.reduced.bc`, `llvm/repro.reduced.ll` | `llvm-reduce`'s output for it |
| `llvm/make-testcase.sh` | Makes the three files above |
| `llvm/reduce-test.sh` | `llvm-reduce`'s interestingness test |
| `notes/` | The investigation: line-by-line walkthrough, root cause, issue drafts, a proposed LLVM fix with a regression test, and the game code that first hit it |
