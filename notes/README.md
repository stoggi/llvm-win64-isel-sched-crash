# LLVM Win64 instruction scheduler crash

> **Investigation notes.** This is the original, long README, kept for the
> detail. The minimal example is in the repository root (see `../README.md`).
> Since this was written the repository was tidied: `src/lib.rs` no longer
> has `#[unsafe(no_mangle)]` or the `win64-anywhere` feature (change the ABI
> to `"win64"` instead), the test case files are in `../llvm/`, and
> `repro.ll`, `repro-win64cc.ll`, `repro-from-rust.ll`, `run-llc.sh`,
> `emit-ir.sh` and the fix patch are in `notes/llvm/`; `king-cape/` is in
> `notes/king-cape/`.

An eleven-line Rust function that crashes rustc when it is compiled with
optimisation for 64-bit Windows. The crash is inside LLVM, in the X86
instruction scheduler, and is triggered by one call shape under the Win64
calling convention: a `bool` passed on the stack, in the same basic block
as a `sin()` whose result feeds another argument.

| Toolchain | LLVM | Result |
|---|---|---|
| rustc 1.95.0 (2026-04-14) | 22.1.2 | `rustc interrupted by SIGSEGV` (null pointer read in `ScheduleDAGRRList::Schedule`) |
| rustc 1.101.0-nightly | 23.1.4 | `LLVM ERROR: SmallVector unable to grow. Requested capacity (4294967296) ...` |

Debug builds (`opt-level = 0`) and `cargo check` are unaffected. The code
is valid; nothing about it is undefined behaviour.

Found while building a rust and bevy game for Windows: its
release container (`cargo xwin build --release --target
x86_64-pc-windows-msvc`) died on the cape animation code. Linux builds of
the same commit were fine.

## Triggering it

### On Windows

Install Rust with [rustup](https://rustup.rs) (the default MSVC host
toolchain). The `rust-toolchain.toml` here pins rustc 1.95.0 and rustup
fetches it on first use. Then, in PowerShell or cmd:

```powershell
cd llvm-win64-isel-sched-crash
cargo build --release
```

rustc crashes compiling the library. On a Windows host the failure shows
as an access violation, for example
`(exit code: 0xc0000005, STATUS_ACCESS_VIOLATION)`. Only the library is
built, so no linker or Visual Studio install is involved. (Tested by
cross-compiling from Linux; the native Windows output is expected but has
not been checked on a Windows machine.)

For comparison, both of these succeed:

```
cargo build          # debug build
cargo check
```

### On Linux or macOS (cross-compiling for Windows)

The toolchain file also installs the `x86_64-pc-windows-msvc` target.
Building a library for it needs no Windows linker:

```sh
cargo build --release --target x86_64-pc-windows-msvc
```

Output (paths shortened):

```text
error: rustc interrupted by SIGSEGV, printing backtrace

librustc_driver-6108105cd7e839cf.so(+0x3b62e1c)
/usr/lib/libc.so.6(+0x3e6f0)
libLLVM.so.22.1-rust-1.95.0-stable(+0x9289e28)
libLLVM.so.22.1-rust-1.95.0-stable(_ZN4llvm16SelectionDAGISel17CodeGenAndEmitDAGEv+0xe0a)
libLLVM.so.22.1-rust-1.95.0-stable(_ZN4llvm16SelectionDAGISel20SelectAllBasicBlocksERKNS_8FunctionE+0x1746)
...
note: we would appreciate a report at https://github.com/rust-lang/rust
help: you can increase rustc's stack size by setting RUST_MIN_STACK=16777216
```

The stack size hint is a red herring: rustc prints it for every SIGSEGV.
This is not a stack overflow, and raising the stack changes nothing.

### On any x86-64 host, without Windows at all

The `win64-anywhere` feature declares the callee `extern "win64"`, Rust's
name for the Win64 calling convention. The crash then happens when
building for the host's own target:

```sh
cargo build --release --features win64-anywhere
```

### Getting the IR from the Rust code

`llvm/emit-ir.sh` runs rustc with `--emit=llvm-ir` (for
`x86_64-pc-windows-msvc` at `opt-level=3`, no debug info) and prints the
crashing function:

```sh
./llvm/emit-ir.sh                                                # -> llvm/repro-from-rust.ll
./llvm/emit-ir.sh king-cape/src/lib.rs llvm/king-cape-from-rust.ll
TARGET=x86_64-unknown-linux-gnu OPT=0 ./llvm/emit-ir.sh          # other targets and levels
```

