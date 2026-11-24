import SwiftUI

struct HomeView: View {
    @ObservedObject private var session = SessionController.shared
    @State private var showSettings = false

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 24) {
                // Left: identity + entry
                VStack(alignment: .leading, spacing: 12) {
                    Text("iios")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("Quest-like XR runtime for iPhone")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    if !session.deviceSupported {
                        Label("ARKit world tracking unavailable on this device",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    Spacer()

                    Button {
                        session.enterVR()
                    } label: {
                        Label("Enter VR", systemImage: "visionpro")
                            .font(.title2.bold())
                            .frame(maxWidth: 260)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!session.deviceSupported)

                    Text("Strap the phone into VR goggles (landscape, camera out).\nBoth triggers (pinch both hands) opens the menu.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity, alignment: .top)

                Spacer()

                // Right: quick glance panel
                VStack(alignment: .leading, spacing: 10) {
                    panelRow(icon: "hand.raised", title: "Hands = controllers",
                             detail: "Pinch index = trigger · curl fingers = grip · pinch thumb+middle = A")
                    panelRow(icon: "camera", title: "Passthrough",
                             detail: "Monoscopic rear-camera video background")
                    panelRow(icon: "waveform.path", title: "Tracking",
                             detail: "ARKit 6DoF SLAM · Vision 21-joint hand pose")
                    Button("Settings & Calibration") {
                        showSettings = true
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 6)
                }
                .frame(width: min(geo.size.width * 0.42, 420))
            }
            .padding(28)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private func panelRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 30)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
