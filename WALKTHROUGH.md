# Walkthrough: how each line sets up the crash

Each line of the Rust reproducer (`src/lib.rs`) next to the LLVM IR rustc
1.95.0 emits for it at `opt-level=3` for `x86_64-pc-windows-msvc`
(`llvm/repro-from-rust.ll`, from `./llvm/emit-ir.sh`), what instruction
selection turns it into, and its part in the crash. The `SU(n)` numbers are
the scheduling units in the `-debug-only=pre-RA-sched` trace from an
assertions build of `llc`.

## Reading the trace

`SU(n)` is a scheduling unit (`SUnit`, in
`llvm/include/llvm/CodeGen/ScheduleDAG.h`): what the instruction scheduler
actually orders. Usually it holds one machine node. Nodes glued together
(which must stay adjacent) share one unit and are placed as a block: SU(8)
is `CopyToReg $xmm0` (passing `y`), `CALL sinf`, `ADJCALLSTACKUP64 32` and
`CopyFromReg $xmm0` together.

`n` is the unit's index in the scheduler's list, in creation order. It
identifies the unit within one trace and means nothing else; any change to
the function or to LLVM renumbers them. The numbers here come from
`llvm/repro.ll` on an assertions build of LLVM main.

In a trace line such as `SU(15): t61: i32,ch = CMP64mi32<...> t2, ...`,
`t61` is the SelectionDAG node inside the unit and `t2` one of its
operands; `t61:1` means result 1 of `t61` (here its chain).

| Edge in the trace | Meaning |
|---|---|
| `Data` | uses the other unit's value |
| `Ord ... Barrier` | ordering only (the chain): memory or call-sequence order |
| `Reg=$eflags` | depends on a physical register the other unit sets; nothing that clobbers it may sit between them |
| `Artificial` | added by the scheduler itself, for example after backtracking |

The scheduler works bottom-up: a unit becomes available once everything
that uses it is placed. "Interfering reg" lines, and the `Interferences`
list, are units that are available but blocked.

## The units

The scheduler builds 19 units for this block. In program order, with the
glued nodes inside each:

| Unit | Contents (top to bottom) | Role |
|---|---|---|
| SU(0) | `RET` | return |
| SU(1) | `CopyToReg $rcx ← t11`, `$rdx ← t13`, `$r8 ← t15`, `$xmm3 ← t24`, `CALL callee`, `ADJCALLSTACKUP64 40` | the outer call: register arguments, call and frame teardown, all glued |
| SU(2) | `ADDSSrr t71, t60` | `sum = sin + sel` |
| SU(3) | `CopyToReg $eflags ← t59`, `CMOV_FR32` | the `select`, reading the `TEST` flags |
| SU(4) | `TEST8ri c, 1` | flags for the `select` |
| SU(5) | `CopyFromReg %1` | `c` |
| SU(6) | `MOVSSrm` (constant pool, 0.8) | the constant |
| SU(7) | `CopyFromReg %2` | `x` |
| SU(8) | `CopyToReg $xmm0 ← y`, `CALL sinf`, `ADJCALLSTACKUP64 32`, `CopyFromReg $xmm0` | the `sinf` call, glued |
| SU(9) | `CopyFromReg %3` | `y` |
| SU(10) | `ADJCALLSTACKDOWN64 32` (chained to the entry node, `t0`) | `sinf`'s frame setup, free-floating |
| SU(11), SU(12), SU(13) | `MOV64rm` from `fixed-stack.0/1/2` | incoming `d`, `b`, `a` (passed on in `r8`, `rdx`, `rcx`) |
| SU(14) | `CopyToReg $eflags ← t61` (chained after `t29:1`), `SETCCm [rsp+32]` | the `bool` stored into its argument slot |
| SU(15) | `CMP64mi32 [p], 0` | the compare with the load folded in; sets `EFLAGS` |
| SU(16) | `CopyFromReg %0` | `p` |
| SU(17) | `ADJCALLSTACKDOWN64 40` (chained after `t61:1`, the compare) | the outer call's frame setup |
| SU(18) | `CopyFromReg $rsp` (chained after `t29:1`) | the stack pointer the argument store addresses |

SU(14) shows the trap in one unit: the `CopyToReg $eflags` feeding the
`SETCCm` is chained after `t29:1`, the outer `ADJCALLSTACKDOWN64`, but its
value, `t61`, comes from the compare that `ADJCALLSTACKDOWN64` is itself
chained after.

### The order they are scheduled in

Bottom-up: the scheduler places the last instruction first.

