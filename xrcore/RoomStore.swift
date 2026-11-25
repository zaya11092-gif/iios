import ARKit
import Foundation

// Room scan persistence — the Quest "Space Setup" equivalent. The ARWorldMap
// keeps the world origin, floor plane and wall anchors stable across app
// launches, so the home environment re-anchors itself without re-scanning.
final class RoomStore {

    static let shared = RoomStore()

    private var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("room.worldmap")
    }

    var hasMap: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    func load() -> ARWorldMap? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    func save(_ session: ARSession, completion: ((Bool) -> Void)? = nil) {
        session.getCurrentWorldMap { [weak self] map, error in
            guard let self = self else { return }
            guard let map = map, error == nil else {
                completion?(false)
                return
            }
            do {
                let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                try data.write(to: self.fileURL, options: .atomic)
                completion?(true)
            } catch {
                completion?(false)
            }
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
