import RealityKit
import UIKit
import simd
import ImmersiveTestingRuntime

// MARK: - StructureBuilder
//
// Procedural destructible architecture for the demolition yard. Everything is assembled
// from primitive boxes tagged `TowerBlockComponent` (so the existing physics + collision
// pipeline treats them as rubble), grouped into recognisable forms — suburban houses,
// mid-rise blocks, and skyscrapers — and laid out into little neighbourhoods that ring the
// ball's swing. Placement draws from the injected RNG, so a seeded env reproduces a city.

@MainActor
enum StructureBuilder {

    /// What kind of neighbourhood to stand up. Picked in the control panel.
    enum Cityscape: String, CaseIterable, Identifiable, Sendable {
        case suburb        // low pitched-roof houses
        case neighborhood  // mixed houses + a few mid-rises
        case downtown      // tall skyscrapers
        var id: String { rawValue }
        var label: String {
            switch self {
            case .suburb:       return "Suburb"
            case .neighborhood: return "Neighborhood"
            case .downtown:     return "Downtown"
            }
        }
    }

    private enum Kind { case house, midRise, skyscraper }

    /// Per-building blueprint the layout step turns into blocks.
    private struct Spec {
        var kind: Kind
        var cols: Int          // footprint width in blocks (X)
        var depth: Int         // footprint depth in blocks (Z)
        var floors: Int        // stories tall
        var hue: CGFloat       // base wall hue
    }

    // MARK: Layout

    /// Builds the whole destructible city for a round and returns its root ("structures").
    static func makeCity(style: Cityscape,
                         config: WreckingBallSceneBuilder.Config,
                         env: any SceneEnvironment) -> Entity {
        let root = Entity()
        root.name = "structures"

        let pivot = WreckingBallSceneBuilder.swingPivotXZ(config)
        let reach = WreckingBallSceneBuilder.pendulumLength(config)
        let count = buildingCount(for: style)

        for i in 0..<count {
            let angle = (Float(i) / Float(count)) * 2 * .pi + env.random.next(in: -0.35...0.35)
            let radius = reach * env.random.next(in: 0.5...0.95)
            let center = SIMD3<Float>(pivot.x + cos(angle) * radius, 0, pivot.y + sin(angle) * radius)
            let spec = spec(for: style, env: env)
            // Face the building toward the swing pivot so rows of windows read from the player.
            let yaw = atan2(pivot.x - center.x, pivot.y - center.z)
            let building = makeBuilding(spec, config: config, env: env)
            building.name = "building_\(i)"
            building.position = center
            building.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            root.addChild(building)
        }
        return root
    }

    private static func buildingCount(for style: Cityscape) -> Int {
        switch style {
        case .suburb:       return 6
        case .neighborhood: return 5
        case .downtown:     return 4
        }
    }

    private static func spec(for style: Cityscape, env: any SceneEnvironment) -> Spec {
        func r(_ lo: Float, _ hi: Float) -> Int { Int(env.random.next(in: lo...hi).rounded()) }
        let hue = CGFloat(env.random.next(in: 0...1))
        switch style {
        case .suburb:
            return Spec(kind: .house, cols: r(2, 3), depth: r(2, 3), floors: r(1, 2), hue: hue)
        case .neighborhood:
            // Mostly houses, occasionally a mid-rise to break the skyline.
            if env.random.next() < 0.35 {
                return Spec(kind: .midRise, cols: r(2, 3), depth: r(2, 3), floors: r(3, 6), hue: hue)
            }
            return Spec(kind: .house, cols: r(2, 3), depth: r(2, 3), floors: r(1, 2), hue: hue)
        case .downtown:
            return Spec(kind: .skyscraper, cols: r(2, 3), depth: r(2, 3), floors: r(7, 12), hue: hue)
        }
    }

    // MARK: Building assembly

    private static func makeBuilding(_ spec: Spec,
                                     config: WreckingBallSceneBuilder.Config,
                                     env: any SceneEnvironment) -> Entity {
        let s = config.blockSize
        let building = Entity()
        let footX = Float(spec.cols) * s
        let footZ = Float(spec.depth) * s

        let wall = wallColor(spec)
        let window = UIColor(red: 0.55, green: 0.75, blue: 0.95, alpha: 1)

        for floor in 0..<spec.floors {
            for cx in 0..<spec.cols {
                for cz in 0..<spec.depth {
                    // Hollow upper floors: only the perimeter is walls (interiors are rooms),
                    // so towers read as buildings and collapse more dramatically. Ground floor
                    // stays solid for a stable base.
                    let perimeter = cx == 0 || cz == 0 || cx == spec.cols - 1 || cz == spec.depth - 1
                    if floor > 0 && !perimeter { continue }

                    // Every other block on the facade is a "window".
                    let isWindow = (floor + cx + cz) % 2 == 0 && floor > 0
                    let block = makeBlock(size: s,
                                          mass: config.blockMass,
                                          color: isWindow ? window : wall)
                    block.position = SIMD3<Float>(
                        (Float(cx) + 0.5) * s - footX / 2,
                        (Float(floor) + 0.5) * s,
                        (Float(cz) + 0.5) * s - footZ / 2
                    )
                    building.addChild(block)
                }
            }
        }

        if spec.kind == .house {
            addRoof(to: building, spec: spec, config: config)
        } else {
            addRooftop(to: building, spec: spec, config: config, env: env)
        }
        return building
    }

