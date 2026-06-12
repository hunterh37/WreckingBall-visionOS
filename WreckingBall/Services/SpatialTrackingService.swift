import ARKit
import QuartzCore
import RealityKit
import simd
import ImmersiveTestingRuntime

// MARK: - SpatialTrackingService
//
// The services-layer live adapter: the one type in the app allowed to import ARKit.
// It runs a single ARKitSession with hand + world tracking and conforms to the
// ImmersiveTesting provider protocols, so the Game layer reads poses through
// `SceneEnvironment` and never touches ARKit (tests swap in `ScriptedHands` /
// `FakeWorldTracking`).

@MainActor
final class SpatialTrackingService: WorldTrackingProviding, HandTrackingProviding {

    private let session = ARKitSession()
    private let handProvider = HandTrackingProvider()
    private let worldProvider = WorldTrackingProvider()

    // Latest poses, refreshed by the update streams.
    private var rightIndexTip = Transform(translation: [0.25, 1.05, -0.45])
    private(set) var rightPinchDistance: Float = 1
    private(set) var leftPinchDistance: Float = 1

    // MARK: Session

    /// Starts tracking and consumes hand updates until cancelled. Call from a `.task`
    /// attached to the immersive view.
    func run() async {
        guard HandTrackingProvider.isSupported else { return }   // simulator: keep fakes-ish defaults
        do {
            try await session.run([handProvider, worldProvider])
        } catch {
            print("SpatialTrackingService failed to start: \(error)")
            return
        }
        for await update in handProvider.anchorUpdates {
            guard update.event == .updated || update.event == .added else { continue }
            ingest(update.anchor)
        }
    }

    private func ingest(_ anchor: HandAnchor) {
        guard anchor.isTracked, let skeleton = anchor.handSkeleton else { return }
        let originFromAnchor = anchor.originFromAnchorTransform
        func worldPosition(_ joint: HandSkeleton.JointName) -> SIMD3<Float> {
            let m = originFromAnchor * skeleton.joint(joint).anchorFromJointTransform
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        let index = worldPosition(.indexFingerTip)
        let thumb = worldPosition(.thumbTip)
        switch anchor.chirality {
        case .right:
            rightPinchDistance = distance(index, thumb)
            rightIndexTip = Transform(translation: index)
        case .left:
            leftPinchDistance = distance(index, thumb)
        }
    }

    // MARK: HandTrackingProviding

    func pointerTipTransform() -> Transform { rightIndexTip }

    // MARK: WorldTrackingProviding

    func deviceTransform() -> Transform {
        guard worldProvider.state == .running,
              let device = worldProvider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())
        else { return Transform(translation: [0, 1.4, 0]) }
        return Transform(matrix: device.originFromAnchorTransform)
    }
}
