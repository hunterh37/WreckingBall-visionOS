import RealityKit
import Observation
import ImmersiveTestingRuntime

// MARK: - GameViewModel
//
// Drives state transitions on the scene root (respawn, reset) — the view shell stays
// logic-free. Owns the production `SceneEnvironment` wired with the live ARKit adapter.

@MainActor
@Observable
final class GameViewModel {

    let config = WreckingBallSceneBuilder.Config()
    let environment: CompositeSceneEnvironment
    let root: Entity
    private let tracking = SpatialTrackingService()

    #if targetEnvironment(simulator)
    /// Joystick-driven mock hand, swapped in for the absent simulator hand tracking. The
    /// control panel reads/writes this; `nil` on device.
    let mockHands = MockHandTracking()
    #endif

    /// Tower preset chosen in the control panel.
    var towerCount: Int = 3
    var towerHeight: Int = 8

    /// Whether the wrecking ball and rubble collide with the real-world scene mesh. Off by
    /// default; toggled from the control panel. Drives the mesh container's `isEnabled`.
    var sceneCollisionsEnabled: Bool = false {
        didSet { tracking.sceneMeshRoot.isEnabled = sceneCollisionsEnabled }
    }

    init() {
        // World tracking always comes from the live adapter (it self-defaults on simulator).
        // Hand input is mocked on the simulator and real on device.
        #if targetEnvironment(simulator)
        let hands: any HandTrackingProviding = mockHands
        #else
        let hands: any HandTrackingProviding = tracking
        #endif
        environment = CompositeSceneEnvironment(
            worldTracking: tracking,
            hands: hands,
            random: SystemRandom()
        )
        root = WreckingBallSceneBuilder().build(config, env: environment)
        // The world-mesh collision bodies must live under the physics root so the ball and
        // rubble collide with real walls. The service populates this container as scene
        // reconstruction streams mesh anchors in.
        root.addChild(tracking.sceneMeshRoot)
        CraneControlSystem.environment = environment
    }

    func startTracking() async {
        await tracking.run()
    }

    /// Clears the rubble and stands up a fresh set of towers at the chosen preset.
    func respawnTowers() {
        var c = config
        c.towerCount = towerCount
        c.towerBlockRows = towerHeight
        WreckingBallSceneBuilder.respawnTowers(in: root, config: c, env: environment)
    }

    /// Hangs the ball and chain straight back under the hook and kills their momentum.
    func resetBall() {
        guard let anchor = root.findEntity(named: "hookAnchor") else { return }
        let top = anchor.position(relativeTo: nil)
        for i in 0..<config.chainLinkCount {
            guard let link = root.findEntity(named: "chainLink_\(i)") else { continue }
            link.setPosition(top - [0, (Float(i) + 0.5) * config.chainLinkLength, 0], relativeTo: nil)
            link.setOrientation(.init(), relativeTo: nil)
            link.components.set(PhysicsMotionComponent())
        }
        if let ball = root.findEntity(named: "wreckingBall") {
            let chain = Float(config.chainLinkCount) * config.chainLinkLength
            ball.setPosition(top - [0, chain + config.ballRadius, 0], relativeTo: nil)
            ball.components.set(PhysicsMotionComponent())
        }
    }
}

/// Production RNG behind the `RandomProviding` protocol (tests use `SeededRandom`).
@MainActor
final class SystemRandom: RandomProviding {
    func next() -> Float { Float.random(in: 0..<1) }
}
