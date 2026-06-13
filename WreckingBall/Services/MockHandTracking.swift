import RealityKit
import simd
import Observation
import ImmersiveTestingRuntime

// MARK: - MockHandTracking
//
// Simulator-only stand-in for `SpatialTrackingService`'s hand input. The Vision Pro
// simulator has no hand tracking, so on the simulator we swap this in and let an on-screen
// joystick drive the "right hand" pointer that `CraneControlSystem` reads each frame. The
// math mirrors `ScriptedHands` (the headless test fake) but is wired to live UI state.
//
// Production builds never compile this — see `GameViewModel`'s `targetEnvironment(simulator)`
// switch. The world-tracking pose still comes from the real `SpatialTrackingService`, which
// already falls back to a sensible default head pose on the simulator.

@MainActor
@Observable
final class MockHandTracking: HandTrackingProviding {

    /// Hand pose treated as "centred" — matches `CraneAnchorComponent.neutralHandPosition`
    /// so a zeroed joystick parks the crane at its neutral hook spot.
    private let neutralHand = SIMD3<Float>(0.25, 1.05, -0.45)

    /// How far the joystick can push the hand from neutral, per axis (metres). The crane's
    /// polar control maps this small reach onto a full 360° slew, full reach, and full lift.
    private let reach = SIMD3<Float>(0.4, 0.4, 0.4)

    /// Joystick: x = left/right (→ hand X), y = forward/back (→ hand −Z). Range −1...1.
    var joystick: SIMD2<Float> = .zero

    /// Vertical slider: up/down hand travel. Range −1...1.
    var elevation: Float = 0

    /// Pinch toggle, so simulator testing can still exercise pinch-gated logic. The crane
    /// game ignores pinch today, but keeping it real costs nothing.
    var isPinching: Bool = false

    var rightPinchDistance: Float { isPinching ? 0.02 : 1.0 }
    var leftPinchDistance: Float { 1.0 }

    func pointerTipTransform() -> Transform {
        let offset = SIMD3<Float>(
            joystick.x * reach.x,
            elevation * reach.y,
            -joystick.y * reach.z
        )
        return Transform(translation: neutralHand + offset)
    }
}