It calls rustc directly because cargo skips the compile when the crate is
already built. The command it runs:

```sh
rustc --edition 2024 --crate-type lib --target x86_64-pc-windows-msvc \
    -C opt-level=3 -C panic=abort -C debuginfo=0 \
    --emit=llvm-ir src/lib.rs -o llvm/repro-from-rust.ll
```

`llvm/repro-from-rust.ll` is its output, kept for reference;
`llc -O3 -filetype=obj -o /dev/null llvm/repro-from-rust.ll` crashes on it
too (the triple is inside the file).

To watch the scheduler get stuck, an `llc` built with assertions (a stock
release build has no debug output) prints the scheduling units and every
decision:

```sh
llc -O3 -mtriple=x86_64-pc-windows-msvc -filetype=obj -o /dev/null \
    -debug-only=pre-RA-sched llvm/repro.ll
```

### On Linux, with Linux's own calling convention

Not reachable this way, as far as I found. The crash needs the compare's
result stored as a single byte straight into a stack argument slot
(`SETCCm` inside the call sequence). The System V convention
(`CC_X86_64_C`) widens `i1`, `i8` and `i16` stack arguments to 32 bits, so
the value is set into a register first (`SETCCr`, no chain) and stored with
a plain `movl`; the flags never have to cross `ADJCALLSTACKDOWN64`. Win64
(`CC_X86_Win64_C`) only widens `i1` to `i8`, so it stores the byte.

Calling conventions that follow the Win64 argument rules do trigger it on
`x86_64-unknown-linux-gnu`. Every x86 convention LLVM accepts was tried
against an assertions build of LLVM main; only these reach the assertion:

| On x86_64 Linux | LLVM IR | Rust |
|---|---|---|
| Win64 | `win64cc` | `extern "win64"` (stable), `extern "efiapi"` (stable) |
| vectorcall | `x86_vectorcallcc` | `extern "vectorcall"` (nightly, `abi_vectorcall`) |
| System V (default), `sysv64`, `fastcc`, `coldcc`, swift, tail, preserve, GHC, HiPE, regcall | | no crash |

`extern "efiapi"` is the realistic one: it is how Rust code running on
Linux targets declares UEFI firmware calls.

### With LLVM alone

`llvm/repro.ll` is the same function as LLVM IR. `llvm/run-llc.sh` runs it
through the `llc` that ships with the pinned toolchain (`llvm-tools`,
installed by the toolchain file) for several targets:

```text
$ ./llvm/run-llc.sh
LLVM 22.1.2-rust-1.95.0-stable
repro.ll             x86_64-pc-windows-msvc       CRASH (exit 139)
repro.ll             x86_64-pc-windows-gnu        CRASH (exit 139)
repro.ll             x86_64-unknown-linux-gnu     ok
repro.ll             i686-pc-windows-msvc         ok
repro-win64cc.ll     x86_64-unknown-linux-gnu     CRASH (exit 139)
```

Or by hand: `llc -O3 -mtriple=x86_64-pc-windows-msvc repro.ll`.

`repro-win64cc.ll` targets Linux but marks the one call `win64cc`. It
crashes the same way, which pins the trigger on the Win64 calling
convention rather than on anything else about the Windows target.

## The reproducer

```rust
unsafe extern "C" {
    fn callee(a: *const u8, b: *const u8, c: *const u8, x: f32, flag: bool);
}

#[unsafe(no_mangle)]
pub fn repro(p: &u64, c: bool, x: f32, y: f32, a: *const u8, b: *const u8, d: *const u8) {
    let flag = *p != 0;               // a bool from comparing a loaded value
    let sel = if c { 0.8 } else { x }; // a select
    let sum = y.sin() + sel;           // sin(), added to the select
    unsafe { callee(a, b, d, sum, flag) }; // flag is the fifth argument
}
```

Under the Win64 calling convention the first four arguments travel in
registers, one slot each whether integer or float (`RCX`, `RDX`, `R8`,
`XMM3` here), and the fifth goes on the stack above the 32-byte shadow
space. So `flag` is stored to the stack while `sum` is in a register. On
Linux (System V) there are six integer and eight float argument registers,
so the same call passes everything in registers.

## The same crash in the game's own code

`king-cape/` is a second crate with the code that actually hit this: the
per-frame pose for a king's cape, with the game's types, constants and
arithmetic (only the spring physics behind the call is simplified).

```sh
cd king-cape
cargo build --release --target x86_64-pc-windows-msvc                      # crashes
cargo build --release --target x86_64-pc-windows-msvc --features cape-wind # the game's fix: builds
```

