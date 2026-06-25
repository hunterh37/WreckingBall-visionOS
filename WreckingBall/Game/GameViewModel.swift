import RealityKit
import Observation
import ImmersiveTestingRuntime
import DicyaninVirtualJoystick

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

    /// DicyaninVirtualJoystick rig adapter and the router that lets the player pick between
    /// it and hand tracking at runtime. `CraneControlSystem` reads `router` through the
    /// environment, so flipping `controlMode` is the whole switch.
    let joystickHands = JoystickHandTracking()
    let router: HandInputRouter

    /// The world-anchored joystick rig entity (an arcade-style pillar stand). Lives in the
    /// scene the whole time but is only enabled — and only fed into the crane — while the
    /// joystick control mode is selected.
    let gamepadPillar = GamepadPillarEntity.make()

    /// Which control scheme drives the crane. Bound to the control panel's picker.
    var controlMode: CraneControlMode = .handTracking {
        didSet {
            router.mode = controlMode
            gamepadPillar.isEnabled = (controlMode == .joystick)
        }
    }

    // MARK: Game state — Demolition Derby (30-second rounds)

    /// Seconds in a round.
    let roundDuration: Float = 30
    /// Seconds left in the active round; counts down once a round starts.
    private(set) var timeRemaining: Float = 30
    /// Whether a round is currently running (false before the first round and after time-up).
    private(set) var isRoundActive: Bool = false
    /// The neighbourhood currently standing. Randomised each round unless the player pins it.
    private(set) var cityStyle: StructureBuilder.Cityscape = .suburb
    /// If non-nil, every new round uses this style; nil = pick a random one each round.
    var pinnedStyle: StructureBuilder.Cityscape? = nil

    /// Demolition score: rubble knocked loose so far this round.
    var score: Int = 0
    /// How many destructible blocks remain standing (untouched) — drives the score.
    private(set) var blocksRemaining: Int = 0
    /// Hidden critters bonked this round (bonus points).
    var crittersBonked: Int = 0
    var critterCount: Int = 8
    private(set) var crittersRemaining: Int = 0

    /// True once the clock runs out.
    var roundOver: Bool { !isRoundActive && timeRemaining <= 0 }

    /// Drives the per-second countdown; cancelled when a round ends or restarts.
    private var roundTask: Task<Void, Never>?
    /// Baseline block count captured when the city spawns, so score = toppled blocks.
    private var initialBlockCount: Int = 0

    /// Whether the wrecking ball and rubble collide with the real-world scene mesh. Off by
    /// default; toggled from the control panel. Drives the mesh container's `isEnabled`.
    var sceneCollisionsEnabled: Bool = false {
        didSet { tracking.sceneMeshRoot.isEnabled = sceneCollisionsEnabled }
    }

    init() {
        // World tracking always comes from the live adapter (it self-defaults on simulator).
        // The "hand tracking" scheme is mocked on the simulator and real on device; the
        // router then chooses between that and the joystick at runtime.
        #if targetEnvironment(simulator)
        let trackingHands: any HandTrackingProviding = mockHands
        #else
        let trackingHands: any HandTrackingProviding = tracking
        #endif
        router = HandInputRouter(tracking: trackingHands, joystick: joystickHands)
        environment = CompositeSceneEnvironment(
            worldTracking: tracking,
            hands: router,
            random: SystemRandom()
        )
        root = WreckingBallSceneBuilder().build(config, env: environment)
        // The world-mesh collision bodies must live under the physics root so the ball and
        // rubble collide with real walls. The service populates this container as scene
        // reconstruction streams mesh anchors in.
        root.addChild(tracking.sceneMeshRoot)

        // The joystick rig is always in the scene but starts disabled (hand tracking is the
        // default scheme). The `controlMode` didSet enables it when the player switches.
        gamepadPillar.isEnabled = false
        root.addChild(gamepadPillar)

        CraneControlSystem.environment = environment
        wireJoystickBridge()

        // Bonus points + population bookkeeping whenever the pop system bonks a critter.
        // Fired from the simulation update, so hop to the main actor.
        CritterPopSystem.onPop = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.crittersBonked += 1
                self.crittersRemaining = max(self.crittersRemaining - 1, 0)
            }
        }
        startRound()
    }

    // MARK: Game flow

    /// Records each block's spawn position so the score can count how many were knocked loose.
    private var blockOrigins: [ObjectIdentifier: SIMD3<Float>] = [:]

    /// Stands up a fresh round: pick (or keep) a neighbourhood, spawn the city + hidden
    /// critters, reset the ball, and start the 30-second clock.
    func startRound() {
        cityStyle = pinnedStyle ?? Self.randomStyle(environment)
        spawnCity()
        spawnCritters()
        resetBall()

        score = 0
        crittersBonked = 0
        timeRemaining = roundDuration
        isRoundActive = true

        roundTask?.cancel()
        roundTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                if !self.isRoundActive { return }
                self.timeRemaining = max(self.timeRemaining - 0.25, 0)
                self.recomputeScore()
                if self.timeRemaining <= 0 {
                    self.isRoundActive = false
                    return
                }
            }
        }
    }

    private static func randomStyle(_ env: any SceneEnvironment) -> StructureBuilder.Cityscape {
        let all = StructureBuilder.Cityscape.allCases
        return all[min(Int(env.random.next() * Float(all.count)), all.count - 1)]
    }

    /// Tears down the previous neighbourhood and procedurally builds a fresh one, capturing
    /// every block's origin for scoring.
    private func spawnCity() {
        root.findEntity(named: "structures")?.removeFromParent()
        root.findEntity(named: "towers")?.removeFromParent()   // legacy sandbox content
        let city = StructureBuilder.makeCity(style: cityStyle, config: config, env: environment)
        root.addChild(city)

        blockOrigins.removeAll()
        forEachBlock(in: city) { block in
            blockOrigins[ObjectIdentifier(block)] = block.position(relativeTo: nil)
        }
        initialBlockCount = blockOrigins.count
        blocksRemaining = initialBlockCount
    }

    /// Score = blocks knocked loose this round + 5 per bonked critter. Recomputed on the tick.
    private func recomputeScore() {
        guard let city = root.findEntity(named: "structures") else { return }
        var toppled = 0
        forEachBlock(in: city) { block in
            guard let origin = blockOrigins[ObjectIdentifier(block)] else { return }
            if distance(block.position(relativeTo: nil), origin) > 0.18 { toppled += 1 }
        }
        blocksRemaining = max(initialBlockCount - toppled, 0)
        score = toppled + crittersBonked * 5
    }

    private func forEachBlock(in entity: Entity, _ body: (Entity) -> Void) {
        if entity.components[TowerBlockComponent.self] != nil { body(entity) }
        for child in entity.children { forEachBlock(in: child, body) }
    }

    /// (Re)hides the alien critters around the room.
    private func spawnCritters() {
        root.findEntity(named: "critters")?.removeFromParent()
        let critters = CritterBuilder.makeCritters(count: critterCount, config: config, env: environment)
        root.addChild(critters)
        crittersRemaining = critterCount
    }

    /// Connect the standalone DicyaninVirtualJoystick package to this app. The rig only runs
    /// while the joystick scheme is selected, and its per-frame stick output is folded into
    /// `joystickHands` so the crane reads it as ordinary hand input.
    private func wireJoystickBridge() {
        VirtualJoystickBridge.isEnabled = { [weak self] in
            self?.controlMode == .joystick
        }

        VirtualJoystickBridge.output = { [weak self] input in
            // Called from the RealityKit simulation update; hop to the main actor to touch
            // the observable adapter.
            Task { @MainActor in self?.joystickHands.apply(input) }
        }

        // Per-hand pinch positions let the rig's sticks be grabbed by hand on device (nil in
        // the simulator, where the package falls back to a drag gesture).
        #if !targetEnvironment(simulator)
        VirtualJoystickBridge.handPinchProvider = { [weak self] in
            guard let self else { return nil }
            return VirtualJoystickHandPinch(
                left:  self.tracking.isLeftPinching()  ? self.tracking.leftPinchPosition  : nil,
                right: self.tracking.isRightPinching() ? self.tracking.rightPinchPosition : nil
            )
        }
        #endif
    }

    func startTracking() async {
        await tracking.run()
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
