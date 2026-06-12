# WreckingBall

A visionOS demolition game: a **giant tower crane** looms in front of you with a wrecking
ball hanging from a real physics joint chain. Move your **right hand** to drive the crane —
the hook chases your hand with ~9× amplification, the jib slews, and the ball swings with
full RealityKit physics into towers of cubes (and barrels). UI buttons respawn towers,
reset the ball, and set tower count/height presets.

## Architecture

Follows the [ImmersiveTesting](../ImmersiveTesting) layered architecture so the whole game
is testable headlessly:

- **`App/`** — thin SwiftUI shell. `ImmersiveView` adds the prebuilt graph to a
  `RealityView` and wires the joints; `ControlPanelView` is the window with the buttons.
- **`Game/`** — `WreckingBallSceneBuilder` is a pure `(Config, SceneEnvironment) → Entity`;
  `CraneControlSystem` keeps its logic in a static `step(entities:dt:env:)` per the blessed
  pattern; `GameViewModel` drives respawn/reset transitions on the root.
- **`Services/`** — `SpatialTrackingService` is the only type that imports ARKit. It runs
  one `ARKitSession` (hand + world tracking) and conforms to the package's
  `HandTrackingProviding` / `WorldTrackingProviding` provider protocols.

Tests in `WreckingBallTests/` build the real graph with `SeededRandom` and drive the real
crane logic with `ScriptedHands` through `SystemHarness` — no headset needed.

## Physics

- Hook anchor: kinematic body moved by the control system (hand input becomes momentum).
- Chain: 6 dynamic links pinned end-to-end with `PhysicsSphericalJoint`; the links collide
  with nothing so only the ball does damage.
- Ball: 1200 kg, low restitution; blocks: 18 kg with high friction so stacks settle.
- Joints are wired in `connectJoints` from the `RealityView` make closure (they need a
  live scene), which is why graph construction is two-phase.

## Build / test

```sh
xcodegen generate
xcodebuild -scheme WreckingBall -destination 'platform=visionOS Simulator,name=Apple Vision Pro' test
```
