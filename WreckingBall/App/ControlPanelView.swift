import SwiftUI

/// Launch window + in-game controls: open the yard, respawn towers, reset the ball.
struct ControlPanelView: View {
    @Bindable var viewModel: GameViewModel

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var yardIsOpen = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Wrecking Ball")
                .font(.extraLargeTitle2)
            Text("Move your right hand to swing the crane. Knock the towers down.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(yardIsOpen ? "Leave the Yard" : "Enter the Yard") {
                Task {
                    if yardIsOpen {
                        await dismissImmersiveSpace()
                        yardIsOpen = false
                    } else if case .opened = await openImmersiveSpace(id: "demolitionYard") {
                        yardIsOpen = true
                    }
                }
            }
            .font(.title3)

            if yardIsOpen {
                Divider()

                HStack(spacing: 16) {
                    Stepper("Towers: \(viewModel.towerCount)", value: $viewModel.towerCount, in: 1...6)
                    Stepper("Height: \(viewModel.towerHeight)", value: $viewModel.towerHeight, in: 3...14)
                }
                .fixedSize()

                HStack(spacing: 16) {
                    Button {
                        viewModel.respawnTowers()
                    } label: {
                        Label("Respawn Towers", systemImage: "building.2")
                    }
                    Button {
                        viewModel.resetBall()
                    } label: {
                        Label("Reset Ball", systemImage: "arrow.counterclockwise.circle")
                    }
                }

                #if targetEnvironment(simulator)
                Divider()
                MockHandControls(hands: viewModel.mockHands)
                #endif
            }
        }
        .padding(32)
        .glassBackgroundEffect()
    }
}

#if targetEnvironment(simulator)
/// Simulator-only panel: an XY joystick + height/pinch controls bound to the mock hand
/// that stands in for the absent simulator hand tracking.
private struct MockHandControls: View {
    @Bindable var hands: MockHandTracking

    var body: some View {
        VStack(spacing: 12) {
            Text("Simulator — drag to swing the crane")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                JoystickPad(value: $hands.joystick)
                VStack(spacing: 8) {
                    Text("Height")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(value: $hands.elevation, in: -1...1)
                        .frame(width: 140)
                    Toggle("Pinch", isOn: $hands.isPinching)
                        .fixedSize()
                }
            }
        }
    }
}

/// A simple square joystick: drag a knob to set a normalized −1...1 XY vector that drives
/// the mock hand pointer. Releasing snaps it back to centre.
private struct JoystickPad: View {
    @Binding var value: SIMD2<Float>

    private let size: CGFloat = 140
    private var radius: CGFloat { size / 2 }

    var body: some View {
        ZStack {
            Circle()
                .fill(.thinMaterial)
                .overlay(Circle().stroke(.secondary.opacity(0.4), lineWidth: 1))
            Circle()
                .fill(.tint)
                .frame(width: 44, height: 44)
                .offset(x: CGFloat(value.x) * radius, y: CGFloat(value.y) * radius)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture()
                .onChanged { g in
                    var v = SIMD2<Float>(
                        Float((g.location.x - radius) / radius),
                        Float((g.location.y - radius) / radius)
                    )
                    let len = sqrt(v.x * v.x + v.y * v.y)   // clamp to the unit circle
                    if len > 1 { v /= len }
                    value = v
                }
                .onEnded { _ in value = .zero }
        )
    }
}
#endif
