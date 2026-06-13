import RealityKit
import UIKit
import ImmersiveTestingRuntime

// MARK: - WreckingBallSceneBuilder
//
// Pure (Config, SceneEnvironment) → Entity, per the ImmersiveTesting architecture: the
// identical graph the headset renders is what headless tests assert against. All sizes are
// metres in world space; the user stands at the origin facing -Z, so the GIANT crane towers
// in front of them with the demolition yard between.
//
// Physics joints can only be wired once the graph is inside a live RealityKit scene, so
// construction is two-phase: `build` makes the bodies, `connectJoints` (called from the
// RealityView make closure) pins the chain together.

struct WreckingBallSceneBuilder: SceneBuilder {

    struct Config {
        // Crane
        var mastPosition: SIMD3<Float> = [0, 0, -7]
        var mastHeight: Float = 10
        var jibLength: Float = 6.5
        var chainLinkCount: Int = 6
        var chainLinkLength: Float = 0.55
        var ballRadius: Float = 0.6
        var ballMass: Float = 1200
        // Towers
        var towerCount: Int = 3
        var towerBlockColumns: Int = 3      // square footprint, columns × columns
        var towerBlockRows: Int = 8
        var blockSize: Float = 0.5
        var blockMass: Float = 18
        // Towers spawn in a 360° ring centred under the ball's swing, between these
        // fractions of the pendulum's horizontal reach so the ball can actually hit them.
        var spawnRadiusRange: ClosedRange<Float> = 0.45...0.85
    }

    // Hook geometry shared by build-time placement and the control system's clamp box.
    static func neutralAnchorPosition(_ c: Config) -> SIMD3<Float> {
        [c.mastPosition.x, c.mastHeight - 1.2, c.mastPosition.z + (c.jibLength - 0.5)]
    }

    /// Length from the hook anchor to the ball's centre — the pendulum's swing radius.
    static func pendulumLength(_ c: Config) -> Float {
        Float(c.chainLinkCount) * c.chainLinkLength + c.ballRadius
    }

    /// Ground-plane point the ball swings around (anchor projected straight down).
    static func swingPivotXZ(_ c: Config) -> SIMD2<Float> {
        let a = neutralAnchorPosition(c)
        return [a.x, a.z]
    }

    func build(_ config: Config, env: any SceneEnvironment) -> Entity {
        let root = Entity("gameRoot")
        root.components.set(PhysicsSimulationComponent())

        root.addChild(Self.makeGround())
        root.addChild(Self.makeCrane(config))
        root.addChild(Self.makeBallAssembly(config))
        root.addChild(Self.makeTowers(config, env: env))
        return root
    }

    // MARK: Ground

    static func makeGround() -> Entity {
        let ground = ModelEntity(
            mesh: .generateBox(width: 30, height: 0.1, depth: 30, cornerRadius: 0.02),
            materials: [SimpleMaterial(color: UIColor(white: 0.25, alpha: 1), isMetallic: false)]
        )
        ground.name = "ground"
        ground.position = [0, -0.05, -5]
        ground.components.set(CollisionComponent(
            shapes: [.generateBox(width: 30, height: 0.1, depth: 30)],
            filter: CollisionFilter(group: GameCollision.scenery, mask: .all)
        ))
        ground.components.set(PhysicsBodyComponent(
            shapes: [.generateBox(width: 30, height: 0.1, depth: 30)],
            mass: 0,
            material: .generate(staticFriction: 0.9, dynamicFriction: 0.8, restitution: 0.05),
            mode: .static
        ))
        return ground
    }

    // MARK: Crane (static mast + slewing jib + trolley + kinematic hook anchor)

