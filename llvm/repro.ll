; llc repro.ll -o /dev/null      (also with -relocation-model=pic or =static, or -O1/-O3)
;
; Crashes LLVM 22.1.2 (rustc 1.95.0) with SIGSEGV in
; ScheduleDAGRRList::Schedule, and LLVM 23.1.4 (rustc 1.101 nightly) with
; "SmallVector unable to grow". Compiles fine for x86_64-unknown-linux-gnu.

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