Every piece of the 11-line reproducer is something the cape code does:

| Reproducer | King's cape (`pose_cape`) |
|---|---|
| `let flag = *p != 0;` | `let drape = mount.is_some();` where `mount: Option<Accessory>` keeps "no mount" as `i64::MIN` in the `Vec` capacity, so it is a load and `icmp ne i64 %v, -9223372036854775808` |
| `y.sin()` | `(beat * 2.0).sin()` and `beat.sin()`: the stride pump and sway |
| `if c { 0.8 } else { x }` | `.clamp(0.0, CAPE_TRAIL_MAX)`, `CAPE_TRAIL_MAX` being `0.8`; LLVM merges it with the `CAPE_TURN_MAX` clamp into a `<2 x float>` select |
| `sum = y.sin() + sel` | `trail = clamp(...) + pump`, `sideways = clamp(...) + sway` |
| `callee(a, b, d, sum, flag)` | `swing_cape(cape_swing, &pieces, dt, trail, sideways, stir, drape)`: with the 392-byte return slot, ten machine arguments, the `bool` last on the stack |

The fix the game shipped, `CapeWind`, passes `dt`, `trail`, `sideways`,
`stir` and `drape` as one struct by reference, so `drape` is no longer a
stack argument and no `SETCCm` lands inside the call sequence.

## What it takes to crash

Starting from `llvm/repro.ll`, each row changes one thing and records
whether `llc -O3 -mtriple=x86_64-pc-windows-msvc` still crashes.

| Change | Crashes? |
|---|---|
| none (the reproducer) | yes |
| `llvm.sin.f32` replaced by a call to an opaque function | no |
| `llvm.sin.f32` replaced by an explicit `call @sinf` | no |
| the select removed (`sum = sin(y) + x`) | no |
| pass `sin(y)` alone, without the add | no |
| pass the select alone, without the add | no |
| `flag` taken straight from a parameter | no |
| `flag` from comparing two parameters (no load) | no |
| `flag` from comparing the loaded value with a different constant | yes |
| the select's condition is `flag` itself | no |
| only four arguments, so everything is in registers | no |
| `flag` in a register (third), the float on the stack | no |
| the call's `bool` marked `zeroext`, or the call given an `sret` return | yes (not needed) |
| target `x86_64-pc-windows-gnu` (MinGW, same Win64 convention) | yes |
| target `i686-pc-windows-msvc` | no |
| target `x86_64-unknown-linux-gnu`, even with `flag` pushed to the stack as a seventh integer argument | no |
| target `x86_64-unknown-linux-gnu` with the call marked `win64cc` | yes |
| `-O0` | no |
| `-O1`, `-O2`, `-O3` | yes |
| `-pre-RA-sched=source`, `list-burr` or `list-ilp` (the `ScheduleDAGRRList` family) | yes |
| `-pre-RA-sched=fast` (a separate scheduler implementation) | no |

Needed, then, all together:

1. a call using the Win64 calling convention, with a `bool` among the
   arguments passed on the stack;
2. that `bool` produced by comparing a value loaded from memory;
3. in the same block, the `llvm.sin.f32` intrinsic, whose result, added to
   a `select`, is another argument of the call.

## What goes wrong

### Root cause (confirmed on an assertions build of LLVM main)

An assertions build of `llc` from main stops with
`getMinimalPhysRegClass(...): Assertion 'Reg < ArrayRef(Mapping).size()'
failed`, and `-debug-only=pre-RA-sched` shows why:

1. The compare producing the `bool` folds the load of `*p`, so it is
   chained *before* the outer call's `ADJCALLSTACKDOWN64`. Its `EFLAGS` are
   read by the `SETCCm` that stores the `bool` into the stack argument slot,
   which is *after* `ADJCALLSTACKDOWN64`. That pseudo clobbers `EFLAGS`, so
   as built, the flags would have to live across a node that destroys them.
   Only the scheduler's last-resort path (duplicate or unfold the compare,
   or copy `EFLAGS`) can fix that.
2. The `sinf` libcall from `llvm.sin.f32` is chained only to the entry
   token, so its call sequence is ready while the outer one is open and
   waits on the scheduler's pseudo-register for call sequences,
   `CallResource`.
3. With both stuck, the last-resort path in `PickNodeToScheduleBottomUp`
   takes the *first* pending node, which is the libcall's, and treats
   `CallResource` (`TRI->getNumRegs()`, one past the last real register) as
   a physical register. The register-class lookup is out of range: an
   assertion with assertions on, a garbage register class and a null read
   (LLVM 22) or a runaway list (LLVM 23) without.

