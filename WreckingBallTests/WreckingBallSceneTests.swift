import XCTest
import RealityKit
import simd
@testable import WreckingBall
import ImmersiveTesting

// Headless tests against the *real* production graph and the *real* crane logic, driven
// through scriptable fakes — no headset, no simulator physics required. (Joint wiring
// needs a live scene, so `connectJoints` is exercised on-device, not here.)

@MainActor
final class WreckingBallSceneTests: XCTestCase {

    private let builder = WreckingBallSceneBuilder()
    private var config: WreckingBallSceneBuilder.Config { .init() }

    // MARK: Graph construction

    func testSceneBuildsCraneChainAndBall() {
        let scene = builder.makeScene(config, env: .fake(random: SeededRandom(seed: 1)))

        XCTAssertNotNil(scene["ground"])
        XCTAssertNotNil(scene["mast"])
        XCTAssertNotNil(scene["jibPivot"])
        XCTAssertNotNil(scene["hookAnchor"])
        XCTAssertNotNil(scene["wreckingBall"])
        for i in 0..<config.chainLinkCount {
            XCTAssertNotNil(scene["chainLink_\(i)"], "missing chain link \(i)")
        }
    }

    func testTowersSpawnExpectedBlockCount() {
        let scene = builder.makeScene(config, env: .fake(random: SeededRandom(seed: 1)))
        let blocks = countEntities(in: scene.root) { $0.components[TowerBlockComponent.self] != nil }
        let perTower = config.towerBlockColumns * config.towerBlockColumns * config.towerBlockRows
        XCTAssertEqual(blocks, config.towerCount * perTower + 4)   // + 4 barrels
    }

    func testTowerPlacementIsDeterministicForSameSeed() {
        let a = builder.makeScene(config, env: .fake(random: SeededRandom(seed: 42)))
        let b = builder.makeScene(config, env: .fake(random: SeededRandom(seed: 42)))
        let pa = a["tower_0"]!.children.first!.position(relativeTo: nil)
        let pb = b["tower_0"]!.children.first!.position(relativeTo: nil)
        XCTAssertEqual(pa, pb)
    }

    func testBallHangsFullChainLengthBelowHook() {
        let scene = builder.makeScene(config, env: .fake())
        let anchor = scene["hookAnchor"]!.position(relativeTo: nil)
        let ball = scene["wreckingBall"]!.position(relativeTo: nil)
        let expectedDrop = Float(config.chainLinkCount) * config.chainLinkLength + config.ballRadius
        XCTAssertEqual(anchor.y - ball.y, expectedDrop, accuracy: 0.001)
        XCTAssertEqual(anchor.x, ball.x, accuracy: 0.001)
    }

    func testRespawnReplacesTowers() {
        let env: CompositeSceneEnvironment = .fake(random: SeededRandom(seed: 7))
        let scene = builder.makeScene(config, env: env)
        let original = scene["towers"]!
        var smaller = config
        smaller.towerCount = 1
        WreckingBallSceneBuilder.respawnTowers(in: scene.root, config: smaller, env: env)

        XCTAssertNil(original.parent, "old towers should be detached")
        let towers = scene["towers"]!
        XCTAssertEqual(towers.children.filter { $0.name.hasPrefix("tower_") }.count, 1)
    }

    // MARK: Crane control (scripted right hand)

    func testCraneSlewsFullCircle() {
        let hands = ScriptedHands()
        let env: CompositeSceneEnvironment = .fake(hands: hands)
        let scene = builder.makeScene(config, env: env)
        let anchor = scene["hookAnchor"]!
        let jib = scene["jibPivot"]!
        let cfg = anchor.components[CraneAnchorComponent.self]!

        // Swing the hand far enough left and right to drive the slew past ±90° — proving the
        // crane reaches all the way around, not just a forward cone.
        func settle(handX: Float) -> Float {
            hands.pointerTip = Transform(translation: cfg.neutralHandPosition + [handX, 0, 0])
            for _ in 0..<400 {
                CraneControlSystem.step(entities: [anchor, jib][...], dt: 1.0 / 90.0, env: env)
            }
            let hook = anchor.position(relativeTo: nil)
            return atan2(hook.x - cfg.mastXZ.x, hook.z - cfg.mastXZ.y)   // slew angle
        }

        // Full-range hand sweep saturates the ±π clamp on either side.
        XCTAssertEqual(settle(handX: 0.6), .pi, accuracy: 0.05)
        XCTAssertEqual(settle(handX: -0.6), -.pi, accuracy: 0.05)
        // A mid sweep lands well past the old ~60° limit (positive = jib swung to the right).
        XCTAssertGreaterThan(settle(handX: 0.2), Float.pi / 2)
    }

