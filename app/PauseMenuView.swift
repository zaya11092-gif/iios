import SwiftUI

struct PauseMenuView: View {
    @ObservedObject private var session = SessionController.shared
    @ObservedObject private var s = XRSettings.shared

    var body: some View {
        VStack(spacing: 18) {
            Text("Paused")
                .font(.largeTitle.bold())

            VStack(alignment: .leading, spacing: 10) {
                sliderRow("Passthrough brightness", value: $s.ptBrightness, range: 0.2...1.5)
                sliderRow("Cube speed", value: $s.demoSpeed, range: 0.3...2.5)
                sliderRow("Spawn rate", value: $s.demoSpawnRate, range: 0.2...3.0)
                Toggle("Show hand joints", isOn: $s.showJoints)
            }
            .padding(16)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: 420)

            HStack(spacing: 16) {
                Button {
                    session.resume()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    XRHome.shared.backToHome()
                    session.resume()
                } label: {
                    Label("Home", systemImage: "house.fill")
                        .frame(minWidth: 110)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    XRHome.shared.startScan()
                    session.resume()
                } label: {
                    Label("Rescan", systemImage: "camera.metering.matrix")
                        .frame(minWidth: 110)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(role: .destructive) {
                    session.exitVR()
                } label: {
                    Label("Exit", systemImage: "xmark")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Text("Open this menu any time: pinch both index fingers and hold.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 22))
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}