    static func makeCrane(_ c: Config) -> Entity {
        let crane = Entity("crane")
        let yellow = SimpleMaterial(color: UIColor(red: 0.95, green: 0.72, blue: 0.05, alpha: 1), isMetallic: true)
        let steel = SimpleMaterial(color: UIColor(white: 0.55, alpha: 1), isMetallic: true)

        // Mast — a giant lattice-style column (visual only; nothing collides with it up high,
        // and a static slab at its base keeps rubble from rolling inside).
        let mast = ModelEntity(mesh: .generateBox(width: 0.9, height: c.mastHeight, depth: 0.9), materials: [yellow])
        mast.name = "mast"
        mast.position = c.mastPosition + [0, c.mastHeight / 2, 0]
        let base = ModelEntity(mesh: .generateBox(width: 2.4, height: 0.6, depth: 2.4), materials: [steel])
        base.name = "mastBase"
        base.position = c.mastPosition + [0, 0.3, 0]
        base.components.set(CollisionComponent(
            shapes: [.generateBox(width: 2.4, height: 0.6, depth: 2.4)],
            filter: CollisionFilter(group: GameCollision.scenery, mask: .all)
        ))
        base.components.set(PhysicsBodyComponent(
            shapes: [.generateBox(width: 2.4, height: 0.6, depth: 2.4)], mass: 0, mode: .static
        ))
        crane.addChild(mast)
        crane.addChild(base)

        // Jib pivot sits atop the mast; the arm hangs off it toward +Z (toward the player)
        // and the control system yaws the pivot so the arm chases the hook.
        let jibPivot = Entity("jibPivot")
        jibPivot.position = c.mastPosition + [0, c.mastHeight - 0.6, 0]
        jibPivot.components.set(CraneJibComponent(mastXZ: [c.mastPosition.x, c.mastPosition.z]))

        let arm = ModelEntity(mesh: .generateBox(width: 0.5, height: 0.5, depth: c.jibLength), materials: [yellow])
        arm.name = "jibArm"
        arm.position = [0, 0, c.jibLength / 2]          // extends along the pivot's local +Z
        let counterweight = ModelEntity(mesh: .generateBox(width: 1.2, height: 0.9, depth: 1.4), materials: [steel])
        counterweight.name = "counterweight"
        counterweight.position = [0, -0.2, -1.6]
        jibPivot.addChild(arm)
        jibPivot.addChild(counterweight)

        let trolley = ModelEntity(mesh: .generateBox(width: 0.7, height: 0.3, depth: 0.7), materials: [steel])
        trolley.name = "trolley"
        trolley.components.set(CraneTrolleyComponent(minRadius: 1.2, maxRadius: c.jibLength - 0.3))
        trolley.position = [0, -0.4, c.jibLength - 0.5]   // ride near the tip of the jib
        jibPivot.addChild(trolley)
        crane.addChild(jibPivot)

        // Hook anchor — the kinematic body the chain is pinned to. Lives at root level
        // (not under the rotating jib) so the control system can drive it in world space.
        let neutral = neutralAnchorPosition(c)
        let anchor = ModelEntity(mesh: .generateBox(size: 0.25), materials: [steel])
        anchor.name = "hookAnchor"
        anchor.position = neutral
        anchor.components.set(CraneAnchorComponent(
            neutralAnchorPosition: neutral,
            mastXZ: [c.mastPosition.x, c.mastPosition.z],
            neutralRadius: c.jibLength - 0.5,
            minRadius: 1.2,
            maxRadius: c.jibLength - 0.3,
            neutralHeight: c.mastHeight - 1.2,
            minHeight: c.mastHeight - 3.5,
            maxHeight: c.mastHeight - 0.8
        ))
        anchor.components.set(CollisionComponent(
            shapes: [.generateBox(size: [0.25, 0.25, 0.25])],
            filter: CollisionFilter(group: GameCollision.chain, mask: [])
        ))
        anchor.components.set(PhysicsBodyComponent(
            shapes: [.generateBox(size: [0.25, 0.25, 0.25])], mass: 0, mode: .kinematic
        ))
        crane.addChild(anchor)
        return crane
    }

    // MARK: Ball + chain

