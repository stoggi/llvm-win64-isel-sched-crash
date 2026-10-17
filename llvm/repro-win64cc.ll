; llc -O3 -mtriple=x86_64-unknown-linux-gnu -filetype=obj -o /dev/null repro-win64cc.ll
;
; The same function for a Linux triple, with only the outer call using the
; Win64 calling convention: it crashes the same way, which shows the
; trigger is the Win64 argument lowering, not anything else about Windows.

declare win64cc void @callee(ptr, ptr, ptr, float, i1)
declare float @llvm.sin.f32(float)

define void @repro(ptr %p, i1 %c, float %x, float %y, ptr %a, ptr %b, ptr %d) {
  %v = load i64, ptr %p, align 8
  %flag = icmp ne i64 %v, 0
  %sel = select i1 %c, float 0x3FE99999A0000000, float %x
  %s = tail call float @llvm.sin.f32(float %y)
  %sum = fadd float %s, %sel
  call win64cc void @callee(ptr %a, ptr %b, ptr %d, float %sum, i1 %flag)
  ret void
}
