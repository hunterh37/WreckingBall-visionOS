import RealityKit
import simd
import Observation
import DicyaninVirtualJoystick
import ImmersiveTestingRuntime
import QuartzCore

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

    /// Units-per-second rate at which full stick deflection moves the integrated position.
    /// At 1.5 the crane travels from center to the edge of its range in ~0.67 s.
    private let speed: Float = 1.5

    /// Integrated planar position (x = slew, y = reach). Clamped to −1…1 on each axis.
    private(set) var planar: SIMD2<Float> = .zero

    /// Integrated vertical position. Clamped to −1…1.
    private(set) var elevation: Float = 0

    /// Timestamp of the previous `apply` call, used to compute dt without a fixed frame rate.
    private var lastApplyTime: Double = CACurrentMediaTime()

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

    /// Reset integrated positions to centre — call on round reset or control-mode change.
    func reset() {
        planar = .zero
        elevation = 0
        lastApplyTime = CACurrentMediaTime()
    }

    /// Fold one frame of joystick output into the hand model. Wired to
    /// `VirtualJoystickBridge.output` by `GameViewModel`.
    ///
    /// Stick deflection is treated as a *velocity*: each call integrates `stick * speed * dt`
    /// into the accumulated position so the crane moves continuously in the pointed direction
    /// rather than snapping to the stick's absolute offset.
    func apply(_ input: VirtualJoystickInput) {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastApplyTime, 0.05))   // cap at 50 ms to survive hitches
        lastApplyTime = now

        if input.rightActive {
            let vel = SIMD2(input.rightDirection.x, input.rightDirection.y)
                        * input.rightMagnitude * speed * dt
            planar = clamp(planar + vel, min: SIMD2(repeating: -1), max: SIMD2(repeating: 1))
        }
        if input.leftActive {
            let vel = input.leftDirection.y * input.leftMagnitude * speed * dt
            elevation = max(-1, min(1, elevation + vel))
        }
    }
}
