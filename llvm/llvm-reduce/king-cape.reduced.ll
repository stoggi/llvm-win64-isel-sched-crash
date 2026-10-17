; ModuleID = 'king-cape.reduced.bc'
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

; Function Attrs: nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare float @llvm.sin.f32(float) #0

attributes #0 = { nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
