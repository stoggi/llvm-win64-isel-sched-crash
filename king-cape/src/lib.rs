//! The crash as the game hit it: the per-frame cape pose for a king, with
//! the game's types, constants and arithmetic (from Poplimit's
//! `render/minifig_bake.rs` before the fix). Only the cape physics inside
//! `swing_cape_chain` is simplified; it is behind a call either way.
//!
//! `cargo build --release --target x86_64-pc-windows-msvc` crashes rustc
//! 1.95. With `--features cape-wind` (the fix the game shipped) it builds.

pub const MAX_CAPE_PIECES: usize = 8;

const CAPE_TRAIL: f32 = 0.32;
const CAPE_TRAIL_PACE: f32 = 140.0;
const CAPE_TRAIL_MAX: f32 = 0.8;
const CAPE_TURN: f32 = 0.16;
const CAPE_TURN_MAX: f32 = 0.5;
const CAPE_STRIDE: f32 = 0.10;
const CAPE_SWAY: f32 = 0.12;
const CAPE_STIR: f32 = 0.03;
const CAPE_STIR_SPEED: f32 = 1.3;

const IDENTITY_ROT: [f32; 9] = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];

pub type Pose = ([f32; 9], [f32; 3]);

/// One brick of a model at rest (the game's `UnitPiece`, minus its GPU
/// handles).
pub struct Piece {
    pub slot: Option<u32>,
    pub rest_rot: [f32; 9],
    pub rest_pos: [f32; 3],
}

/// Pieces worn or ridden: a cape, a mount.
pub struct Accessory {
    pub pieces: Vec<Piece>,
}

/// The cape's spring state, carried from frame to frame.
#[derive(Clone, Copy)]
pub struct CapeSwing {
    angle: [[f32; 2]; MAX_CAPE_PIECES],
    vel: [[f32; 2]; MAX_CAPE_PIECES],
    settled: bool,
}

impl Default for CapeSwing {
    fn default() -> Self {
        Self { angle: [[0.0; 2]; MAX_CAPE_PIECES], vel: [[0.0; 2]; MAX_CAPE_PIECES], settled: true }
    }
}

/// The parts of the game's `MinifigBake` the cape reads.
pub struct MinifigBake {
    pub cape: Option<Accessory>,
    pub cape_swing: CapeSwing,
    /// The animal under a rider. `Option<Accessory>` keeps "no mount" in
    /// the `Vec`'s capacity niche, so `mount.is_some()` is a load and a
    /// compare against `i64::MIN`: the crash's `i1` argument.
    pub mount: Option<Accessory>,
    pub gait_phase: f32,
    pub walk_envelope: f32,
}

pub struct WalkAnimation {
    pub ground_ldu_per_sec: f32,
}

#[cfg(not(feature = "cape-wind"))]
#[inline(never)]
fn swing_cape(
    swing: &mut CapeSwing,
    pieces: &[Piece],
    dt: f32,
    trail: f32,
    sideways: f32,
    stir: (f32, f32),
    drape: bool,
) -> ([Pose; MAX_CAPE_PIECES], usize) {
    let mut rest = [(IDENTITY_ROT, [0.0; 3]); MAX_CAPE_PIECES];
    let n = pieces.len().min(MAX_CAPE_PIECES);
    for (slot, piece) in rest.iter_mut().zip(pieces) {
        *slot = (piece.rest_rot, piece.rest_pos);
    }
    swing_cape_chain(swing, &rest[..n], dt, trail, sideways, stir, drape)
}

#[cfg(not(feature = "cape-wind"))]
fn swing_cape_chain(
    swing: &mut CapeSwing,
    rest: &[Pose],
    dt: f32,
    trail: f32,
    sideways: f32,
    (stir_amp, stir_phase): (f32, f32),
    drape: bool,
) -> ([Pose; MAX_CAPE_PIECES], usize) {
    chain(swing, rest, dt, trail, sideways, stir_amp, stir_phase, drape)
}

/// What moves a cape this frame, passed as one argument by reference: the
/// game's fix.
#[cfg(feature = "cape-wind")]
#[derive(Clone, Copy)]
struct CapeWind {
    dt: f32,
    trail: f32,
    sideways: f32,
    stir: (f32, f32),
    drape: bool,
}