    func testCraneAnchorStaysInsideEnvelope() {
        let hands = ScriptedHands()
        let env: CompositeSceneEnvironment = .fake(hands: hands)
        let scene = builder.makeScene(config, env: env)
        let anchor = scene["hookAnchor"]!
        let cfg = anchor.components[CraneAnchorComponent.self]!

        // Fling the hand absurdly far — reach and height must clamp to their limits.
        hands.pointerTip = Transform(translation: [50, -30, 80])
        for _ in 0..<600 {
            CraneControlSystem.step(entities: [anchor][...], dt: 1.0 / 90.0, env: env)
        }
        let p = anchor.position(relativeTo: nil)
        let reach = length(SIMD2<Float>(p.x, p.z) - cfg.mastXZ)
        XCTAssertLessThanOrEqual(reach, cfg.maxRadius + 0.01)
        XCTAssertGreaterThanOrEqual(reach, cfg.minRadius - 0.01)
        XCTAssertTrue(p.y >= cfg.minHeight - 0.01 && p.y <= cfg.maxHeight + 0.01,
                      "hook height escaped envelope: \(p.y)")
    }

    func testJibSlewsTowardHook() {
        let hands = ScriptedHands()
        let env: CompositeSceneEnvironment = .fake(hands: hands)
        let scene = builder.makeScene(config, env: env)
        let anchor = scene["hookAnchor"]!
        let jib = scene["jibPivot"]!
        let cfg = anchor.components[CraneAnchorComponent.self]!

        hands.pointerTip = Transform(translation: cfg.neutralHandPosition + [0.4, 0, 0])
        for _ in 0..<300 {
            CraneControlSystem.step(entities: [anchor, jib][...], dt: 1.0 / 90.0, env: env)
        }

        // The jib's local +Z (arm direction) should point toward the hook's XZ offset.
        let armDir = jib.orientation(relativeTo: nil).act([0, 0, 1])
        let mastXZ = jib.components[CraneJibComponent.self]!.mastXZ
        let hook = anchor.position(relativeTo: nil)
        let toHook = normalize(SIMD2<Float>(hook.x, hook.z) - mastXZ)
        XCTAssertEqual(dot(normalize(SIMD2(armDir.x, armDir.z)), toHook), 1.0, accuracy: 0.01)
    }

    func testNoNaNTransformsAfterSimulatedSession() {
        let hands = ScriptedHands()
        let env: CompositeSceneEnvironment = .fake(hands: hands)
        let scene = builder.makeScene(config, env: env)
        let harness = SystemHarness(scene: scene, environment: env)
        harness.registerStep("crane") { entities, dt, env in
            CraneControlSystem.step(entities: entities[...], dt: dt, env: env)
        }
        // Wave the hand around for ~5 simulated seconds.
        for frame in 0..<450 {
            let t = Float(frame) / 90.0
            hands.pointerTip = Transform(translation: [sin(t * 2) * 0.4, 1.0 + cos(t) * 0.2, -0.5])
            harness.tick()
        }
        assertNoNaNTransforms(in: scene.root)
    }

    // MARK: Helpers

    private func countEntities(in root: Entity, where predicate: (Entity) -> Bool) -> Int {
        var count = predicate(root) ? 1 : 0
        for child in root.children { count += countEntities(in: child, where: predicate) }
        return count
    }

    private func assertNoNaNTransforms(in root: Entity, file: StaticString = #filePath, line: UInt = #line) {
        let p = root.position
        XCTAssertFalse(p.x.isNaN || p.y.isNaN || p.z.isNaN, "NaN transform on \(root.name)", file: file, line: line)
        for child in root.children { assertNoNaNTransforms(in: child, file: file, line: line) }
    }
}
