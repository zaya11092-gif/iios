import Foundation

// App settings, persisted via UserDefaults. Explicit @Published + didSet
// (rather than @AppStorage inside an ObservableObject, which does not publish).
final class XRSettings: ObservableObject {
    static let shared = XRSettings()

    private static func d(_ key: String, _ def: Double) -> Double { UserDefaults.standard.object(forKey: key) as? Double ?? def }
    private static func b(_ key: String, _ def: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? def }
    private static func i(_ key: String, _ def: Int) -> Int { UserDefaults.standard.object(forKey: key) as? Int ?? def }

    private func setD(_ v: Double, _ key: String) { UserDefaults.standard.set(v, forKey: key) }
    private func setB(_ v: Bool, _ key: String) { UserDefaults.standard.set(v, forKey: key) }
    private func setI(_ v: Int, _ key: String) { UserDefaults.standard.set(v, forKey: key) }

    // Headset geometry
    @Published var ipdMM: Double = XRSettings.d("ipdMM", 63) { didSet { XRSettings.shared.setD(ipdMM, "ipdMM") } }
    @Published var fovDeg: Double = XRSettings.d("fovDeg", 85) { didSet { XRSettings.shared.setD(fovDeg, "fovDeg") } }

    // Lens distortion (barrel compensation applied in the final pass)
    @Published var lensK1: Double = XRSettings.d("lensK1", -0.12) { didSet { XRSettings.shared.setD(lensK1, "lensK1") } }
    @Published var lensK2: Double = XRSettings.d("lensK2", 0.02) { didSet { XRSettings.shared.setD(lensK2, "lensK2") } }

    // Passthrough
    @Published var passthrough: Bool = XRSettings.b("passthrough", true) { didSet { XRSettings.shared.setB(passthrough, "passthrough") } }
    @Published var ptBrightness: Double = XRSettings.d("ptBrightness", 1.0) { didSet { XRSettings.shared.setD(ptBrightness, "ptBrightness") } }
    @Published var ptZoom: Double = XRSettings.d("ptZoom", 1.0) { didSet { XRSettings.shared.setD(ptZoom, "ptZoom") } }
    @Published var flipH: Bool = XRSettings.b("flipH", false) { didSet { XRSettings.shared.setB(flipH, "flipH") } }
    @Published var flipV: Bool = XRSettings.b("flipV", false) { didSet { XRSettings.shared.setB(flipV, "flipV") } }

    // Hand tracking
    @Published var visionOrient: Int = XRSettings.i("visionOrient", 1) { didSet { XRSettings.shared.setI(visionOrient, "visionOrient") } } // 1 = CGImagePropertyOrientation.right
    @Published var pinchThresh: Double = XRSettings.d("pinchThresh", 0.30) { didSet { XRSettings.shared.setD(pinchThresh, "pinchThresh") } }
    @Published var gripThresh: Double = XRSettings.d("gripThresh", 0.45) { didSet { XRSettings.shared.setD(gripThresh, "gripThresh") } }
    @Published var reachMeters: Double = XRSettings.d("reachMeters", 0.30) { didSet { XRSettings.shared.setD(reachMeters, "reachMeters") } } // saber length

    // Compositor
    @Published var timewarp: Bool = XRSettings.b("timewarp", true) { didSet { XRSettings.shared.setB(timewarp, "timewarp") } }

    // Debug
    @Published var showJoints: Bool = XRSettings.b("showJoints", false) { didSet { XRSettings.shared.setB(showJoints, "showJoints") } }
    @Published var showStats: Bool = XRSettings.b("showStats", true) { didSet { XRSettings.shared.setB(showStats, "showStats") } }

    // Phone mode: single (non-split) view for hand-held use, no stereo/IPD/lens warp.
    @Published var phoneMode: Bool = XRSettings.b("phoneMode", false) { didSet { XRSettings.shared.setB(phoneMode, "phoneMode") } }

    // Demo game
    @Published var demoSpeed: Double = XRSettings.d("demoSpeed", 1.0) { didSet { XRSettings.shared.setD(demoSpeed, "demoSpeed") } }
    @Published var demoSpawnRate: Double = XRSettings.d("demoSpawnRate", 1.2) { didSet { XRSettings.shared.setD(demoSpawnRate, "demoSpawnRate") } }

    // PC streaming (Phase 2, beta)
    @Published var pcIP: String = udString("pcIP", "192.168.1.100") { didSet { UserDefaults.standard.set(pcIP, forKey: "pcIP") } }
    @Published var pcPort: Int = XRSettings.i("pcPort", 9100) { didSet { XRSettings.shared.setI(pcPort, "pcPort") } }
    @Published var showJointDots: Bool = XRSettings.b("showJointDots", true) { didSet { XRSettings.shared.setB(showJointDots, "showJointDots") } }

    // On-device Windows layer (Phase 3)
    @Published var winExePath: String = udString("winExePath", "C:\\Program Files (x86)\\Steam\\steamapps\\common\\") { didSet { UserDefaults.standard.set(winExePath, forKey: "winExePath") } }

    private static func udString(_ key: String, _ def: String) -> String {
        UserDefaults.standard.object(forKey: key) as? String ?? def
    }
}
