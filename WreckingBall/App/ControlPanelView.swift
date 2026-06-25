import SwiftUI

/// Launch window + in-game controls: open the yard, respawn towers, reset the ball.
struct ControlPanelView: View {
    @Bindable var viewModel: GameViewModel

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var yardIsOpen = false

    private var timeString: String {
        String(format: "0:%02d", Int(viewModel.timeRemaining.rounded(.up)))
    }

    private var styleBinding: Binding<StructureBuilder.Cityscape?> {
        Binding(get: { viewModel.pinnedStyle }, set: { viewModel.pinnedStyle = $0 })
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Wrecking Ball")
                .font(.extraLargeTitle2)
            Text(viewModel.controlMode == .joystick
                 ? "Grab the joystick rig to swing the crane. Knock the towers down."
                 : "Move your right hand to swing the crane. Knock the towers down.")
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

                Text(viewModel.cityStyle.label.uppercased())
                    .font(.caption).tracking(2).foregroundStyle(.secondary)

                HStack(spacing: 28) {
                    VStack {
                        Text(timeString).font(.largeTitle).bold().monospacedDigit()
                            .foregroundStyle(viewModel.timeRemaining <= 5 ? .red : .primary)
                        Text("Time").font(.caption2).foregroundStyle(.secondary)
                    }
                    VStack {
                        Text("\(viewModel.score)").font(.largeTitle).bold().monospacedDigit()
                        Text("Score").font(.caption2).foregroundStyle(.secondary)
                    }
                    VStack {
                        Text("\(viewModel.crittersRemaining)").font(.largeTitle).bold().monospacedDigit()
                        Text("Aliens").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                if viewModel.roundOver {
                    Text("Time! Demolished \(viewModel.score) 🧨")
                        .font(.headline)
                }

                Button {
                    viewModel.startRound()
                } label: {
                    Label(viewModel.isRoundActive ? "Restart Round" : "New Round (30s)",
                          systemImage: "arrow.clockwise")
                }
                .font(.title3)

                Picker("Neighborhood", selection: styleBinding) {
                    Text("Random").tag(StructureBuilder.Cityscape?.none)
                    ForEach(StructureBuilder.Cityscape.allCases) { style in
                        Text(style.label).tag(StructureBuilder.Cityscape?.some(style))
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Divider()

                Picker("Control", selection: $viewModel.controlMode) {
                    ForEach(CraneControlMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Button {
                    viewModel.resetBall()
                } label: {
                    Label("Reset Ball", systemImage: "arrow.counterclockwise.circle")
                }

                Toggle(isOn: $viewModel.sceneCollisionsEnabled) {
                    Label("Collide with Room", systemImage: "cube.transparent")
                }
                .fixedSize()

                #if targetEnvironment(simulator)
                if viewModel.controlMode == .handTracking {
                    Divider()
                    MockHandControls(hands: viewModel.mockHands)
                } else {
                    Divider()
                    Text("Joystick mode — drag a stick head on the rig in the yard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
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
