import SwiftUI

// Quest Space Setup-style scan overlay: dark passthrough vignette, centered
// progress ring, "slowly look around" prompt, surface coverage readouts.
struct ScanOverlayView: View {
    @ObservedObject private var home = XRHome.shared
    @State private var counts = (horizontal: 0, vertical: 0)

    /// 0..1 — floor counts half, walls half (like Quest's surface coverage).
    private var progress: Double {
        let floor = counts.horizontal > 0 ? 0.5 : 0.0
        let walls = Double(min(counts.vertical, 2)) / 2.0 * 0.5
        return floor + walls
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2)) { _ in
            counts = XRCore.shared.planeCounts
            return ZStack {
                // dark vignette like Quest's scan mode
                LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.15), .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                VStack {
                    Text("Room Setup")
                        .font(.title2.bold())
                    Text("Slowly look around your space to map the floor and walls")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Spacer()

                    // progress ring
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.15), lineWidth: 10)
                            .frame(width: 110, height: 110)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(progress >= 1.0 ? Color.green : Color.blue, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .frame(width: 110, height: 110)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.3), value: progress)
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    Spacer()

                    HStack(spacing: 12) {
                        surfaceCard(icon: "square.bottomthird.fill",
                                    label: "Floor",
                                    found: counts.horizontal > 0)
                        surfaceCard(icon: "rect.split.3x1",
                                    label: "Walls",
                                    found: counts.vertical >= 2,
                                    value: "\(min(counts.vertical, 2))/2")
                    }

                    Button {
                        home.finishScan()
                    } label: {
                        Label(progress >= 1.0 ? "Done" : "Skip", systemImage: "checkmark")
                            .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
                }
                .padding(20)
            }
        }
    }

    private func surfaceCard(icon: String, label: String, found: Bool, value: String = "—") -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(found ? Color.green : Color.blue.opacity(0.7))
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.subheadline)
                Text(found ? "Mapped" : "Looking…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if value != "—" {
                Text(value)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}
