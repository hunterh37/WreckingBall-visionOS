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

    @State private var showSettings = false

    private func toggleYard() {
        Task {
            if yardIsOpen {
                await dismissImmersiveSpace()
                yardIsOpen = false
            } else if case .opened = await openImmersiveSpace(id: "demolitionYard") {
                yardIsOpen = true
            }
        }
    }

    var body: some View {
        Group {
            if yardIsOpen {
                inGamePanel
            } else {
                mainMenu
            }
        }
        .animation(.snappy(duration: 0.35), value: yardIsOpen)
        .animation(.snappy(duration: 0.3), value: showSettings)
    }

    // MARK: - Main Menu (visionOS game-style)

    private var mainMenu: some View {
        ZStack {
            MenuHaloBackground()

            VStack(spacing: 6) {
                Spacer(minLength: 8)

                Image("wreckingball")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 340, height: 340)
                    .shadow(color: .orange.opacity(0.45), radius: 38, y: 10)
                    .shadow(color: .black.opacity(0.5), radius: 22, y: 26)
                    .offset(z: 64)
                    .rotation3DEffect(.degrees(showSettings ? -4 : 0), axis: (0, 1, 0))

                VStack(spacing: 2) {
                    Text("WRECKING")
                        .font(.system(size: 56, weight: .heavy)).tracking(8)
                    Text("BALL")
                        .font(.system(size: 56, weight: .heavy))
                        .tracking(18)
                        .foregroundStyle(.orange)
                }
                .shadow(color: .black.opacity(0.6), radius: 8, y: 4)

                Text("DEMOLITION YARD")
                    .font(.caption).tracking(6).foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                if showSettings {
                    settingsCard
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    VStack(spacing: 16) {
                        FloatingMenuButton(title: "PLAY", systemImage: "play.fill", tint: .orange, prominent: true) {
                            toggleYard()
                        }
                        FloatingMenuButton(title: "SETTINGS", systemImage: "gearshape.fill", tint: .white) {
                            showSettings = true
                        }
                    }
                    .padding(.top, 8)
                    .transition(.opacity)
                }

                Spacer(minLength: 16)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
        }
        .frame(width: 560, height: 760)
    }

    private var settingsCard: some View {
        VStack(spacing: 18) {
            Text("SETTINGS").font(.headline).tracking(4).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("CONTROL SCHEME").font(.caption2).tracking(2).foregroundStyle(.secondary)
                Picker("Control", selection: $viewModel.controlMode) {
                    ForEach(CraneControlMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("NEIGHBORHOOD").font(.caption2).tracking(2).foregroundStyle(.secondary)
                Picker("Neighborhood", selection: styleBinding) {
                    Text("Random").tag(StructureBuilder.Cityscape?.none)
                    ForEach(StructureBuilder.Cityscape.allCases) { style in
                        Text(style.label).tag(StructureBuilder.Cityscape?.some(style))
                    }
                }
                .pickerStyle(.segmented)
            }

            Toggle(isOn: $viewModel.sceneCollisionsEnabled) {
                Label("Collide with Room", systemImage: "cube.transparent")
            }

            FloatingMenuButton(title: "BACK", systemImage: "chevron.left", tint: .white) {
                showSettings = false
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 420)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.5), lineWidth: 1.5))
        .offset(z: 32)
    }

    // MARK: - In-game panel

    private var inGamePanel: some View {
        VStack(spacing: 20) {
            Button(yardIsOpen ? "Leave the Yard" : "Enter the Yard") {
                toggleYard()
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

// MARK: - visionOS game-style menu chrome

/// A floating, glassy 3D button with a crisp white outline — visionOS game aesthetic.
private struct FloatingMenuButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .white
    var prominent: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .bold))
                Text(title)
                    .font(.system(size: 26, weight: .heavy)).tracking(3)
            }
            .foregroundStyle(prominent ? AnyShapeStyle(.black) : AnyShapeStyle(.white))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .padding(.horizontal, 36)
            .background {
                if prominent {
                    Capsule().fill(tint.gradient)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .overlay(Capsule().stroke(.white.opacity(prominent ? 0.85 : 0.6), lineWidth: 2))
            .shadow(color: tint.opacity(prominent ? 0.6 : 0.0), radius: hovering ? 30 : 18, y: 8)
            .shadow(color: .black.opacity(0.45), radius: 14, y: 12)
        }
        .buttonStyle(.plain)
        .frame(width: 360)
        .scaleEffect(hovering ? 1.05 : 1.0)
        .offset(z: hovering ? 28 : 12)
        .animation(.snappy(duration: 0.25), value: hovering)
        .onHover { hovering = $0 }
        .hoverEffect(.lift)
    }
}

/// Soft radial glow backdrop behind the menu hero.
private struct MenuHaloBackground: View {
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [.orange.opacity(0.35), .clear],
                center: .top, startRadius: 20, endRadius: 460
            )
            RadialGradient(
                colors: [.white.opacity(0.06), .clear],
                center: .center, startRadius: 40, endRadius: 520
            )
        }
        .allowsHitTesting(false)
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
