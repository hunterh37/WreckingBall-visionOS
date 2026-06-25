import RealityKit
import Observation
import ImmersiveTestingRuntime

// MARK: - CraneControlMode
//
// The two ways to drive the crane. Chosen in the control panel; the immersive scene reads
// it through the router below.

enum CraneControlMode: String, CaseIterable, Identifiable {
    /// Drive the crane directly with the right hand (or, on the simulator, the on-screen
    /// mock-hand joystick).
    case handTracking
    /// Drive the crane with the world-anchored DicyaninVirtualJoystick rig.
    case joystick

    var id: String { rawValue }

    var label: String {
        switch self {
        case .handTracking: return "Hand Tracking"
        case .joystick:     return "Joystick"
        }
    }

    var systemImage: String {
        switch self {
        case .handTracking: return "hand.raised"
        case .joystick:     return "gamecontroller"
        }
    }
}

// MARK: - HandInputRouter
//
// A `HandTrackingProviding` that forwards every read to whichever underlying provider the
// player's selected `CraneControlMode` points at. Because `CraneControlSystem` reads hand
// input only through `SceneEnvironment.hands`, swapping control schemes is just a matter of
// flipping `mode` here — no system, scene-builder, or test changes required.

@MainActor
@Observable
final class HandInputRouter: HandTrackingProviding {

    var mode: CraneControlMode = .handTracking

    /// Real hand tracking (device) or the simulator mock-hand joystick.
    private let tracking: any HandTrackingProviding
    /// The DicyaninVirtualJoystick rig adapter.
    private let joystick: any HandTrackingProviding

    init(tracking: any HandTrackingProviding, joystick: any HandTrackingProviding) {
        self.tracking = tracking
        self.joystick = joystick
    }

    private var active: any HandTrackingProviding {
        mode == .joystick ? joystick : tracking
    }

    var rightPinchDistance: Float { active.rightPinchDistance }
    var leftPinchDistance: Float { active.leftPinchDistance }
    func pointerTipTransform() -> Transform { active.pointerTipTransform() }
    func secondaryTipTransform() -> Transform { active.secondaryTipTransform() }
}
