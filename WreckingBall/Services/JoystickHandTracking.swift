import RealityKit
import simd
import Observation
import DicyaninVirtualJoystick
import ImmersiveTestingRuntime

// MARK: - JoystickHandTracking
//
// A `HandTrackingProviding` adapter driven by the DicyaninVirtualJoystick rig instead of
// ARKit hands. The world-anchored joystick rig reports a normalized two-stick output every
// frame through `VirtualJoystickBridge.output`; we fold that into the same neutral-hand +
// reach model `MockHandTracking` uses, so `CraneControlSystem` reads a pointer-tip transform
// and never knows whether a hand or a joystick produced it.
//
// Unlike `MockHandTracking` this is NOT simulator-gated — the joystick is a real, on-device
// control scheme the player can pick in the control panel.
//
// Stick mapping (chosen to match the package's own channel semantics, where the LEFT stick
// is the "height/throttle" channel and the RIGHT stick is the planar "pitch/roll" channel):
//   • RIGHT stick X → crane slew (left/right azimuth)
//   • RIGHT stick Y → crane reach (push away = extend the hook outward)
//   • LEFT  stick Y → hook height (raise / lower)

@MainActor
@Observable
final class JoystickHandTracking: HandTrackingProviding {

    /// Hand pose treated as "centred" — matches `CraneAnchorComponent.neutralHandPosition`
    /// so a zeroed stick parks the crane at its neutral hook spot.
    private let neutralHand = SIMD3<Float>(0.25, 1.05, -0.45)

    /// How far full stick deflection pushes the hand from neutral, per axis (metres). The
    /// crane's polar control maps this small reach onto a full 360° slew, full reach, and
    /// full lift.
    private let reach = SIMD3<Float>(0.4, 0.4, 0.4)

    /// Planar stick (right joystick): x = slew, y = reach. Range roughly −1...1.
    private(set) var planar: SIMD2<Float> = .zero

    /// Vertical channel (left joystick Y): up/down hook travel. Range −1...1.
    private(set) var elevation: Float = 0

    var rightPinchDistance: Float { 1 }
    var leftPinchDistance: Float { 1 }

    func pointerTipTransform() -> Transform {
        let offset = SIMD3<Float>(
            planar.x * reach.x,
            elevation * reach.y,
            -planar.y * reach.z
        )
        return Transform(translation: neutralHand + offset)
    }

    /// Fold one frame of joystick output into the hand model. Wired to
    /// `VirtualJoystickBridge.output` by `GameViewModel`.
    func apply(_ input: VirtualJoystickInput) {
        if input.rightActive {
            planar = SIMD2(input.rightDirection.x, input.rightDirection.y) * input.rightMagnitude
        } else {
            planar = .zero
        }
        elevation = input.leftActive ? input.leftDirection.y * input.leftMagnitude : 0
    }
}
