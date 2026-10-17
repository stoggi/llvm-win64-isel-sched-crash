; ModuleID = 'lib.c6f551dc431569fb-cgu.0'
source_filename = "lib.c6f551dc431569fb-cgu.0"
target datalayout = "e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-pc-windows-msvc"

; Function Attrs: nounwind uwtable
define void @repro(ptr noalias noundef readonly align 8 captures(none) dereferenceable(8) %p, i1 noundef zeroext %c, float noundef %0, float noundef %y, ptr noundef %a, ptr noundef %b, ptr noundef %d) unnamed_addr #0 {
start:
  %_9 = load i64, ptr %p, align 8, !noundef !2
  %flag = icmp ne i64 %_9, 0
  %spec.store.select = select i1 %c, float 0x3FE99999A0000000, float %0
  %1 = tail call float @llvm.sin.f32(float %y)
  %sum = fadd float %spec.store.select, %1
  tail call void @callee(ptr noundef %a, ptr noundef %b, ptr noundef %d, float noundef %sum, i1 noundef zeroext %flag) #2
  ret void
}

; Function Attrs: mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none)
declare float @llvm.sin.f32(float) #1

; Function Attrs: nounwind uwtable
declare void @callee(ptr noundef, ptr noundef, ptr noundef, float noundef, i1 noundef zeroext) unnamed_addr #0

attributes #0 = { nounwind uwtable "target-cpu"="x86-64" "target-features"="+cx16,+sse,+sse2,+sse3,+sahf" }
attributes #1 = { mustprogress nocallback nocreateundeforpoison nofree nosync nounwind speculatable willreturn memory(none) }
attributes #2 = { nounwind }

!llvm.module.flags = !{!0}
!llvm.ident = !{!1}

!0 = !{i32 8, !"PIC Level", i32 2}
!1 = !{!"rustc version 1.95.0 (59807616e 2026-04-14)"}
!2 = !{}
