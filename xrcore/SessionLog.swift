import Foundation

// SessionLog — on-phone rolling session log (CardboardXR pattern). Events
// are appended to a bounded ring in Documents and viewable in Settings.
enum SessionLog {
    private static let maxLines = 300
    private static let lock = NSLock()
    private static var lines: [String] = []
    private static var formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        let snapshot = lines
        lock.unlock()

        // Persist async (best effort; logs survive relaunch).
        DispatchQueue.global(qos: .utility).async {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("session.log")
            try? snapshot.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func recentLines() -> [String] {
        lock.withLock { lines }
    }
}
