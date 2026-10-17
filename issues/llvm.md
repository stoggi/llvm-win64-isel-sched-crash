<!-- File at https://github.com/llvm/llvm-project/issues/new
     Suggested labels: backend:X86, llvm:SelectionDAG, crash
     Attach llvm/fix-scheduledagrrlist.patch (or open it as a PR and link
     it), and fill in the link at the bottom. -->

**Title:** [SelectionDAG] ScheduleDAGRRList's last-resort path treats CallResource as a physical register (Win64 call with a SETCCm stack argument and an FSIN libcall)

---

`llc -O3` fails in X86 instruction selection on the function below when the
call uses the Win64 calling convention. On an assertions build of main
(llvmorg-24-init-14827-g793ff02cdb35):

```text
X86GenRegisterInfoTargetDesc.inc:4774: virtual const llvm::TargetRegisterClass*
llvm::X86GenRegisterInfo::getMinimalPhysRegClass(llvm::MCRegister) const:
Assertion `Reg < ArrayRef(Mapping).size()' failed.
...
2.	Running pass 'X86 DAG->DAG Instruction Selection' on function '@repro'
```

The bottom-up list scheduler ends up in the last-resort path of
`PickNodeToScheduleBottomUp` with the first pending interference being on
the special call-sequence resource (`TRI->getNumRegs()`), and passes it to
`getMinimalPhysRegClass` as if it were a register. Details, a proposed fix
and a test are below.

### Reproducer

```llvm
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

```sh
llc -O3 -mtriple=x86_64-pc-windows-msvc -filetype=obj -o /dev/null repro.ll
```

Release builds without assertions do not stop at the bad lookup:

- LLVM 22.1.2 (as shipped with rustc 1.95.0): SIGSEGV, a null `SDNode`
  read in `ScheduleDAGRRList::Schedule()` (`mov 0x18(%rax),%r11d`,
  `rax == 0`).
- LLVM 23.1.4 (rustc 1.101.0-nightly): `LLVM ERROR: SmallVector unable to
  grow. Requested capacity (4294967296) ...`, from
  `SmallVectorTemplateBase<long, true>::growAndPushBack` called by
  `ScheduleDAGRRList::Schedule()`.

### Cause

`-debug-only=pre-RA-sched` on the assertions build, trimmed:

```text
SU(15): t61: i32,ch = CMP64mi32<Mem:(load (s64) from %ir.p)> t2, ...
  Successors:
    SU(14): Data Latency=1 Reg=$eflags      ; SETCCm into the stack arg slot
    SU(17): Ord  Latency=1 Barrier          ; ADJCALLSTACKDOWN64 40 (outer call)
SU(17): t29: i64,ch,glue = ADJCALLSTACKDOWN64 TargetConstant:i64<40>, ..., t61:1
  Successors:
    SU(14): Ord  Latency=1 Barrier
    SU(18): Ord  Latency=1 Barrier          ; CopyFromReg $rsp
SU(8): t71: f32,ch,glue = CopyFromReg t70:1, Register:f32 $xmm0, t70:2
    t69: ch,glue = CALL64pcrel32 TargetExternalSymbol:i64'sinf', ...
    t70: i64,ch,glue = ADJCALLSTACKUP64 TargetConstant:i64<32>, ...
...
    Interfering reg CallResource SU(8)
    Interfering reg $eflags SU(17)
```

1. The compare producing the `i1` argument folds the load of `%p`, so it is
   chained before the outer call's `ADJCALLSTACKDOWN64` (SU(17)). Its
   EFLAGS are read by the `SETCCm` that stores the argument at `rsp+32`
   (SU(14)), which comes after SU(17). `ADJCALLSTACKDOWN64` defines
   EFLAGS, so as built, EFLAGS would have to be live across a node that
   clobbers them. Only the last-resort path (duplicate or unfold the def,
   or copy the register) can untangle that.
2. The `sinf` libcall that the `FSIN` is expanded to is chained only to the
   entry token, so its call-sequence end (SU(8)) becomes available while
   the outer call sequence is open, and is held back on `CallResource`.
3. With both pending, backtracking would create a cycle, so the last-resort
   path runs. It takes `Interferences[0]`, which is SU(8), and calls
   `TRI->getMinimalPhysRegClass(CallResource)`.

### What it depends on

Each row changes one thing in the IR above and records whether
`llc -O3 -mtriple=x86_64-pc-windows-msvc` still fails (LLVM 22.1.2). They
match the cause: remove either of the two interferences, or change which
one is first, and it compiles.

| Change | Fails? |
|---|---|
| none | yes |
| `llvm.sin.f32` replaced by a call to an opaque function | no |
| `llvm.sin.f32` replaced by an explicit `call float @sinf` (ordered before the outer call, so never pending) | no |
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
| `-mtriple=x86_64-unknown-linux-gnu` with the call marked `win64cc` | yes |
| `-O0` | no |
| `-O1`, `-O2` | yes |
| `-pre-RA-sched=source`, `list-burr`, `list-ilp` | yes |
| `-pre-RA-sched=fast` | no |

The `select` matters through the `TEST8ri`/`CMOV_FR32` EFLAGS traffic it
adds, which steers the earlier backtracking so that SU(8) is first in
`Interferences`. I did not pin down why System V with the `i1` on the stack
does not end up in the same state.

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
load, the same shape `-pre-RA-sched=fast` produces:

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

Testing:

- `check-llvm-codegen-x86` passes (5745 passed, 15 expectedly failed, 2
  unsupported).
- A new test, `llvm/test/CodeGen/X86/pre-ra-sched-callseq-interference.ll`
  (the IR above with checks from `update_llc_test_checks.py`), fails
  without the change and passes with it. Patch with the test attached.
- The original function this was reduced from (a few thousand lines of
  rustc output) compiles with the change.

This is the smallest change that fixes it. Alternatives that may be
preferable: keep the folded-load compare from being chained across
`CALLSEQ_START` while its flags are consumed inside the sequence, or have
the last-resort path try every interference rather than the first
real-register one.

### Where it came from

Found through rustc building a game for `x86_64-pc-windows-msvc`: the
release build crashed on a call that passed five floats and a `bool` on the
stack. Rust reproducer and full notes:
<!-- link to the rust-lang/rust issue or a repository with this folder -->