    /// Pitched roof for houses: stacked, shrinking slabs that taper to a ridge.
    private static func addRoof(to building: Entity,
                                spec: Spec,
                                config: WreckingBallSceneBuilder.Config) {
        let s = config.blockSize
        let roofColor = UIColor(red: 0.5, green: 0.18, blue: 0.14, alpha: 1) // terracotta
        let baseY = Float(spec.floors) * s
        let layers = spec.depth
        for layer in 0..<layers {
            let inset = Float(layer) * (s / 2)
            let width = Float(spec.cols) * s
            let depth = Float(spec.depth) * s - Float(layer) * s
            if depth <= 0 { break }
            let slab = ModelEntity(
                mesh: .generateBox(width: width, height: s * 0.5, depth: depth, cornerRadius: 0.01),
                materials: [SimpleMaterial(color: roofColor, isMetallic: false)]
            )
            slab.name = "roof"
            slab.components.set(TowerBlockComponent())
            slab.position = [0, baseY + Float(layer) * s * 0.5 + s * 0.25, 0]
            _ = inset
            attachPhysics(to: slab, size: [width, s * 0.5, depth], mass: config.blockMass * 0.6)
            building.addChild(slab)
        }
    }

    /// Flat roof + a little rooftop clutter (water tank / AC box) for taller buildings.
    private static func addRooftop(to building: Entity,
                                   spec: Spec,
                                   config: WreckingBallSceneBuilder.Config,
                                   env: any SceneEnvironment) {
        let s = config.blockSize
        let footX = Float(spec.cols) * s
        let footZ = Float(spec.depth) * s
        let baseY = Float(spec.floors) * s
        let cap = ModelEntity(
            mesh: .generateBox(width: footX, height: s * 0.3, depth: footZ),
            materials: [SimpleMaterial(color: UIColor(white: 0.4, alpha: 1), isMetallic: false)]
        )
        cap.name = "rooftop"
        cap.components.set(TowerBlockComponent())
        cap.position = [0, baseY + s * 0.15, 0]
        attachPhysics(to: cap, size: [footX, s * 0.3, footZ], mass: config.blockMass * 0.5)
        building.addChild(cap)

        let tank = makeBlock(size: s * 0.6, mass: config.blockMass * 0.4,
                             color: UIColor(white: 0.55, alpha: 1))
        tank.position = [env.random.next(in: -footX/4...footX/4),
                         baseY + s * 0.45,
                         env.random.next(in: -footZ/4...footZ/4)]
        building.addChild(tank)
    }

    // MARK: Blocks

    private static func wallColor(_ spec: Spec) -> UIColor {
        switch spec.kind {
        case .house:
            return UIColor(hue: spec.hue, saturation: 0.35, brightness: 0.85, alpha: 1)
        case .midRise:
            return UIColor(hue: spec.hue, saturation: 0.2, brightness: 0.7, alpha: 1)
        case .skyscraper:
            return UIColor(hue: 0.58, saturation: 0.12, brightness: 0.6, alpha: 1) // glass-grey
        }
    }

    /// A single destructible cube, wired exactly like the original tower blocks.
    static func makeBlock(size s: Float, mass: Float, color: UIColor) -> ModelEntity {
        let block = ModelEntity(
            mesh: .generateBox(size: s * 0.98, cornerRadius: 0.012),
            materials: [SimpleMaterial(color: color, isMetallic: false)]
        )
        block.components.set(TowerBlockComponent())
        attachPhysics(to: block, size: [s, s, s], mass: mass)
        return block
    }

    private static func attachPhysics(to block: ModelEntity, size: SIMD3<Float>, mass: Float) {
        block.components.set(CollisionComponent(
            shapes: [.generateBox(size: size)],
            filter: CollisionFilter(group: GameCollision.scenery, mask: .all)
        ))
        var body = PhysicsBodyComponent(
            shapes: [.generateBox(size: size)],
            mass: mass,
            material: .generate(staticFriction: 0.8, dynamicFriction: 0.7, restitution: 0.05),
            mode: .dynamic
        )
        body.linearDamping = 0.05
        body.angularDamping = 0.2
        block.components.set(body)
        block.components.set(PhysicsMotionComponent())
    }
}