    static func makeBallAssembly(_ c: Config) -> Entity {
        let assembly = Entity("ballAssembly")
        let anchorPos = neutralAnchorPosition(c)
        let linkMat = SimpleMaterial(color: UIColor(white: 0.35, alpha: 1), isMetallic: true)

        // Chain links: slim dynamic bodies pinned end-to-end. They collide with nothing
        // (chain group, empty mask) so the chain never snags — only the ball does damage.
        for i in 0..<c.chainLinkCount {
            let link = ModelEntity(
                mesh: .generateBox(width: 0.09, height: c.chainLinkLength, depth: 0.09, cornerRadius: 0.03),
                materials: [linkMat]
            )
            link.name = "chainLink_\(i)"
            link.components.set(ChainLinkComponent(index: i))
            link.position = anchorPos - [0, (Float(i) + 0.5) * c.chainLinkLength, 0]
            link.components.set(CollisionComponent(
                shapes: [.generateBox(width: 0.09, height: c.chainLinkLength, depth: 0.09)],
                filter: CollisionFilter(group: GameCollision.chain, mask: [])
            ))
            var body = PhysicsBodyComponent(
                shapes: [.generateBox(width: 0.09, height: c.chainLinkLength, depth: 0.09)],
                mass: 30,
                material: .generate(staticFriction: 0.5, dynamicFriction: 0.5, restitution: 0),
                mode: .dynamic
            )
            body.linearDamping = 0.15
            body.angularDamping = 0.4
            link.components.set(body)
            assembly.addChild(link)
        }

        // The ball: heavy, hard, barely bouncy — demolition iron.
        let ball = ModelEntity(
            mesh: .generateSphere(radius: c.ballRadius),
            materials: [SimpleMaterial(color: UIColor(white: 0.12, alpha: 1), isMetallic: true)]
        )
        ball.name = "wreckingBall"
        ball.components.set(WreckingBallComponent())
        let chainLength = Float(c.chainLinkCount) * c.chainLinkLength
        ball.position = anchorPos - [0, chainLength + c.ballRadius, 0]
        ball.components.set(CollisionComponent(
            shapes: [.generateSphere(radius: c.ballRadius)],
            filter: CollisionFilter(group: GameCollision.scenery, mask: .all)
        ))
        var ballBody = PhysicsBodyComponent(
            shapes: [.generateSphere(radius: c.ballRadius)],
            mass: c.ballMass,
            material: .generate(staticFriction: 0.6, dynamicFriction: 0.5, restitution: 0.1),
            mode: .dynamic
        )
        ballBody.linearDamping = 0.05
        ballBody.angularDamping = 0.1
        ball.components.set(ballBody)
        assembly.addChild(ball)
        return assembly
    }

    /// Pins anchor → links → ball with spherical joints. Call once the root is inside a
    /// live scene (RealityView's make closure); joints can't register before that.
    @discardableResult
    static func connectJoints(root: Entity, config: Config = Config()) throws -> Int {
        guard let anchor = root.findEntity(named: "hookAnchor") else { return 0 }
        let half = config.chainLinkLength / 2
        var jointCount = 0
        var upper = anchor
        var upperPinOffset: SIMD3<Float> = [0, -0.12, 0]    // bottom of the hook block

        for i in 0..<config.chainLinkCount {
            guard let link = root.findEntity(named: "chainLink_\(i)") else { break }
            let pin0 = upper.pins.set(named: "toLink\(i)", position: upperPinOffset)
            let pin1 = link.pins.set(named: "top", position: [0, half, 0])
            try PhysicsSphericalJoint(pin0: pin0, pin1: pin1).addToSimulation()
            jointCount += 1
            upper = link
            upperPinOffset = [0, -half, 0]
        }

        if let ball = root.findEntity(named: "wreckingBall") {
            let pin0 = upper.pins.set(named: "toBall", position: upperPinOffset)
            let pin1 = ball.pins.set(named: "top", position: [0, config.ballRadius, 0])
            try PhysicsSphericalJoint(pin0: pin0, pin1: pin1).addToSimulation()
            jointCount += 1
        }
        return jointCount
    }

    // MARK: Towers

