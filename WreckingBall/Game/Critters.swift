import RealityKit
import UIKit
import simd
import ImmersiveTestingRuntime

// MARK: - Alien Critters
//
// The game layer over the demolition sandbox: little glowing slime aliens hide throughout
// the player's room. Knock them out with the wrecking ball before you run out of whacks.
// Pure (Config/env) → Entity builders plus a headless-drivable proximity system, matching
// the ImmersiveTesting pattern used by CraneControlSystem.

/// Marks a hideable alien critter. `popped` flips once the ball reaches it so the system
/// scores it exactly once.
struct AlienCritterComponent: Component {
    var radius: Float = 0.16
    var popped: Bool = false
    /// Seconds left in the squish-and-vanish animation once popped (counted down by the
    /// system); the entity is removed when it hits zero.
    var popTimer: Float = 0
}

// MARK: Builder

@MainActor
enum CritterBuilder {

    /// Scatters `count` slime aliens around the play space: a full 360° ring at random
    /// radius/height so they tuck against the real room (walls, furniture, on top of the
    /// towers) when room collisions are on, and float in space otherwise.
    static func makeCritters(count: Int,
                             config: WreckingBallSceneBuilder.Config,
                             env: any SceneEnvironment) -> Entity {
        let root = Entity()
        root.name = "critters"
        let pivot = WreckingBallSceneBuilder.swingPivotXZ(config)
        let reach = WreckingBallSceneBuilder.pendulumLength(config)

        for i in 0..<count {
            let angle = (Float(i) / Float(max(count, 1))) * 2 * .pi + env.random.next(in: -0.5...0.5)
            let radius = reach * env.random.next(in: 0.35...0.95)
            let height = env.random.next(in: 0.3...2.2)
            let pos = SIMD3<Float>(pivot.x + cos(angle) * radius, height, pivot.y + sin(angle) * radius)
            let critter = makeCritter(index: i, env: env)
            critter.position = pos
            root.addChild(critter)
        }
        return root
    }

    /// The cute ghosty archetypes — each lays out the bubbly metasphere body differently.
    enum Shape: CaseIterable {
        case blob       // squat, round, big head
        case tall       // stretched, two stacked lobes
        case wisp       // small head, long bubbly tail
        case chubby     // wide cheeks, short tail
        case tiny       // little baby ghost, single lobe
    }

