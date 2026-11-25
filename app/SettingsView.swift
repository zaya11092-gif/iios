import SwiftUI

// All calibration knobs are live — changes apply on the very next compositor
// frame. Tune with the debug joint overlay on until tracking looks right.
struct SettingsView: View {
    @ObservedObject private var s = XRSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Headset") {
                    sliderRow("IPD (mm)", value: $s.ipdMM, in: 50...75, format: "%.0f")
                    sliderRow("FOV (°)", value: $s.fovDeg, in: 60...100, format: "%.0f")
                }
                Section("Lens distortion") {
                    sliderRow("Barrel k1", value: $s.lensK1, in: -0.5...0.5, format: "%.3f")
                    sliderRow("Barrel k2", value: $s.lensK2, in: -0.2...0.2, format: "%.3f")
                    Toggle("Timewarp (rotational)", isOn: $s.timewarp)
                }
                Section("Passthrough") {
                    Toggle("Camera background", isOn: $s.passthrough)
                    sliderRow("Brightness", value: $s.ptBrightness, in: 0.2...1.5, format: "%.2f")
                    sliderRow("Zoom", value: $s.ptZoom, in: 1.0...1.5, format: "%.2f")
                    Toggle("Flip horizontal", isOn: $s.flipH)
                    Toggle("Flip vertical", isOn: $s.flipV)
                }
                Section("Hand tracking") {
                    Picker("Vision orientation", selection: $s.visionOrient) {
                        Text("up (0°)").tag(0)
                        Text("right (90° CW)").tag(1)
                        Text("down (180°)").tag(2)
                        Text("left (90° CCW)").tag(3)
                    }
                    sliderRow("Pinch threshold", value: $s.pinchThresh, in: 0.12...0.6, format: "%.2f")
                    sliderRow("Grip threshold", value: $s.gripThresh, in: 0.2...0.8, format: "%.2f")
                    sliderRow("Saber reach (m)", value: $s.reachMeters, in: 0.15...0.45, format: "%.2f")
                    Text("If the green joint dots are rotated or offset from your hands, change the Vision orientation first, then flips under Passthrough.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Debug") {
                    Toggle("Show hand joints on passthrough", isOn: $s.showJoints)
                    Toggle("Show stats HUD", isOn: $s.showStats)
                }
                Section("Launch options") {
                    Picker("Hand tracking rate", selection: $s.handHz) {
                        Text("30 Hz").tag(30)
                        Text("20 Hz").tag(20)
                        Text("15 Hz").tag(15)
                    }
                    sliderRow("Prediction (ms)", value: $s.predictionMs, in: 0...40, format: "%.1f")
                    sliderRow("Render scale", value: $s.renderScale, in: 0.6...1.0, format: "%.2f")
                }
                Section("Session log") {
                    NavigationLink("View session log") {
                        SessionLogView()
                    }
                }
                Section("Demo game") {
                    sliderRow("Cube speed", value: $s.demoSpeed, in: 0.3...2.5, format: "%.2f")
                    sliderRow("Spawn rate (per s)", value: $s.demoSpawnRate, in: 0.2...3.0, format: "%.2f")
                }
                Section("PC streaming (beta)") {
                    HStack {
                        Text("PC IP")
                        TextField("192.168.1.100", text: $s.pcIP)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.footnote, design: .monospaced))
                            .autocorrectionDisabled()
                            .keyboardType(.decimalPad)
                    }
                    Stepper(value: $s.pcPort, in: 1024...65535) {
                        HStack {
                            Text("Port")
                            Spacer()
                            Text("\(s.pcPort)")
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Run the pc-bridge companion on your gaming PC (see docs/STREAMING.md), then use the PC Stream panel in VR. Full ALVR/SteamVR integration lands in the next iteration.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Room") {
                    Button(role: .destructive) {
                        XRCore.shared.clearRoomMap()
                    } label: {
                        Text("Forget saved room scan")
                    }
                }
                Section("Windows layer (Phase 3, experimental)") {
                    HStack {
                        Text("Game path")
                        TextField("C:\\...\\game.exe", text: $s.winExePath)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.caption2, design: .monospaced))
                            .autocorrectionDisabled()
                    }
                    HStack {
                        Text("Layer status")
                        Spacer()
                        Text(WindowsHost.shared.status.label)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text("The FEX + Wine + DXMT layer is built separately (windows/build-layer.sh, or the windows-layer CI workflow) and embedded in the app. Until then the Windows button reports 'no layer'. See docs/ONDEVICE-STEAM.md.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}
