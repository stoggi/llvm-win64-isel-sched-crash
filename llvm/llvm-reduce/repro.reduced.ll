; ModuleID = 'repro.reduced.bc'
target datalayout = "e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-pc-windows-msvc"

define void @repro(i1 %c) {
start:
  %spec.store.select = select i1 %c, float 1.000000e+00, float 0.000000e+00
  %0 = tail call float @llvm.sin.f32(float 0.000000e+00)
  %sum = fadd float %spec.store.select, %0
  %_9 = load i64, ptr null, align 8
  %flag = icmp ne i64 %_9, 0
  tail call void null(ptr null, ptr null, ptr null, float %sum, i1 %flag)
  ret void
}

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare float @llvm.sin.f32(float) #0

attributes #0 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
