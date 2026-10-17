<!-- File at https://github.com/rust-lang/rust/issues/new?template=ice.md
     (the "Internal Compiler Error" template). File the LLVM issue first
     and link it below; maintainers usually label these A-LLVM, I-crash,
     O-windows and pick up the fix when it lands upstream. -->

**Title:** rustc segfaults in LLVM's X86 scheduler (`ScheduleDAGRRList`) on a Win64 call passing a `bool` on the stack next to `f32::sin`

---

### Code

```rust
unsafe extern "C" {
    fn callee(a: *const u8, b: *const u8, c: *const u8, x: f32, flag: bool);
}

#[unsafe(no_mangle)]
pub fn repro(p: &u64, c: bool, x: f32, y: f32, a: *const u8, b: *const u8, d: *const u8) {
    let flag = *p != 0;
    let sel = if c { 0.8 } else { x };
    let sum = y.sin() + sel;
    unsafe { callee(a, b, d, sum, flag) };
}
```

A library crate with just this file. Then:

```sh
cargo build --release --target x86_64-pc-windows-msvc
```

No linker is involved (it is a library), so this reproduces from any
host with the target installed. With the callee declared
`extern "win64"` instead of `extern "C"`, it also crashes when building
for `x86_64-unknown-linux-gnu`.

Debug builds and `cargo check` succeed; `-C opt-level=1` and above crash.

### Meta

`rustc --version --verbose`:

```text
rustc 1.95.0 (59807616e 2026-04-14)
binary: rustc
commit-hash: 59807616e1fa2540724bfbac14d7976d7e4a3860
commit-date: 2026-04-14
host: x86_64-unknown-linux-gnu
release: 1.95.0
LLVM version: 22.1.2
```

Also fails on `rustc 1.101.0-nightly` (LLVM 23.1.4), with a different
message (below).

### Error output

1.95.0:

```text
error: rustc interrupted by SIGSEGV, printing backtrace

librustc_driver-6108105cd7e839cf.so(+0x3b62e1c)
/usr/lib/libc.so.6(+0x3e6f0)
libLLVM.so.22.1-rust-1.95.0-stable(+0x9289e28)
libLLVM.so.22.1-rust-1.95.0-stable(_ZN4llvm16SelectionDAGISel17CodeGenAndEmitDAGEv+0xe0a)
libLLVM.so.22.1-rust-1.95.0-stable(_ZN4llvm16SelectionDAGISel20SelectAllBasicBlocksERKNS_8FunctionE+0x1746)
libLLVM.so.22.1-rust-1.95.0-stable(_ZN4llvm16SelectionDAGISel20runOnMachineFunctionERNS_15MachineFunctionE+0x19f)
libLLVM.so.22.1-rust-1.95.0-stable(_ZN4llvm22SelectionDAGISelLegacy20runOnMachineFunctionERNS_15MachineFunctionE+0x19b)
libLLVM.so.22.1-rust-1.95.0-stable(_ZN4llvm13FPPassManager13runOnFunctionERNS_8FunctionE+0x8db)
libLLVM.so.22.1-rust-1.95.0-stable(_ZN4llvm13FPPassManager11runOnModuleERNS_6ModuleE+0x28)
libLLVM.so.22.1-rust-1.95.0-stable(_ZN4llvm6legacy15PassManagerImpl3runERNS_6ModuleE+0x2b0)
...
note: we would appreciate a report at https://github.com/rust-lang/rust
help: you can increase rustc's stack size by setting RUST_MIN_STACK=16777216
```

The faulting frame (`+0x9289e28`) is
`(anonymous namespace)::ScheduleDAGRRList::Schedule()`, reading through a
null `SDNode` pointer. It is not a stack overflow, despite the hint.

1.101.0-nightly:

```text
rustc-LLVM ERROR: SmallVector unable to grow. Requested capacity (4294967296) is larger than maximum value for size type (4294967295)
```

### Cause

An LLVM bug in the bottom-up pre-RA list scheduler
(`ScheduleDAGRRList`), reported upstream:
<!-- link to the llvm/llvm-project issue -->

Under Win64 the `bool` is the fifth argument, so it is stored to the stack
by a `SETCCm` inside the call sequence. Its flags come from a compare that
folds the load of `*p` and is therefore chained before the call's
`ADJCALLSTACKDOWN64`, which clobbers EFLAGS; only the scheduler's
last-resort path can resolve that. At the same time the `sinf` libcall that
`f32::sin` is expanded to is chained only to the entry token and waits on
the scheduler's call-sequence resource. With both pending, the last-resort
path picks the first one, the call-sequence wait, and asks for the register
class of `CallResource` (`TRI->getNumRegs()`) as if it were a register. An
assertions build of LLVM main stops there
(`getMinimalPhysRegClass: Assertion 'Reg < ArrayRef(Mapping).size()'
failed`); release builds carry on and crash (LLVM 22) or abort (LLVM 23).

A proposed fix (skip call-resource interferences in that path and resolve
the EFLAGS one, which unfolds the compare's load) is on the LLVM issue,
with a regression test; LLVM's X86 code generation tests pass with it.

### Workaround

Avoid the call shape: keep the `bool` within the first four arguments, or
pass the scalars by reference in a struct. That is what the game this came
from now does (the crashing call passed five floats and a `bool` on the
stack). A larger `RUST_MIN_STACK` does not help.