#[cfg(feature = "cape-wind")]
#[inline(never)]
fn swing_cape(swing: &mut CapeSwing, pieces: &[Piece], wind: &CapeWind) -> ([Pose; MAX_CAPE_PIECES], usize) {
    let mut rest = [(IDENTITY_ROT, [0.0; 3]); MAX_CAPE_PIECES];
    let n = pieces.len().min(MAX_CAPE_PIECES);
    for (slot, piece) in rest.iter_mut().zip(pieces) {
        *slot = (piece.rest_rot, piece.rest_pos);
    }
    let CapeWind { dt, trail, sideways, stir: (stir_amp, stir_phase), drape } = *wind;
    chain(swing, &rest[..n], dt, trail, sideways, stir_amp, stir_phase, drape)
}

/// A damped spring per band, leaning back by `trail`, across by
/// `sideways`, rippled by the stir, laid flat over a mount when draped.
#[allow(clippy::too_many_arguments)]
fn chain(
    swing: &mut CapeSwing,
    rest: &[Pose],
    dt: f32,
    trail: f32,
    sideways: f32,
    stir_amp: f32,
    stir_phase: f32,
    drape: bool,
) -> ([Pose; MAX_CAPE_PIECES], usize) {
    let mut out = [(IDENTITY_ROT, [0.0; 3]); MAX_CAPE_PIECES];
    let n = rest.len().min(MAX_CAPE_PIECES);
    let held = if drape { 1.2 } else { 0.0 };
    let mut settled = true;
    for i in 0..n {
        let depth = i as f32 / n.max(1) as f32;
        let stir = stir_amp * (stir_phase + depth * 2.2).sin();
        let target = [held + trail * depth + stir, sideways * depth];
        for k in 0..2 {
            let a = swing.angle[i][k];
            let v = swing.vel[i][k] + (42.0 * (target[k] - a) - 4.2 * swing.vel[i][k]) * dt;
            swing.vel[i][k] = v;
            swing.angle[i][k] = a + v * dt;
            settled &= v.abs() < 0.004;
        }
        let (s, c) = swing.angle[i][0].sin_cos();
        out[i] = ([1.0, 0.0, 0.0, 0.0, c, -s, 0.0, s, c], rest[i].1);
    }
    swing.settled = settled;
    (out, n)
}

/// The cape's pose for one frame of one unit, as `animate_minifig` worked
/// it out before calling `swing_cape`.
#[unsafe(no_mangle)]
pub fn pose_cape(
    bake: &mut MinifigBake,
    walk: &WalkAnimation,
    dt: f32,
    facing_yaw: f32,
    prev_yaw: Option<f32>,
    now: f32,
) -> Option<([Pose; MAX_CAPE_PIECES], usize)> {
    if bake.cape.is_some() && dt > 0.0 {
        // How fast the figure is turning, with the wrap taken out.
        let turn = prev_yaw.map_or(0.0, |prev| {
            let mut d = facing_yaw - prev;
            while d > std::f32::consts::PI { d -= std::f32::consts::TAU }
            while d < -std::f32::consts::PI { d += std::f32::consts::TAU }
            d / dt
        });
        // Every stride pumps the cloth and sways it across.
        let beat = bake.gait_phase;
        let pump = CAPE_STRIDE * (beat * 2.0).sin() * bake.walk_envelope;
        let sway = CAPE_SWAY * beat.sin() * bake.walk_envelope;
        let trail = (walk.ground_ldu_per_sec / CAPE_TRAIL_PACE * CAPE_TRAIL)
            .clamp(0.0, CAPE_TRAIL_MAX) + pump;
        let sideways = (-turn * CAPE_TURN).clamp(-CAPE_TURN_MAX, CAPE_TURN_MAX) + sway;
        // The stir is the air going past, so it fades with the walk.
        let stir = (CAPE_STIR * bake.walk_envelope, now * CAPE_STIR_SPEED);
        let MinifigBake { cape, cape_swing, mount, .. } = bake;
        // In the saddle the cloth lies over the animal's back.
        let drape = mount.is_some();
        #[cfg(not(feature = "cape-wind"))]
        return cape.as_ref().map(|acc| swing_cape(cape_swing, &acc.pieces, dt, trail, sideways, stir, drape));
        #[cfg(feature = "cape-wind")]
        return cape.as_ref().map(|acc| swing_cape(cape_swing, &acc.pieces, &CapeWind { dt, trail, sideways, stir, drape }));
    }
    None
}
