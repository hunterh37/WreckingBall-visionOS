import RealityKit
import simd
import ImmersiveTestingRuntime

// MARK: - CraneControlSystem
//
// Maps the player's right hand onto the giant crane each frame:
//   hand delta from a neutral rest pose → amplified, clamped hook-anchor target →
//   exponentially smoothed kinematic move. The jib then slews to face the hook and the
//   trolley rides out along the arm, so the whole crane visibly follows your hand while
//   the ball swings from real physics joints underneath.
//
// Per the ImmersiveTesting "blessed pattern", all logic lives in the static
// `step(entities:dt:env:)` so headless tests drive it with `ScriptedHands`; the `System`
// conformance is a thin delegate.

struct CraneControlSystem: System {

    /// Injected once at app start (tests bypass this and pass a fake env to `step`).
    @MainActor static var environment: (any SceneEnvironment)?

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        guard let env = Self.environment else { return }
        let entities = context.scene.performQuery(Self.query).map { $0 }
        Self.step(entities: entities[...], dt: Float(context.deltaTime), env: env)
    }

    private static let query = EntityQuery(where: .has(CraneAnchorComponent.self)
        || .has(CraneJibComponent.self))

    @MainActor
    static func step(entities: ArraySlice<Entity>, dt: Float, env: any SceneEnvironment) {
        guard let anchor = entities.first(where: { $0.components[CraneAnchorComponent.self] != nil }),
              let cfg = anchor.components[CraneAnchorComponent.self]
        else { return }

        // 1. Hand → target hook position, in polar coords around the mast so the crane can
        //    slew the full 360°: left/right hand = azimuth, forward/back = reach, up/down =
        //    height. (A box mapping could only ever cover a forward cone.)
        let hand = env.hands.pointerTipTransform().translation
        let handDelta = hand - cfg.neutralHandPosition
        let yaw = simd_clamp(handDelta.x * cfg.yawGain, -.pi, .pi)
        let radius = simd_clamp(cfg.neutralRadius - handDelta.z * cfg.radiusGain,
                                cfg.minRadius, cfg.maxRadius)
        let height = simd_clamp(cfg.neutralHeight + handDelta.y * cfg.heightGain,
                                cfg.minHeight, cfg.maxHeight)
        let target = SIMD3<Float>(cfg.mastXZ.x + sin(yaw) * radius,
                                  height,
                                  cfg.mastXZ.y + cos(yaw) * radius)

        // 2. Smooth, framerate-independent chase. The anchor is kinematic, so the joint
        //    chain converts this motion into real momentum on the ball.
        let alpha = 1 - exp(-cfg.smoothing * dt)
        let anchorWorld = anchor.position(relativeTo: nil)
        let next = mix(anchorWorld, target, t: SIMD3<Float>(repeating: alpha))
        anchor.setPosition(next, relativeTo: nil)

        // 3. Slew the jib to face the hook and ride the trolley out above it.
        guard let jib = entities.first(where: { $0.components[CraneJibComponent.self] != nil }),
              let jibCfg = jib.components[CraneJibComponent.self]
        else { return }

        let toHook = SIMD2<Float>(next.x, next.z) - jibCfg.mastXZ   // (Δx, Δz)
        let planarDistance = length(toHook)
        if planarDistance > 0.01 {
            // Local +Z is the arm direction; yawing by atan2(Δx, Δz) points it at the hook.
            let yaw = atan2(toHook.x, toHook.y)
            jib.setOrientation(simd_quatf(angle: yaw, axis: [0, 1, 0]), relativeTo: nil)
        }
        if let trolley = jib.children.first(where: { $0.components[CraneTrolleyComponent.self] != nil }),
           let tCfg = trolley.components[CraneTrolleyComponent.self] {
            let radius = simd_clamp(planarDistance, tCfg.minRadius, tCfg.maxRadius)
            trolley.position = [0, trolley.position.y, radius]
        }
    }
}
