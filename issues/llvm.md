<!-- File at https://github.com/llvm/llvm-project/issues/new
     Suggested labels: backend:X86, llvm:SelectionDAG, crash (the
     guidelines say labels are optional).
     Attach:
       llvm/llvm-reduce/king-cape.reduced.bc   (llvm-reduce output, the test case)
       llvm/llvm-reduce/king-cape.bc           (unreduced rustc bitcode)
       llvm/llvm-reduce/reduce-test.sh         (llvm-reduce interestingness test)
       llvm/repro.ll                           (equivalent hand-cleaned test case)
       llvm/fix-scheduledagrrlist.patch        (proposed fix + regression test)
     or open the patch as a PR and link it. Fill in the link at the bottom. -->

**Title:** [SelectionDAG] ScheduleDAGRRList's last-resort path treats CallResource as a physical register (Win64 call with a SETCCm stack argument and an FSIN libcall)

---

### Summary

`llc` crashes in X86 instruction selection, in the bottom-up list scheduler
(`ScheduleDAGRRList`), on a block where a Win64 call passes an `i1` on the
stack and an `llvm.sin.f32` result in a register. The scheduler reaches the
last-resort path of `PickNodeToScheduleBottomUp` with the first pending
interference being on the special call-sequence resource
(`TRI->getNumRegs()`), and passes it to `getMinimalPhysRegClass` as if it
were a register. With assertions:

```text
llc: .../lib/Target/X86/X86GenRegisterInfoTargetDesc.inc:4774: virtual const llvm::TargetRegisterClass*
llvm::X86GenRegisterInfo::getMinimalPhysRegClass(llvm::MCRegister) const:
Assertion `Reg < ArrayRef(Mapping).size()' failed.
PLEASE submit a bug report to https://github.com/llvm/llvm-project/issues/ and include the crash backtrace and instructions to reproduce the bug.
Stack dump:
0.	Program arguments: llc king-cape.reduced.ll -o /dev/null
1.	Running pass 'Function Pass Manager' on module 'king-cape.reduced.ll'.
2.	Running pass 'X86 DAG->DAG Instruction Selection' on function '@pose_cape'
```

Without assertions it does not stop there and fails later: `LLVM ERROR:
SmallVector unable to grow` (main, 23.1.4) or a SIGSEGV (22.1.2). Details,
a proposed fix and a test are below.

### Reproducing

Reduced test case, as emitted by `llvm-reduce` (attached as
`king-cape.reduced.bc`):

```llvm
target datalayout = "e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-pc-windows-msvc"

define void @pose_cape(i1 %0) {
start:
  %self.sroa.0.1.i5 = select i1 %0, float 1.000000e+00, float 0.000000e+00
  %1 = tail call float @llvm.sin.f32(float 0.000000e+00)
  %sideways = fadd float %self.sroa.0.1.i5, %1
  %2 = load i64, ptr null, align 8
  %3 = icmp ne i64 %2, 0
  call fastcc void null(float 0.000000e+00, float %sideways, float 0.000000e+00, float 0.000000e+00, i1 %3)
  ret void
}

declare float @llvm.sin.f32(float) #0

attributes #0 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
```

```sh
llc king-cape.reduced.ll -o /dev/null
```

All three commands from the bug-reporting guide fail on it, as on the
unreduced bitcode (`king-cape.bc`):

| Command | main 793ff02cdb35, assertions | main 793ff02cdb35, no assertions | 22.1.2 (rustc 1.95.0) |
|---|---|---|---|
| `llc foo.bc` | assertion above | `SmallVector unable to grow` | SIGSEGV |
| `llc foo.bc -relocation-model=pic` | assertion above | `SmallVector unable to grow` | SIGSEGV |
| `llc foo.bc -relocation-model=static` | assertion above | `SmallVector unable to grow` | SIGSEGV |

`llc` does not fold `llvm.sin.f32` of a constant, so the reduced case
still contains the libcall. An equivalent hand-cleaned version with real
operands (attached as `repro.ll`), which the analysis below uses:

```llvm
target triple = "x86_64-pc-windows-msvc"

