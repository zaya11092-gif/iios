import SwiftUI

// On-phone session log viewer (CardboardXR pattern).
struct SessionLogView: View {
    @State private var lines: [String] = SessionLog.recentLines()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if lines.isEmpty {
                    Text("No events yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Session log")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { lines = SessionLog.recentLines() }
        .refreshable { lines = SessionLog.recentLines() }
    }
}