    /// Cyber-green glowing goop the whole metasphere is skinned in.
    private static var ghostMaterial: RealityKit.Material {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: 0.20, green: 1.0, blue: 0.45, alpha: 1))
        m.roughness = 0.15
        m.metallic = 0.0
        m.emissiveColor = .init(color: UIColor(red: 0.15, green: 1.0, blue: 0.40, alpha: 1))
        m.emissiveIntensity = 1.6
        m.blending = .transparent(opacity: 0.96)
        return m
    }

    /// One ghosty critter: a bubbly "metasphere" body built from overlapping spheres
    /// (varied shape + size), two big eyes, glowing cyber-green. A single sphere collider on
    /// the host keeps physics cheap while the lobes give it character.
    static func makeCritter(index: Int, env: any SceneEnvironment) -> Entity {
        let shape = Shape.allCases[min(Int(env.random.next() * Float(Shape.allCases.count)),
                                       Shape.allCases.count - 1)]
        let size: Float = env.random.next(in: 0.7...1.5)   // overall scale jitter
        let r: Float = 0.16 * size                          // head/collision radius

        // Host carries the gameplay component + one cheap sphere collider sized to the head.
        let host = Entity()
        host.name = "critter_\(index)"
        host.components.set(AlienCritterComponent(radius: r))
        host.components.set(CollisionComponent(
            shapes: [.generateSphere(radius: r)],
            filter: CollisionFilter(group: GameCollision.scenery, mask: .all)
        ))
        host.components.set(PhysicsBodyComponent(
            shapes: [.generateSphere(radius: r)], mass: 2,
            material: .generate(staticFriction: 0.6, dynamicFriction: 0.5, restitution: 0.3),
            mode: .dynamic
        ))

        let mat = ghostMaterial
        func lobe(_ radius: Float, _ pos: SIMD3<Float>) {
            let e = ModelEntity(mesh: .generateSphere(radius: radius), materials: [mat])
            e.position = pos
            host.addChild(e)
        }

        // Head lobe always present.
        lobe(r, [0, 0, 0])

        // Shape-specific body lobes + a wavy bottom of shrinking "tail" bubbles.
        switch shape {
        case .blob:
            lobe(r * 0.85, [0, -r * 0.7, 0])
            tail(host, count: 3, top: r * 0.55, y0: -r * 1.1, mat: mat)
        case .tall:
            lobe(r * 0.95, [0, -r * 0.9, 0])
            lobe(r * 0.75, [0, -r * 1.7, 0])
            tail(host, count: 3, top: r * 0.5, y0: -r * 2.1, mat: mat)
        case .wisp:
            lobe(r * 0.6, [0, -r * 0.6, 0])
            tail(host, count: 5, top: r * 0.5, y0: -r * 0.9, mat: mat)
        case .chubby:
            lobe(r * 0.7, [ r * 0.7, -r * 0.2, 0])
            lobe(r * 0.7, [-r * 0.7, -r * 0.2, 0])
            tail(host, count: 4, top: r * 0.6, y0: -r * 0.9, mat: mat)
        case .tiny:
            tail(host, count: 2, top: r * 0.5, y0: -r * 0.8, mat: mat)
        }

        addEyes(to: host, r: r)
        return host
    }

    /// A descending row of shrinking, side-to-side bubbles — the classic wavy ghost hem.
    private static func tail(_ host: Entity, count: Int, top: Float, y0: Float,
                             mat: RealityKit.Material) {
        for j in 0..<count {
            let f = Float(j)
            let rad = top * (1 - f / Float(count + 1))
            let x = (j % 2 == 0 ? 1 : -1) * top * 0.7 * (f / Float(max(count, 1)))
            let e = ModelEntity(mesh: .generateSphere(radius: max(rad, 0.01)), materials: [mat])
            e.position = [x, y0 - f * top * 0.7, 0]
            host.addChild(e)
        }
    }

    private static func addEyes(to host: Entity, r: Float) {
        let eyeMat = SimpleMaterial(color: .black, roughness: 0.05, isMetallic: false)
        let glintMat = SimpleMaterial(color: .white, roughness: 0.0, isMetallic: false)
        for side in [Float(-1), 1] {
            let eye = ModelEntity(mesh: .generateSphere(radius: r * 0.26), materials: [eyeMat])
            eye.position = [side * r * 0.42, r * 0.2, r * 0.82]
            let glint = ModelEntity(mesh: .generateSphere(radius: r * 0.09), materials: [glintMat])
            glint.position = [r * 0.1, r * 0.1, r * 0.18]
            eye.addChild(glint)
            host.addChild(eye)
        }
    }
}

// MARK: Pop system

/// Pops critters the wrecking ball reaches and tells the game model to score them. Logic
/// lives in `step` so headless tests can drive it with a scripted ball position.
struct CritterPopSystem: System {

    /// Set once by the game model; receives +1 per critter popped (on the main actor).
    @MainActor static var onPop: (() -> Void)?

    /// Weak reference to the scene root entity so temporary effect entities can be added as children.
    @MainActor static weak var rootEntity: Entity?

    init(scene: RealityKit.Scene) {}

    private static let critterQuery = EntityQuery(where: .has(AlienCritterComponent.self))
    private static let ballQuery = EntityQuery(where: .has(WreckingBallComponent.self))

    func update(context: SceneUpdateContext) {
        let critters = context.scene.performQuery(Self.critterQuery).map { $0 }
        let ball = context.scene.performQuery(Self.ballQuery).map { $0 }.first
        Self.step(critters: critters[...], ball: ball, dt: Float(context.deltaTime))
    }