declare void @callee(ptr, ptr, ptr, float, i1)
declare float @llvm.sin.f32(float)

define void @repro(ptr %p, i1 %c, float %x, float %y, ptr %a, ptr %b, ptr %d) {
  %v = load i64, ptr %p, align 8
  %flag = icmp ne i64 %v, 0
  %sel = select i1 %c, float 0x3FE99999A0000000, float %x
  %s = tail call float @llvm.sin.f32(float %y)
  %sum = fadd float %s, %sel
  call void @callee(ptr %a, ptr %b, ptr %d, float %sum, i1 %flag)
  ret void
}
```

### Where LLVM came from

- **llvm/llvm-project main at 793ff02cdb35** (llvmorg-24-init-14827),
  built from git on x86_64 Linux with GCC 16.2.1:
  `-DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD=X86`, once with
  `-DLLVM_ENABLE_ASSERTIONS=ON` and once with it off.
- **LLVM 22.1.2** (`22.1.2-rust-1.95.0-stable`) and **LLVM 23.1.4**
  (`23.1.4-rust-1.101.0-nightly`): the `llc` that rustup's `llvm-tools`
  component ships with rustc 1.95.0 and rustc 1.101.0-nightly, built from
  rust-lang/llvm-project. Release builds without assertions.
  - 22.1.2: SIGSEGV. Under gdb, a null `SDNode` read in
    `ScheduleDAGRRList::Schedule()` (`mov 0x18(%rax),%r11d`, `rax == 0`);
    the faulting load indexes entry 388 of a per-register table, and
    `getNumRegs()` is 388 for X86, i.e. the `CallResource` slot.
  - 23.1.4: `LLVM ERROR: SmallVector unable to grow. Requested capacity
    (4294967296) ...`, from `SmallVectorTemplateBase<long,
    true>::growAndPushBack` called by `ScheduleDAGRRList::Schedule()`.

### How the crashing component was identified

The input comes from rustc rather than clang, so the guide's steps were
followed with the rustc equivalents:

1. `rustc --emit=llvm-bc -C opt-level=3 --target x86_64-pc-windows-msvc`
   (the equivalent of `-emit-llvm -c`) succeeds: not a front-end crash.
2. `opt -O3 king-cape.bc -disable-output` succeeds: not a middle-end crash.
3. `llc king-cape.bc` crashes (all three variants above): a code generator
   crash.
4. Reduced with `llvm-reduce -j 20 --test=reduce-test.sh king-cape.bc`. The
   test (attached) requires `llc` to fail with the `getMinimalPhysRegClass`
   assertion, so the reduction cannot drift onto a different crash.
   Reducing the separate small Rust reproducer the same way gives the same
   five instructions.

### Cause

`-debug-only=pre-RA-sched` for `repro.ll` on the assertions build, trimmed:

```text
SU(15): t61: i32,ch = CMP64mi32<Mem:(load (s64) from %ir.p)> t2, ...
  Successors:
    SU(14): Data Latency=1 Reg=$eflags      ; SETCCm into the stack arg slot
    SU(17): Ord  Latency=1 Barrier          ; ADJCALLSTACKDOWN64 40 (outer call)
SU(17): t29: i64,ch,glue = ADJCALLSTACKDOWN64 TargetConstant:i64<40>, ..., t61:1
  Successors:
    SU(14): Ord  Latency=1 Barrier
    SU(18): Ord  Latency=1 Barrier          ; CopyFromReg $rsp
SU(14): t81: ch,glue = CopyToReg t29:1, Register:i32 $eflags, t61
        t34: ch = SETCCm<Mem:(store (s8) into stack + 32)> t31, ..., t81, t81:1
SU(8):  t67: ch,glue = CopyToReg t65:1, Register:f32 $xmm0, t8
        t69: ch,glue = CALL64pcrel32 TargetExternalSymbol:i64'sinf', ...
        t70: i64,ch,glue = ADJCALLSTACKUP64 TargetConstant:i64<32>, ...
        t71: f32,ch,glue = CopyFromReg t70:1, Register:f32 $xmm0, t70:2