`llvm/fix-scheduledagrrlist.patch` makes that path skip call-resource
interferences and resolve the real `EFLAGS` one; LLVM then splits the
compare's load back out, as the `fast` scheduler also does (though it
places the load after the `sinf` call). With the patch, LLVM's 5762 X86
code generation tests still pass, a release build of main compiles the
reproducer and the game's original function (unpatched, it fails with
`SmallVector unable to grow`), and the patch's new regression test fails
without the change. The sections below are the investigation that led there.

### Where it crashes

In instruction selection, LLVM builds a graph of each basic block's
operations, legalises it for the target, then orders it with the "pre-RA"
scheduler before emitting machine instructions. The crash is in that
ordering step. Under gdb, LLVM 22.1.2 faults in
`(anonymous namespace)::ScheduleDAGRRList::Schedule()` at
`mov 0x18(%rax),%r11d` with `rax == 0`: it takes a pointer from one of the
scheduler's tables and reads through it while it is null. The backtrace
is five frames deep, so this is not a recursion or a stack overflow.

All three schedulers built on `ScheduleDAGRRList` (`source`, `list-burr`,
`list-ilp`) crash; `-pre-RA-sched=fast`, a separate implementation,
compiles the function. LLVM 23.1.4 no longer reads the null pointer but
grows a list without bound until it aborts, so the fault is still there.

### What the block looks like to the scheduler

The IR that reaches instruction selection is one basic block (as printed
after CodeGenPrepare). Inside it, at scheduling time:

- **The `select`** becomes a `CMOV_FR32` pseudo-instruction: x86 has no
  conditional move between float registers, so LLVM selects a pseudo that
  reads `EFLAGS` (from `testb $1, %bl` on `c`) and only expands it into a
  branch after scheduling. That is the `je .LBB0_2` in the output below.
- **The `bool`** is stored by a `SETcc` straight into the fifth argument's
  stack slot, `setne 32(%rsp)`, reading `EFLAGS` from a compare of the
  loaded value. Under System V the `bool` goes in a register instead, and
  the compare and `setne` happen early, before any call (Linux output:
  `cmpq $0, (%rdi); setne %r12b`, kept in a callee-saved register).
- **`llvm.sin.f32`** is not a call in the IR. It enters as an `fsin` node
  and becomes a `sinf` libcall when the legaliser expands it. That call
  clobbers `EFLAGS`, and it is not ordered against the rest of the block
  by anything but its data: its result feeds the outer call's argument.
  An explicit `call @sinf` in the IR is lowered in place, already ordered
  before the outer call, and does not crash.

So the scheduler has to order two `EFLAGS` producers and their consumers,
one of them a store into the outer call's argument area, around a call
that clobbers `EFLAGS` and is free to land anywhere before its use. This
is the part of `ScheduleDAGRRList` that tracks physical register live
ranges and call sequences (`LiveRegDefs`, `LiveRegGens`, the call
resource), and where it can clone or unfold a node, for example splitting
the compare's folded load back out. The `fast` scheduler resolves it by
doing just that:

```text
; llc -O3 -pre-RA-sched=fast -mtriple=x86_64-pc-windows-msvc repro.ll
    movaps  %xmm3, %xmm0
    ...
    callq   sinf
    movq    (%rsi), %rax          ; the load, moved after the call
    testb   $1, %bl               ; flags for the select...
    je      .LBB0_2               ; ...expanded to a branch
    movss   __real@3f4ccccd(%rip), %xmm6
.LBB0_2:
    testq   %rax, %rax            ; flags for the bool
    addss   %xmm6, %xmm0
    movq    144(%rsp), %r8        ; outgoing arguments, from incoming stack args
    movq    136(%rsp), %rdx
    setne   32(%rsp)              ; the bool, set straight into the stack slot
    movq    128(%rsp), %rcx
    movaps  %xmm0, %xmm3
    callq   callee
```

