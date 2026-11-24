import SwiftUI

// In-VR stats + score HUD. TimelineView re-evaluates at a fixed cadence and
// reads runtime state directly — no state mutation during body evaluation.
struct HudOverlay: View {
    @ObservedObject private var s = XRSettings.shared

    struct HudState {
        var arFps = 0.0
        var handFps = 0.0
        var renderFps = 0.0
        var handLatency = 0.0
        var leftTracked = false
        var rightTracked = false
        var score = 0
        var combo = 0
        var misses = 0
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2)) { _ in
            let d = makeState()
            if s.showStats {
                statsView(d)
            }
        }
        .allowsHitTesting(false)
    }

    private func makeState() -> HudState {
        let l = XRCore.shared.handTracker.snapshot(for: 0)
        let r = XRCore.shared.handTracker.snapshot(for: 1)
        return HudState(
            arFps: XRCore.shared.stats.arFps,
            handFps: XRCore.shared.stats.handFps,
            renderFps: XRCore.shared.stats.renderFps,
            handLatency: XRCore.shared.stats.handLatencyMs,
            leftTracked: l.isTracked,
            rightTracked: r.isTracked,
            score: BeatDemo.shared.score,
            combo: BeatDemo.shared.combo,
            misses: BeatDemo.shared.misses)
    }

    private func statsView(_ d: HudState) -> some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    stat("render", d.renderFps)
                    stat("AR", d.arFps)
                    stat("hands", d.handFps)
                    stat("hand lag", d.handLatency, unit: "ms")
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(8)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("SCORE \(d.score)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("combo \(d.combo)   miss \(d.misses)")
                        .font(.system(size: 12, design: .monospaced))
                    HStack(spacing: 4) {
                        Image(systemName: "hand.raised.fill")
                            .foregroundStyle(d.leftTracked ? Color.green : Color.gray)
                        Image(systemName: "hand.raised.fill")
                            .foregroundStyle(d.rightTracked ? Color.green : Color.gray)
                    }
                    .font(.footnote)
                }
                .padding(8)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
        }
    }

    private func stat(_ label: String, _ value: Double, unit: String = "") -> some View {
        Text(String(format: "%@ %.0f%@", label, value, unit))
    }
}
