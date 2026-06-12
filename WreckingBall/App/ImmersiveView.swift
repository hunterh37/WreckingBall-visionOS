import SwiftUI
import RealityKit

/// Thin shell: adds the prebuilt graph to the RealityView, wires the physics joints once
/// the graph is in a live scene, and runs hand tracking for the session. No game logic.
struct ImmersiveView: View {
    let viewModel: GameViewModel

    var body: some View {
        RealityView { content in
            content.add(viewModel.root)
            do {
                try WreckingBallSceneBuilder.connectJoints(root: viewModel.root, config: viewModel.config)
            } catch {
                print("Failed to connect wrecking-ball joints: \(error)")
            }
        }
        .task {
            await viewModel.startTracking()
        }
    }
}