    @MainActor
    static func step(critters: ArraySlice<Entity>, ball: Entity?, dt: Float) {
        let ballPos = ball?.position(relativeTo: nil)
        let ballRadius: Float = 0.6
        for critter in critters {
            guard var c = critter.components[AlienCritterComponent.self] else { continue }
            if c.popped {
                c.popTimer -= dt
                let s = max(c.popTimer / 0.25, 0.001)
                critter.scale = SIMD3<Float>(repeating: s)
                critter.components.set(c)
                if c.popTimer <= 0 { critter.removeFromParent() }
                continue
            }
            guard let ballPos else { continue }
            if distance(critter.position(relativeTo: nil), ballPos) <= ballRadius + c.radius + 0.05 {
                let pos = critter.position(relativeTo: nil)
                c.popped = true
                c.popTimer = 0.25
                critter.components.set(c)
                critter.components.remove(PhysicsBodyComponent.self)
                critter.components.remove(CollisionComponent.self)
                spawnPoof(at: pos)
                spawnScoreText(at: pos)
                playPopSound(at: pos)
                onPop?()
            }
        }
    }

    // MARK: Pop VFX

    @MainActor
    private static var popSound: AudioFileResource? = {
        guard let url = Bundle.main.url(forResource: "pop", withExtension: "wav") else { return nil }
        return try? AudioFileResource.load(contentsOf: url)
    }()

    @MainActor
    private static func spawnPoof(at position: SIMD3<Float>) {
        guard let root = rootEntity else { return }
        let smoke = Entity()
        smoke.position = position
        smoke.name = "poof_smoke"

        var particles = ParticleEmitterComponent()
        particles.emitterShape = .sphere
        particles.emitterShapeSize = [0.05, 0.05, 0.05]
        particles.speed = 0.25
        particles.speedVariation = 0.12
        particles.emissionDirection = [0, 1, 0]
        particles.mainEmitter.birthRate = 500
        particles.mainEmitter.lifeSpan = 0.6
        particles.mainEmitter.lifeSpanVariation = 0.2
        particles.mainEmitter.size = 0.06
        particles.mainEmitter.sizeVariation = 0.04
        particles.mainEmitter.sizeMultiplierAtEndOfLifespan = 2.0
        particles.mainEmitter.opacityCurve = .linearFadeOut
        particles.mainEmitter.blendMode = .alpha
        particles.mainEmitter.color = .evolving(
            start: .single(UIColor(red: 0.20, green: 1.0, blue: 0.45, alpha: 0.9)),
            end: .single(UIColor(red: 0.0, green: 0.4, blue: 0.1, alpha: 0.0))
        )
        particles.timing = .once(warmUp: 0, emit: .init(duration: 0.3, variation: 0.1))

        smoke.components.set(particles)
        root.addChild(smoke)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.0))
            smoke.removeFromParent()
        }
    }

    @MainActor
    private static func spawnScoreText(at position: SIMD3<Float>) {
        guard let root = rootEntity else { return }

        let textMesh = MeshResource.generateText(
            "+1000",
            extrusionDepth: 0.015,
            font: .systemFont(ofSize: 0.08),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byWordWrapping
        )

        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: UIColor(red: 0.3, green: 1.0, blue: 0.5, alpha: 1))
        mat.emissiveColor = .init(color: UIColor(red: 0.2, green: 1.0, blue: 0.4, alpha: 0.8))
        mat.emissiveIntensity = 2.0
        mat.blending = .transparent(opacity: 1.0)

        let textEntity = ModelEntity(mesh: textMesh, materials: [mat])
        textEntity.position = position + [0, 0.25, 0]
        textEntity.name = "score_text"

        root.addChild(textEntity)

        let up = position + [0, 0.9, 0]
        textEntity.move(to: Transform(translation: up), relativeTo: nil, duration: 1.2, timingFunction: .easeOut)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            textEntity.removeFromParent()
        }
    }

    @MainActor
    private static func playPopSound(at position: SIMD3<Float>) {
        guard let root = rootEntity, let sound = popSound else { return }
        let audioEntity = Entity()
        audioEntity.position = position
        root.addChild(audioEntity)
        let controller = audioEntity.prepareAudio(sound)
        controller.play()

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            audioEntity.removeFromParent()
        }
    }
}