```text
[0]   SU(0)  RET
[1]   SU(1)  outer call + ADJCALLSTACKUP64 40  -> outer call sequence open (CallResource held)
[2]   SU(14) SETCCm                            -> $eflags live, waiting for SU(15)
[3]   SU(18) CopyFromReg $rsp
[4]   SU(2)  ADDSS                             -> SU(8) ready, but blocked on CallResource
[5-7] SU(11), SU(12), SU(13) loads
      stuck: backtrack, unscheduling [7] to [2]; ARTIFICIAL edge SU(14) -> SU(3)
[2]   SU(2)  ADDSS
[3]   SU(3)  CMOV_FR32
[4]   SU(6)  constant load
[5]   SU(4)  TEST8ri
[6]   SU(14) SETCCm
[7]   SU(18) CopyFromReg $rsp
[8]   SU(5)   [9] SU(7)   [10] SU(13)   [11] SU(12)   [12] SU(11)
      stuck again: last resort, and the bad register-class lookup
```

### The six units never placed

| Unit | Why it cannot be placed |
|---|---|
| SU(8), the `sinf` call | blocked on `CallResource`: it would end a second call inside the open one |
| SU(17), `ADJCALLSTACKDOWN64 40` | blocked on `$eflags`: it clobbers the flags SU(14) still needs from SU(15) |
| SU(15), the compare | not ready: its user SU(17) is not placed (bottom-up, a unit waits for all its users) |
| SU(16), `p` | not ready: waits for SU(15) |
| SU(10), `sinf`'s frame setup | not ready: waits for SU(8) |
| SU(9), `y` | not ready: waits for SU(8) |

At that point the scheduler's list of blocked units (`Interferences`) is
exactly `[SU(8): CallResource, SU(17): $eflags]`, confirmed with
temporary debug output added to the last-resort path.

## In short

- **Wait 1 (`$eflags`).** Line 3 makes a compare's flags have to survive
  an instruction that destroys them. Line 1 makes the store that needs
  them land inside the call sequence.
- **Wait 2 (`CallResource`).** Line 5 makes a call that floats free and
  ends up waiting on the open call sequence.
- **The order.** Line 4 puts wait 2 first in the queue.
- **The collision.** Line 6 brings both waits together, and the scheduler's
  last-resort path treats the pseudo-register `CallResource` as a real
  register.

## 1. The declaration: where each argument goes

```rust
unsafe extern "C" { fn callee(a: *const u8, b: *const u8, c: *const u8, x: f32, flag: bool); }
```

```llvm
declare void @callee(ptr noundef, ptr noundef, ptr noundef, float noundef, i1 noundef zeroext)
```

On a Windows target `extern "C"` means Win64 (`CC_X86_Win64_C` in
`X86CallingConv.td`), which has four positional argument slots. The names
are the callee's parameters; the call passes `a`, `b`, `d`, `sum`, `flag`:

| Argument | Location |
|---|---|
| `a` | `RCX` |
| `b` | `RDX` |
| `c` | `R8` |
| `x` | `XMM3` (the fourth slot, so the float register) |
| `flag` | the stack, at `[rsp+32]`, above the 32-byte shadow space |

So every call opens a 40-byte call frame: `ADJCALLSTACKDOWN64 40`, the
argument setup, `CALL`, then `ADJCALLSTACKUP64 40`.

Win64 widens an `i1` only to `i8`, so `flag` is stored as a single byte.
That is what later lets the `setne` write straight into the stack slot.
Under System V, `flag` would go in a register (and even on the stack would
be widened to 32 bits), and nothing below happens.

## 2. The signature: mostly incidental

```rust
pub fn repro(p: &u64, c: bool, x: f32, y: f32, a: *const u8, b: *const u8, d: *const u8)
```

```llvm
define void @repro(ptr noalias noundef readonly align 8 dereferenceable(8) %p, i1 zeroext %c,
                   float %0, float %y, ptr %a, ptr %b, ptr %d)
```

`p` arrives in `RCX`, `c` in `DL`, `x` in `XMM2` and `y` in `XMM3`. `a`, `b`
and `d` are this function's own fifth to seventh arguments, so they come in
on the stack: the `MOV64rm ... fixed-stack` loads, which become
`movq 128(%rsp), %rcx` and so on in the output.

What matters here is only that `p` is a reference, so reading it is a load,
and that there are enough outgoing arguments for `flag` to land fifth.

## 3. `let flag = *p != 0;`: the compare whose flags must cross a clobber

```llvm
%_9  = load i64, ptr %p, align 8
%flag = icmp ne i64 %_9, 0
```

This line creates the first impossible requirement. Four things combine:

1. **The load is folded into the compare.** At `-O1` and above, x86 merges
   them into one instruction, `CMP64mi32 [p], 0` (SU(15)), which sets
   `EFLAGS`. At `-O0` it never folds loads (`IsProfitableToFold` returns
   false), which is one reason debug builds are safe.
2. **The compare is ordered before the call.** It now carries the load's
   memory ordering (its "chain"). A call takes its chain from
   `SelectionDAGBuilder::getRoot()` (in `LowerCallTo`), which chains in the
   loads still pending before it. So the outer `ADJCALLSTACKDOWN64 40`
   (SU(17)) is chained after the compare: `t29 = ADJCALLSTACKDOWN64 ...,
   t61:1`.
3. **The result is stored inside the call.** `%flag` is the byte argument,
   so "store byte to `[rsp+32]`" and "set byte from flags" fuse into
   `SETCCm` (SU(14)). That store addresses the stack pointer after the
   frame is set up (`CopyFromReg $rsp`, SU(18), chained after SU(17)), so
   it must come after `ADJCALLSTACKDOWN64`.
4. **The frame setup clobbers the flags.** `ADJCALLSTACKDOWN64` is
   defined with `Defs = [RSP, EFLAGS, SSP]` (`X86InstrCompiler.td`, under
   "Pessimistically assume ADJCALLSTACKDOWN / ADJCALLSTACKUP will become
   sub / add which can clobber EFLAGS"). Here it does not actually emit a
   `sub`, but the scheduler has to assume it does.

So `EFLAGS` must be produced before SU(17), consumed after it, and survive
SU(17), which destroys it. The scheduler can only untangle that in its
last-resort path, by duplicating the compare (splitting the load back out)
or copying the flags.

This is wait #1: SU(17) is blocked on `$eflags`.

## 4. `let sel = if c { 0.8 } else { x };`: a second flags user that shapes the order

```llvm
%spec.store.select = select i1 %c, float 0x3FE99999A0000000, float %0
```

- **In IR:** optimisation turns the `if` into a `select` (hence the name
  `spec.store.select`).
- **On x86:** there is no conditional move between float registers, so it
  becomes a `CMOV_FR32` pseudo-instruction (SU(3), `Uses = [EFLAGS]`). It
  reads `EFLAGS` from `TEST8ri c, 1` (SU(4)). It only turns into a branch
  in the `FinalizeISel` pass, after scheduling, through its custom
  inserter.

This line creates no impossible requirement of its own. It adds a second
producer/consumer pair of flags to the same block, and that decides which
of the two waits ends up first in the scheduler's list:

- At the first dead end the blocked units are SU(17) (`$eflags`), SU(8)
  (`CallResource`, and `$eflags` too, since the `sinf` call clobbers the
  flags) and SU(3) (`$eflags`, the `CMOV`). Backtracking for SU(17) and
  SU(8) would create cycles; for SU(3) it would not, so the scheduler
  backtracks there: it unschedules back to SETCCm and adds an artificial
  edge from SU(14) to SU(3).
- When it gets stuck again, the list is `[SU(8), SU(17)]`: the `sinf` wait
  first.
- Without the `select`, both waits still arise and the last-resort path
  still runs, but the list is `[$eflags wait, CallResource wait]`. The
  fallback takes the flags wait, splits the compare's load back out, and it
  compiles. So the `select` does not cause a wait; it puts the wrong one
  first.

In the game, this is `.clamp(0.0, CAPE_TRAIL_MAX)`: `CAPE_TRAIL_MAX` is the
`0.8` (`0x3FE99999A0000000`).

## 5. `let sum = y.sin() + sel;`: a call that floats free

```llvm
%1   = tail call float @llvm.sin.f32(float %y)
%sum = fadd float %spec.store.select, %1
```

This line creates the second impossible requirement.

- **The intrinsic becomes a call.** `y.sin()` inlines to the
  `llvm.sin.f32` intrinsic. x86 marks f32 `FSIN` as `Expand` ("We don't
  support sin/cos/fmod" in `X86ISelLowering.cpp`), so `LegalizeDAG` turns
  it into a call to `sinf` with its own call sequence:
  `ADJCALLSTACKDOWN64 32` (SU(10), just shadow space), then
  `CopyToReg $xmm0`, `CALL sinf`, `ADJCALLSTACKUP64 32` and
  `CopyFromReg $xmm0`, glued into SU(8).
- **Nothing orders it against the outer call.** `ExpandLibCall` starts the
  libcall's chain at the function's entry ("By default, the input chain to
  this libcall is the entry node of the function"). Its only link to the
  outer call is data: `sinf`'s result feeds the `ADDSS` (SU(2)), which
  feeds `XMM3`.
- **It ends up waiting.** The scheduler works bottom-up. Once it has
  placed the outer `ADJCALLSTACKUP64 40`, it treats the outer call
  sequence as open and holds a pseudo-register, `CallResource`, until it
  reaches the matching `ADJCALLSTACKDOWN64 40`. When `ADDSS` is placed,
  SU(8) becomes ready, but it ends another call. The scheduler only lets a
  call end inside an open sequence if it is chained inside that sequence
  (`IsChainDependent` in `DelayForLiveRegsBottomUp`); SU(8) is chained only
  to the entry node, so it has to wait.

This is wait #2: SU(8) is blocked on `CallResource`.

Compare `call float @sinf(...)` written explicitly in IR: that is lowered
in order, chained after the load and before the outer call, so it never
becomes ready early and there is no `CallResource` wait at all. Only the
flags conflict remains, the fallback splits the load out, and that variant
compiles. So does a debug build, where
`y.sin()` stays an ordinary call to std's `f32::sin` wrapper.

The `fadd` ties the two halves together: the argument in `XMM3` depends on
both the `sinf` result and the select.

## 6. `unsafe { callee(a, b, d, sum, flag) };`: where the two waits meet

```llvm
tail call void @callee(ptr %a, ptr %b, ptr %d, float %sum, i1 zeroext %flag)
```

This lowers to:

1. `ADJCALLSTACKDOWN64 40` (SU(17));
2. `CopyFromReg $rsp` (SU(18));
3. `SETCCm` storing `flag` to `[rsp+32]` (SU(14));
4. copies to `RCX`, `RDX`, `R8` and `XMM3`, glued to the call;
5. `CALL callee`;
6. `ADJCALLSTACKUP64 40` (SU(1)), then `RET` (SU(0)).

That puts both waits inside one open call sequence:

- the `sinf` sequence's end (SU(8)) waits on `CallResource`;
- the outer `ADJCALLSTACKDOWN64` (SU(17)) waits on `$eflags`.

## What the scheduler then does

Working bottom-up:

1. It places `RET`, `ADJCALLSTACKUP64 40`, `SETCCm`, `CopyFromReg $rsp`,
   `ADDSS`, `CMOV_FR32`, `TEST8ri`, the constant load and the
   incoming-argument loads (with one round of backtracking in between).
2. Every remaining ready unit is now blocked. `Interferences` holds
   `[SU(8): CallResource, SU(17): $eflags]`, in that order because of
   line 4.
3. **Backtracking is ruled out.** For each blocked unit the scheduler would
   undo back to the unit that last needs the contested register, and both
   options create a cycle: for SU(17) that unit is SU(14), which SU(17)
   must precede; for SU(8) it is SU(1), the outer call, which needs SU(8)'s
   result.
4. **The last-resort path only looks at `Interferences[0]`.** That is
   SU(8), whose conflict is `CallResource`. Since `CallResource` is defined
   as `TRI->getNumRegs()`, one past the last real register, the code treats
   it as a register and calls `getMinimalPhysRegClass(CallResource)`. The
   lookup is out of range (`getNumRegs()` is 388 for X86):
   - with assertions on, `llc` stops there, in `getMinimalPhysRegClass`;
   - without assertions it carries on with a bogus register class. LLVM
     main and 23.1 then fail with `SmallVector unable to grow`; LLVM 22.1
     reads through a null pointer, and gdb shows the faulting load indexing
     entry 388 of a per-register table, the `CallResource` slot.

If the fallback takes SU(17)'s `$eflags` conflict instead, it duplicates
the compare by splitting its load back out (the trace shows
`Unfolding SU(15)`). That is `llvm/fix-scheduledagrrlist.patch`. With it,
both an assertions build and a release build of main compile the
reproducer, and the release build compiles the game's original function:

```asm
movq  (%rcx), %rsi    ; the load, now separate, before sinf
callq sinf
testq %rsi, %rsi      ; the compare, after the call frame is set up
setne 32(%rsp)        ; flag stored straight into its stack slot
```

`-pre-RA-sched=fast` resolves the same conflict the same way, by splitting
the load out, but places the load after the `sinf` call instead:

```asm
callq sinf
movq  (%rsi), %rax
...
testq %rax, %rax
setne 32(%rsp)
```

## Reproducing the trace

```sh
./llvm/emit-ir.sh                         # rustc's IR -> llvm/repro-from-rust.ll
llc -O3 -mtriple=x86_64-pc-windows-msvc -filetype=obj -o /dev/null \
    -debug-only=pre-RA-sched llvm/repro.ll
```

The second command needs an `llc` built with `-DLLVM_ENABLE_ASSERTIONS=ON`;
release builds have no debug output.
