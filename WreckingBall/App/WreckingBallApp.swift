import SwiftUI
import RealityKit
import DicyaninVirtualJoystick

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
        AlienCritterComponent.registerComponent()
        CraneControlSystem.registerSystem()
        CritterPopSystem.registerSystem()

        // DicyaninVirtualJoystick rig: register its components + driving system so the
        // world-anchored joystick stand simulates each frame when that scheme is active.
        Gamepad3DJoystickComponent.registerComponent()
        Gamepad3DHeadComponent.registerComponent()
        Gamepad3DSystem.registerSystem()
    }

    var body: some SwiftUI.Scene {
        WindowGroup(id: "controls") {
            ControlPanelView(viewModel: viewModel)
        }
        .windowStyle(.plain)
        .defaultSize(width: 560, height: 760)

        ImmersiveSpace(id: "demolitionYard") {
            ImmersiveView(viewModel: viewModel)
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
        .immersiveEnvironmentBehavior(.coexist)
    }
}
