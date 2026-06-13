import RealityKit
import simd

// MARK: - Game components
//
// Pure value-type ECS markers/state. Everything in this file (and the rest of the Game
// layer) is constructible headlessly — no ARKit, no singletons — so tests build and drive
// the real graph on CI, mirroring the ImmersiveTesting architecture guide.

/// The kinematic hook the wrecking-ball chain hangs from. The crane control system moves
/// this entity each frame from the player's right-hand pose; physics joints do the rest.
struct CraneAnchorComponent: Component {
    /// World-space point the hook rests at when the hand is in its neutral pose. Kept for
    /// build-time placement and as the reference the chain hangs from.
    var neutralAnchorPosition: SIMD3<Float>
    /// World-space XZ of the mast the hook orbits as the jib slews.
    var mastXZ: SIMD2<Float>
    /// Hand position (world space) treated as "centred" — a comfortable right-hand rest pose.
    var neutralHandPosition: SIMD3<Float> = [0.25, 1.05, -0.45]

    // Polar control: the hand drives the hook in (azimuth, radius, height) around the mast
    // rather than inside a forward box, so the jib can slew a full 360°.
    /// Radians of slew per metre of left/right (x) hand travel. Sized so a comfortable hand
    /// sweep reaches the full ±π, letting the crane swing all the way around.
    var yawGain: Float = 8
    /// Metres of reach change per metre of forward/back (z) hand travel; pushing the hand
    /// away from you extends the hook outward.
    var radiusGain: Float = 9
    /// Metres of hook lift per metre of up/down (y) hand travel.
    var heightGain: Float = 5
    /// Reach (distance from the mast) when the hand is neutral, and its clamp range.
    var neutralRadius: Float
    var minRadius: Float
    var maxRadius: Float
    /// Hook height when the hand is neutral, and its clamp range.
    var neutralHeight: Float
    var minHeight: Float
    var maxHeight: Float
    /// Exponential smoothing rate (1/s). Higher = snappier crane.
    var smoothing: Float = 7
}

/// The rotating jib assembly. The control system yaws it about the mast so the arm
/// visually tracks the hook, like a real tower crane slewing.
struct CraneJibComponent: Component {
    /// World-space XZ position of the mast the jib slews around.
    var mastXZ: SIMD2<Float>
}

/// The trolley that rides along the jib above the hook.
struct CraneTrolleyComponent: Component {
    /// How far the trolley may travel from the mast along the jib, in metres.
    var minRadius: Float
    var maxRadius: Float
}

/// Marks the wrecking ball.
struct WreckingBallComponent: Component {}

/// Marks one chain link between the anchor and the ball.
struct ChainLinkComponent: Component {
    var index: Int
}

/// Marks a destructible block (or other rubble object) belonging to a tower.
struct TowerBlockComponent: Component {}

/// Collision groups so chain links thread freely instead of tangling on towers.
@MainActor
enum GameCollision {
    static let scenery = CollisionGroup(rawValue: 1 << 0)   // ground, blocks, ball
    static let chain   = CollisionGroup(rawValue: 1 << 1)   // links: collide with nothing
}
