//! Building this crate with optimisation crashes rustc inside LLVM's X86
//! instruction scheduler when the call below uses the Win64 calling
//! convention. See README.md.
//!
//! Every line matters: the `sin()` (lowered to a `sinf` libcall during
//! instruction selection), the `if` select added to it, the bool computed
//! by comparing a loaded value, and the bool being the fifth argument,
//! which Win64 passes on the stack.

unsafe extern "C" {
    fn callee(a: *const u8, b: *const u8, c: *const u8, x: f32, flag: bool);
}

pub fn repro(p: &u64, c: bool, x: f32, y: f32, a: *const u8, b: *const u8, d: *const u8) {
    let flag = *p != 0;
    let sel = if c { 0.8 } else { x };
    let sum = y.sin() + sel;
    unsafe { callee(a, b, d, sum, flag) };
}