    /// Builds the destructible yard: `towerCount` cube towers ringed around the yard centre
    /// (placement from the injected RNG ⇒ seedable in tests), plus a few loose barrels.
    static func makeTowers(_ c: Config, env: any SceneEnvironment) -> Entity {
        let towersRoot = Entity("towers")
        let palette: [UIColor] = [.systemRed, .systemOrange, .systemTeal, .systemIndigo, .systemGreen]
        let blockMaterialFor: (Int) -> SimpleMaterial = { idx in
            SimpleMaterial(color: palette[idx % palette.count], isMetallic: false)
        }

        let pivot = swingPivotXZ(c)
        let reach = pendulumLength(c)

        for t in 0..<c.towerCount {
            // Even slices of the full circle, jittered, so towers ring the swing pivot at
            // random 360° positions while staying within the ball's horizontal reach.
            let baseAngle = (Float(t) / Float(max(c.towerCount, 1))) * 2 * .pi
            let jitter = env.random.next(in: -0.4...0.4)
            let angle = baseAngle + jitter
            let radius = reach * env.random.next(in: c.spawnRadiusRange)
            let center = SIMD3(pivot.x + cos(angle) * radius, 0, pivot.y + sin(angle) * radius)

            let tower = Entity("tower_\(t)")
            let s = c.blockSize
            let footprint = Float(c.towerBlockColumns) * s
            for row in 0..<c.towerBlockRows {
                for cx in 0..<c.towerBlockColumns {
                    for cz in 0..<c.towerBlockColumns {
                        let block = ModelEntity(
                            mesh: .generateBox(size: s * 0.98, cornerRadius: 0.015),
                            materials: [blockMaterialFor(row + cx + cz)]
                        )
                        block.name = "block_t\(t)_r\(row)_\(cx)_\(cz)"
                        block.components.set(TowerBlockComponent())
                        block.position = center + SIMD3(
                            (Float(cx) + 0.5) * s - footprint / 2,
                            (Float(row) + 0.5) * s,
                            (Float(cz) + 0.5) * s - footprint / 2
                        )
                        block.components.set(CollisionComponent(
                            shapes: [.generateBox(size: [s, s, s])],
                            filter: CollisionFilter(group: GameCollision.scenery, mask: .all)
                        ))
                        var body = PhysicsBodyComponent(
                            shapes: [.generateBox(size: [s, s, s])],
                            mass: c.blockMass,
                            material: .generate(staticFriction: 0.8, dynamicFriction: 0.7, restitution: 0.05),
                            mode: .dynamic
                        )
                        // Stacked boxes settle instead of jittering.
                        body.linearDamping = 0.05
                        body.angularDamping = 0.2
                        block.components.set(body)
                        // Heavy stacks sleep until the ball arrives.
                        block.components.set(PhysicsMotionComponent())
                        tower.addChild(block)
                    }
                }
            }
            towersRoot.addChild(tower)
        }

        // A few loose "other objects" — barrels scattered between towers.
        for b in 0..<4 {
            let barrel = ModelEntity(
                mesh: .generateCylinder(height: 0.7, radius: 0.22),
                materials: [SimpleMaterial(color: .systemYellow, isMetallic: true)]
            )
            barrel.name = "barrel_\(b)"
            barrel.components.set(TowerBlockComponent())
            let dir = env.random.unitVectorXZ()
            let r = reach * env.random.next(in: c.spawnRadiusRange)
            barrel.position = SIMD3(pivot.x + dir.x * r, 0.35, pivot.y + dir.z * r)
            barrel.components.set(CollisionComponent(
                shapes: [.generateCapsule(height: 0.7, radius: 0.22)],
                filter: CollisionFilter(group: GameCollision.scenery, mask: .all)
            ))
            barrel.components.set(PhysicsBodyComponent(
                shapes: [.generateCapsule(height: 0.7, radius: 0.22)],
                mass: 12,
                material: .generate(staticFriction: 0.6, dynamicFriction: 0.5, restitution: 0.2),
                mode: .dynamic
            ))
            towersRoot.addChild(barrel)
        }
        return towersRoot
    }

    /// Removes the current towers and spawns a fresh set (the respawn button).
    static func respawnTowers(in root: Entity, config: Config = Config(), env: any SceneEnvironment) {
        root.findEntity(named: "towers")?.removeFromParent()
        root.addChild(makeTowers(config, env: env))
    }
}