Exactly which bookkeeping loses the node was not established; that needs
a debug build of LLVM. The ablation table above matches this picture:
take away the `select` (one `EFLAGS` consumer), the compare (the other
producer), the stack slot (System V, or fewer arguments), or the
free-floating libcall (explicit `call @sinf`), and it compiles. LLVM has
fixed a neighbouring problem before: [D31536](https://reviews.llvm.org/D31536)
dealt with several `CALLSEQ_BEGIN`s pending at once in `DelayForLiveRegs`.

## How it was found

1. The Windows release container build of the game crashed with the
   SIGSEGV above; the Linux build of the same commit did not.
2. A 64 MiB `RUST_MIN_STACK`, as the hint suggests, changed nothing.
3. Reproduced locally by cross-compiling the game's library for
   `x86_64-pc-windows-msvc` (a library build needs no MSVC linker; the
   `blake3` dependency needed `CARGO_FEATURE_PURE=1` to skip its MSVC
   assembler).
4. `RUSTC_BOOTSTRAP=1 ... -Z no-parallel-backend -C
   llvm-args=-debug-pass=Executions` printed each function as LLVM
   compiled it; the last before the crash was a per-unit animation
   closure. (With 16 codegen units in parallel the log interleaves
   unreadably, and with one codegen unit the crash disappeared, because
   the different partitioning changed what was inlined.)
5. `-C save-temps` kept the per-codegen-unit bitcode; `llc` reproduced
   the crash on it, and on a module cut down to that one function.
6. A delta reducer, then hand ablation, brought it down to
   `llvm/repro.ll`, and the Rust source was written to produce the same
   IR.

## Working around it

Change the call so the trigger is gone. In the game the call passed
`(swing, pieces, dt, trail, sideways, stir, drape)` and a 392-byte return
value; the five floats and the `bool` went on the stack. Passing them as
one struct by reference fixed the build:

```rust
struct CapeWind { dt: f32, trail: f32, sideways: f32, stir: (f32, f32), drape: bool }
fn swing_cape(swing: &mut CapeSwing, pieces: &[Piece], wind: &CapeWind) -> (...)
```

Other ways out of the table above: keep the `bool` within the first four
arguments, compute it from something other than a fresh load, or move
the `sin()` out of the block (for example into a non-inlined helper, so
it becomes an ordinary call). Raising `RUST_MIN_STACK` does not help.

The bug remains in LLVM, so another function with the same shape can hit
it later.

## Files

| Path | What |
|---|---|
| `WALKTHROUGH.md` | Line by line: each Rust line, its IR, and how it sets up the crash |
| `src/lib.rs` | The Rust reproducer (`extern "C"`, or `extern "win64"` with `--features win64-anywhere`) |
| `king-cape/` | The crash in the game's own shape (a king's cape), with `--features cape-wind` for the shipped fix |
| `Cargo.toml` | Library crate; the `win64-anywhere` feature |
| `rust-toolchain.toml` | Pins rustc 1.95.0, adds the Windows target and `llvm-tools` |
| `llvm/repro.ll` | The same function as LLVM IR |
| `llvm/repro-win64cc.ll` | The IR for a Linux triple, with the call marked `win64cc` |
| `llvm/run-llc.sh` | Runs both through the toolchain's `llc` for several targets |
| `llvm/llvm-reduce/` | rustc's bitcode for `src/lib.rs` (`repro.bc`), its `llvm-reduce` output (`repro.reduced.bc`, `repro.reduced.ll`), the interestingness test `reduce-test.sh`, and `make-testcase.sh`, which runs every step that made them |
| `llvm/emit-ir.sh` | Emits rustc's LLVM IR for a reproducer (Windows target, `opt-level=3` by default) |
| `llvm/repro-from-rust.ll` | That IR for `src/lib.rs`, as rustc 1.95.0 emits it |
| `llvm/fix-scheduledagrrlist.patch` | Proposed LLVM fix plus a regression test, against main 793ff02cdb35 |
| `issues/llvm.md` | Draft issue for llvm/llvm-project |
| `issues/rust.md` | Draft issue for rust-lang/rust (ICE template) |

## Reporting it

`issues/llvm.md` follows LLVM's bug-reporting guide for a code generator
crash, with a test case made purely from `src/lib.rs`.
`llvm/llvm-reduce/make-testcase.sh` runs every step:

1. rustc's bitcode for `src/lib.rs` (`repro.bc`);
2. the guide's three `llc` commands (no extra options,
   `-relocation-model=pic`, `-relocation-model=static`), which must crash;
3. `opt -O3`, which must not;
4. `llvm-reduce` with `reduce-test.sh`, which only accepts the
   `getMinimalPhysRegClass` assertion (`repro.reduced.bc`);
5. `llvm-dis` (`repro.reduced.ll`).

```sh
LLVM_BIN=/path/to/llvm-build/bin ./llvm/llvm-reduce/make-testcase.sh
```

It needs an LLVM build with assertions and without the fix. The draft
lists the files to attach. `issues/rust.md` is the matching
rust-lang/rust report.
