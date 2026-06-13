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
    private let sceneReconstruction = SceneReconstructionProvider()

    /// Container for the scene-understanding collision mesh. Parent this under the physics
    /// root (it carries `PhysicsSimulationComponent`) so the wrecking ball and rubble cubes
    /// collide with real-world walls and furniture. One static child per `MeshAnchor`.
    /// Off by default: the world-mesh bodies exist but are disabled, so demolition physics
    /// ignores real walls until the player flips the toggle. Disabling the container disables
    /// the collision/physics components on every mesh child it holds.
    let sceneMeshRoot: Entity = {
        let e = Entity()
        e.name = "sceneUnderstandingMesh"
        e.isEnabled = false
        return e
    }()

    /// Entities keyed by the anchor that produced them, so updates replace and removals prune.
    private var meshEntities: [UUID: ModelEntity] = [:]

    // Latest poses, refreshed by the update streams.
    private var rightIndexTip = Transform(translation: [0.25, 1.05, -0.45])
    private(set) var rightPinchDistance: Float = 1
    private(set) var leftPinchDistance: Float = 1

    // MARK: Session

    /// Starts tracking and consumes hand + scene-reconstruction updates until cancelled.
    /// Call from a `.task` attached to the immersive view.
    func run() async {
        guard HandTrackingProvider.isSupported else { return }   // simulator: keep fakes-ish defaults

        var providers: [any DataProvider] = [handProvider, worldProvider]
        let meshingSupported = SceneReconstructionProvider.isSupported
        if meshingSupported { providers.append(sceneReconstruction) }

        do {
            try await session.run(providers)
        } catch {
            print("SpatialTrackingService failed to start: \(error)")
            return
        }

        // Consume both anchor streams concurrently for the life of the session.
        async let hands: Void = consumeHandUpdates()
        async let mesh: Void = consumeMeshUpdates(enabled: meshingSupported)
        _ = await (hands, mesh)
    }

    private func consumeHandUpdates() async {
        for await update in handProvider.anchorUpdates {
            guard update.event == .updated || update.event == .added else { continue }
            ingest(update.anchor)
        }
    }

    private func consumeMeshUpdates(enabled: Bool) async {
        guard enabled else { return }
        for await update in sceneReconstruction.anchorUpdates {
            await ingest(meshUpdate: update)
        }
    }

    // MARK: Scene reconstruction → collision mesh

    /// Turns a `MeshAnchor` update into a static collision/physics body so demolition
    /// physics treats real walls and furniture as solid scenery.
    private func ingest(meshUpdate update: AnchorUpdate<MeshAnchor>) async {
        let anchor = update.anchor
        switch update.event {
        case .added, .updated:
            guard let shape = try? await ShapeResource.generateStaticMesh(from: anchor) else { return }
            let entity = meshEntities[anchor.id] ?? {
                let e = ModelEntity()
                e.name = "worldMesh_\(anchor.id.uuidString)"
                meshEntities[anchor.id] = e
                sceneMeshRoot.addChild(e)
                return e
            }()
            entity.transform = Transform(matrix: anchor.originFromAnchorTransform)
            entity.components.set(CollisionComponent(
                shapes: [shape],
                isStatic: true,
                filter: CollisionFilter(group: GameCollision.scenery, mask: .all)
            ))
            entity.components.set(PhysicsBodyComponent(
                shapes: [shape],
                mass: 0,
                material: .generate(staticFriction: 0.9, dynamicFriction: 0.8, restitution: 0.05),
                mode: .static
            ))
        case .removed:
            meshEntities.removeValue(forKey: anchor.id)?.removeFromParent()
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
