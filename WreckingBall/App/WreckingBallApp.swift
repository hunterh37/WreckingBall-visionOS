import SwiftUI
import RealityKit

@main
struct WreckingBallApp: App {

    @State private var viewModel = GameViewModel()
    @State private var immersionStyle: ImmersionStyle = .mixed

    init() {
        CraneAnchorComponent.registerComponent()
        CraneJibComponent.registerComponent()
        CraneTrolleyComponent.registerComponent()
        WreckingBallComponent.registerComponent()
        ChainLinkComponent.registerComponent()
        TowerBlockComponent.registerComponent()
        CraneControlSystem.registerSystem()
    }

    var body: some SwiftUI.Scene {
        WindowGroup(id: "controls") {
            ControlPanelView(viewModel: viewModel)
        }
        .windowStyle(.plain)
        .defaultSize(width: 420, height: 340)

        ImmersiveSpace(id: "demolitionYard") {
            ImmersiveView(viewModel: viewModel)
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
        .immersiveEnvironmentBehavior(.coexist)
    }
}
