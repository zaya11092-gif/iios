import SwiftUI

// First-launch room scan overlay (Quest Space Setup equivalent). The user
// holds the phone in hand, pans slowly; ARKit plane detection draws floors
// and walls through the passthrough. Auto-completes when floor + 2 walls are
// held for a moment, or finishes manually with the button.
struct ScanOverlayView: View {
    @ObservedObject private var home = XRHome.shared
    @State private var counts = (horizontal: 0, vertical: 0)

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25)) { _ in
            counts = XRCore.shared.planeCounts
            return VStack(spacing: 10) {
                HStack {
                    Image(systemName: "camera.metering.matrix")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Room Setup").font(.title3.bold())
                        Text("Hold the phone up and pan slowly around the room")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: 420)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))

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
                    Label(counts.horizontal > 0 ? "Done" : "Skip", systemImage: "checkmark")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(20)
        }
    }

    private func surfaceCard(icon: String, label: String, found: Bool, value: String = "—") -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(found ? Color.green : Color.gray)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.subheadline)
                Text(found ? "Found \(value == "—" ? "" : "· " + value)" : "Looking… \(value == "—" ? "" : value)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}