SU(10): t65: i64,ch,glue = ADJCALLSTACKDOWN64 TargetConstant:i64<32>, ..., t0
```

1. Win64 (`CC_X86_Win64_C`) promotes the `i1` only to `i8` and passes it
   fifth, in a stack slot, so the store of the setcc result folds into
   `SETCCm` (SU(14)) inside the outer call sequence. The compare producing
   it folds the load of `%p` (`CMP64mi32`, SU(15)) and so is chained before
   the outer `ADJCALLSTACKDOWN64` (SU(17); `LowerCallTo` takes its chain
   from `getRoot()`, which chains in pending loads). `ADJCALLSTACKDOWN64`
   has `Defs = [RSP, EFLAGS, SSP]`, so as built, EFLAGS would have to be
   live across a node that clobbers them. Only the last-resort path
   (duplicate or unfold the def, or copy the register) can resolve that.
2. `FSIN` is `Expand` for f32 on x86, and `ExpandLibCall` chains the
   resulting `sinf` call to the entry node. So its call-sequence end
   (SU(8)) becomes available while the outer call sequence is open, and
   since it is not chain-dependent on that sequence (`IsChainDependent` in
   `DelayForLiveRegsBottomUp`), it is held back on `CallResource`.
3. With both pending, backtracking would create a cycle for each (for
   SU(17) the backtrack target is SU(14), which SU(17) must precede; for
   SU(8) it is SU(1), the outer call, which needs SU(8)'s result). The
   last-resort path takes `Interferences[0]`, which is SU(8), and calls
   `TRI->getMinimalPhysRegClass(CallResource)`.

Confirmed with temporary debug output in the last-resort path: at that
point `Interferences` is `[SU(8): CallResource, SU(17): $eflags]`,
`LiveRegDefs[CallResource]` is SU(17) and `LiveRegDefs[$eflags]` is SU(15).

### What it depends on

Each row changes one thing in `repro.ll` and records whether `llc -O3
-mtriple=x86_64-pc-windows-msvc` still fails (LLVM 22.1.2). They match the
cause: remove either interference, or change which one is first, and it
compiles.

| Change | Fails? |
|---|---|
| none | yes |
| `llvm.sin.f32` replaced by a call to an opaque function | no |
| `llvm.sin.f32` replaced by an explicit `call float @sinf` (chained before the outer call, so never pending) | no |
| no `select` (`%sum = fadd float %s, %x`) | no |
| pass `%s` or `%sel` directly, without the `fadd` | no |
| `%flag` is a function parameter | no |
| `%flag` compares two parameters (no folded load) | no |
| the `select`'s condition is `%flag` | no |
| only four call arguments (`i1` in a register, no `SETCCm` in the sequence) | no |
| `i1` third argument (register), float on the stack | no |
| `i1 zeroext`, or an `sret` first argument | yes |
| `-mtriple=x86_64-pc-windows-gnu` | yes |
| `-mtriple=i686-pc-windows-msvc` | no |
| `-mtriple=x86_64-unknown-linux-gnu`, even with the `i1` pushed to the stack as a seventh integer argument | no |
| `-mtriple=x86_64-unknown-linux-gnu` with the call marked `win64cc` or `x86_vectorcallcc` | yes |
| `-mtriple=x86_64-unknown-linux-gnu` with any other x86 calling convention (`ccc`, `fastcc`, `coldcc`, `swiftcc`, `tailcc`, `preserve_*`, `ghccc`, `x86_regcallcc`, ...) | no |
| `-O0` | no |
| `-O1`, `-O2` | yes |
| `-pre-RA-sched=source`, `list-burr`, `list-ilp` | yes |
| `-pre-RA-sched=fast` | no |

- **The `select`** matters through the `TEST8ri`/`CMOV_FR32` EFLAGS traffic
  it adds, which steers the earlier backtracking (an artificial edge from
  SU(14) to the `CMOV`) so that SU(8) is first in `Interferences`. Without
  it both interferences still arise and the last-resort path still runs,
  but the EFLAGS one is first, so the existing code unfolds the compare
  and compiles the function.
- **System V** does not reach it because `CC_X86_64_C` promotes
  `i1`/`i8`/`i16` stack arguments to `i32`: the setcc goes to a register
  (`SETCCr`, no chain) and is stored with `MOV32mr`, so EFLAGS never has to
  cross `ADJCALLSTACKDOWN64`.
- **`-O0`** does not reach it because `X86DAGToDAGISel::IsProfitableToFold`
  returns false at `CodeGenOptLevel::None`, so the compare does not carry
  the load's chain.

### Proposed fix

In the last-resort path, skip interferences on the call resource and
resolve one on a real register. The call-sequence interference clears by
itself once the blocking call sequence is scheduled.

```diff
--- a/llvm/lib/CodeGen/SelectionDAG/ScheduleDAGRRList.cpp
+++ b/llvm/lib/CodeGen/SelectionDAG/ScheduleDAGRRList.cpp
@@ -1501,7 +1501,17 @@ SUnit *ScheduleDAGRRList::PickNodeToScheduleBottomUp() {
     // values to break the dependency. In case even that doesn't work,
     // insert cross class copies.
     // If it's not too expensive, i.e. cost != -1, issue copies.
-    SUnit *TrySU = Interferences[0];
+    //
+    // The call sequence resource is not a register and cannot be copied; a
+    // node waiting on it is unblocked by scheduling the call sequence that
+    // holds it. Resolve an interference on a real register instead.
+    unsigned CallResource = TRI->getNumRegs();
+    auto TryIt = find_if(Interferences, [&](SUnit *SU) {
+      return !is_contained(LRegsMap[SU], CallResource);
+    });
+    if (TryIt == Interferences.end())
+      report_fatal_error("Can't resolve call sequence interference!");
+    SUnit *TrySU = *TryIt;
     SmallVectorImpl<unsigned> &LRegs = LRegsMap[TrySU];
     assert(LRegs.size() == 1 && "Can't handle this yet!");
     unsigned Reg = LRegs[0];
```

With it, the EFLAGS interference is resolved by unfolding the compare's
load (`Unfolding SU(15)` in the trace). `-pre-RA-sched=fast` also splits
the load out, though it places it after the `sinf` call; with the patch:

```text
	movq	(%rcx), %rsi
	callq	sinf
	testq	%rsi, %rsi
	movq	144(%rsp), %r8
	movq	136(%rsp), %rdx
	movq	128(%rsp), %rcx
	setne	32(%rsp)
	testb	$1, %bl
	je	.LBB0_2
	...
	callq	callee
```

Testing (on 793ff02cdb35):

- `check-llvm-codegen-x86` passes (5745 passed, 15 expectedly failed, 2
  unsupported).
- A new test, `llvm/test/CodeGen/X86/pre-ra-sched-callseq-interference.ll`
  (`repro.ll` with checks from `update_llc_test_checks.py`), fails without
  the change and passes with it.
- With the change, both the assertions build and the build without
  assertions compile `king-cape.reduced.ll`, `king-cape.bc`, the
  `repro.ll` and `win64cc` variants, and the original function this was
  reduced from (a few thousand lines of rustc output). Without it, the
  build without assertions fails on each with `SmallVector unable to grow`.

This is the smallest change that fixes it. Alternatives that may be
preferable: keep the folded-load compare from being chained across
`CALLSEQ_START` while its flags are consumed inside the sequence, or have
the last-resort path try every interference rather than the first
real-register one.

### Where it came from

Found through rustc building a game for `x86_64-pc-windows-msvc`: the
release build crashed on a call that passed five floats and a `bool` on the
stack (the cape animation of a unit, hence `pose_cape`). Rust reproducer
and full notes:
<!-- link to the rust-lang/rust issue or a repository with this folder -->
