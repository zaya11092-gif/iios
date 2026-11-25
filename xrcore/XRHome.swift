import ARKit
import Foundation
import Metal
import simd
import UIKit

// XRHome — the Quest-style home shell and session state machine.
//
// States:
//   scanning — first launch (or manual rescan): passthrough + plane
//              visualization; completes automatically when floor + enough
//              walls are found, then persists an ARWorldMap.
//   home     — virtual environment (gradient sky + floor grid) with a laser-
//              pointer panel dock: Demo / Rescan / PC Stream / Exit.
//   demo     — BeatDemo gameplay; both-trigger gesture opens the pause menu
//              whose "Home" button returns here.
//
// Owns the xrc frame callback and routes it to the active state.
final class XRHome: ObservableObject {

    static let shared = XRHome()

    enum UIState: Equatable {
        case booting
        case scanning
        case home
        case demo
    }

    @Published var uiState: UIState = .booting
    @Published var roomScanSaved = false

    private var state: UIState = .booting            // render-thread mirror
    private var scanStartedAt: Double = 0
    private var scanDwellOK: Double = 0              // auto-complete dwell timer
    private var lastTriggerDown = false
    private var panelsBuilt = false

    // Home panel dock (world-anchored when entering home).
    private final class Panel {
        let id: Int
        var center: SIMD3<Float>
        var normal: SIMD3<Float>
        var hw: Float
        var hh: Float
        var texId: Int32
        var hovered = false
        let action: Action
        var renderer: PanelTextRenderer

        enum Action { case startDemo, rescanRoom, toggleStream, exitVR }

        init(id: Int, center: SIMD3<Float>, normal: SIMD3<Float>, texId: Int32,
             action: Action, renderer: PanelTextRenderer) {
            self.id = id
            self.center = center
            self.normal = normal
            self.hw = 0.23
            self.hh = 0.15
            self.texId = texId
            self.action = action
            self.renderer = renderer
        }
    }

    private var panels: [Panel] = []

    private var settings: XRSettings { XRSettings.shared }
    private let core = XRCore.shared

    // MARK: - lifecycle

    /// Called by VRViewController right after beginSession. Decides: restore
    /// the saved room map (home directly) or run the first-launch room scan.
    func sessionDidStart() {
        xrc_set_frame_callback({ _userdata, predictedTime in
            XRHome.shared.frame(predictedTime)
        }, nil)

        if RoomStore.shared.hasMap {
            setState(.home)
            rebuildPanelsIfNeeded()
            // Quest-style: trust the restore, but if no surfaces reappear
            // within 3 s the map didn't relocalize -> fall back to a scan.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self, self.state == .home else { return }
                if self.core.planeCounts.horizontal == 0 {
                    self.startScan()
                }
            }
        } else {
            startScan()
        }
    }

    func shutdown() {
        xrc_set_frame_callback(nil, nil)
        panels.removeAll()
        panelsBuilt = false
        BeatDemo.shared.deactivate()
        DispatchQueue.main.async { self.uiState = .booting }
        state = .booting
    }

    // MARK: - state transitions

    private func setState(_ s: UIState) {
        state = s
        DispatchQueue.main.async { self.uiState = s }
    }

    func startScan() {
        BeatDemo.shared.deactivate()
        scanStartedAt = CACurrentMediaTime()
        scanDwellOK = 0
        setState(.scanning)
    }

    /// Manual finish (overlay button) or auto-complete.
    func finishScan() {
        core.saveRoomMap { [weak self] ok in
            DispatchQueue.main.async { self?.roomScanSaved = ok }
        }
        backToHome()
    }

    func backToHome() {
        BeatDemo.shared.deactivate()
        rebuildPanelsIfNeeded()
        setState(.home)
    }

    func startDemo() {
        BeatDemo.shared.activate()
        setState(.demo)
    }

    /// Pause menu -> Home (also used by the both-trigger gesture flow).
    func homeRequested() {
        if state == .demo { backToHome() }
    }

    // MARK: - frame callback (render thread)

    func frame(_ t: Double) {
        switch state {
        case .scanning:
            drawScan(t)
        case .home:
            drawHome(t)
        case .demo:
            core.compositor.sceneBackgroundMode = settings.passthrough ? 0 : 1
            BeatDemo.shared.frame(t)
        case .booting:
            core.compositor.sceneBackgroundMode = 1
        }
    }

    // MARK: - room scan scene

    private func drawScan(_ t: Double) {
        core.compositor.sceneBackgroundMode = 0 // passthrough during scan

        xrc_scene_begin()
        // Detected surfaces as translucent slabs (Quest Space Setup vibes).
        for (anchor, vertical) in core.planeAnchors {
            let e = anchor.extent                      // x/y = plane extents, z ≈ 0
            let m = anchor.transform
                * XRCMath.model(translation: anchor.center,
                                scale: SIMD3<Float>(max(e.x, 0.1), max(e.y, 0.1), 0.02))
            var arr = XRCMath.floatArray(m)
            if vertical {
                xrc_scene_push_box(&arr, 0.30, 0.55, 1.0, 0.30)
            } else {
                xrc_scene_push_box(&arr, 0.20, 0.90, 0.70, 0.35)
            }
        }
        // Floor hint grid once a floor exists.
        if let fy = core.floorY {
            drawFloorGrid(floorY: fy, color: SIMD4<Float>(0.25, 0.85, 0.65, 0.4))
        }
        xrc_scene_end()

        // Auto-complete: floor + >= 2 walls, held for 0.6 s, after 3 s minimum.
        let elapsed = CACurrentMediaTime() - scanStartedAt
        let c = core.planeCounts
        let ok = c.horizontal >= 1 && c.vertical >= 2
        if elapsed > 3.0, ok, scanDwellOK == 0 {
            scanDwellOK = CACurrentMediaTime()
        }
        if scanDwellOK > 0, CACurrentMediaTime() - scanDwellOK > 0.6 {
            finishScan()
        }
    }

    // MARK: - home scene

    private func drawHome(_ t: Double) {
        core.compositor.sceneBackgroundMode = 2

        let floor = core.floorY ?? 0

        xrc_scene_begin()
        drawFloorGrid(floorY: floor, color: SIMD4<Float>(0.45, 0.50, 0.62, 0.35))
        drawEnvironmentDressing(floor: floor)
        drawPanels()
        drawLaserAndHands()
        xrc_scene_end()

        handleInput()
        refreshStreamPanel()
    }

    private func drawFloorGrid(floorY: Float, color: SIMD4<Float>) {
        let gridColor = color
        for i in -6...6 {
            let x = Float(i) * 0.5
            var a = XRCMath.floatArray(XRCMath.model(translation: SIMD3<Float>(x, floorY + 0.004, 0),
                                                     scale: SIMD3<Float>(0.02, 0.02, 6)))
            xrc_scene_push_box(&a, gridColor.x, gridColor.y, gridColor.z, gridColor.w)
            var b = XRCMath.floatArray(XRCMath.model(translation: SIMD3<Float>(0, floorY + 0.004, x),
                                                     scale: SIMD3<Float>(6, 0.02, 0.02)))
            xrc_scene_push_box(&b, gridColor.x, gridColor.y, gridColor.z, gridColor.w)
        }
    }

    /// A few ambient shapes so the room doesn't feel empty.
    private func drawEnvironmentDressing(floor: Float) {
        let posts: [(SIMD3<Float>, SIMD4<Float>)] = [
            (SIMD3<Float>(-2.2, floor + 0.6, -2.2), SIMD4<Float>(0.25, 0.28, 0.38, 1)),
            (SIMD3<Float>(2.2, floor + 0.6, -2.2), SIMD4<Float>(0.25, 0.28, 0.38, 1)),
            (SIMD3<Float>(-2.2, floor + 0.6, 2.2), SIMD4<Float>(0.25, 0.28, 0.38, 1)),
            (SIMD3<Float>(2.2, floor + 0.6, 2.2), SIMD4<Float>(0.25, 0.28, 0.38, 1)),
        ]
        for (p, c) in posts {
            var arr = XRCMath.floatArray(XRCMath.model(translation: p, scale: SIMD3<Float>(0.12, 1.2, 0.12)))
            xrc_scene_push_box(&arr, c.x, c.y, c.z, c.w)
            // glow cap
            var cap = XRCMath.floatArray(XRCMath.model(translation: p + SIMD3<Float>(0, 0.66, 0),
                                                       scale: SIMD3<Float>(0.16, 0.06, 0.16)))
            xrc_scene_push_box(&cap, 0.95, 0.45, 0.25, 0.9)
        }
    }

    // MARK: - panels

    private func rebuildPanelsIfNeeded() {
        guard !panelsBuilt else { return }
        panels.removeAll()

        var headPose = xrc_pose()
        guard xrc_get_head_pose(0, &headPose) == XRC_OK else { return }
        let head = XRCMath.fromXrc(headPose)
        let headPos = head.columns.3.xyz
        var fwd = -head.columns.2.xyz
        fwd.y = 0
        if simd_length(fwd) < 0.05 { fwd = SIMD3<Float>(0, 0, -1) }
        fwd = normalize(fwd)

        let floor = core.floorY ?? (headPos.y - 1.4)
        let eyeY = floor + 1.05
        let origin = headPos + fwd * 1.25
        let right = normalize(SIMD3<Float>(-fwd.z, 0, fwd.x))

        let device = core.compositor.device
        let defs: [(String, String, String, UIColor, Panel.Action)] = [
            ("Beat Demo", "Slash flying cubes with your sabers", "", UIColor(red: 0.95, green: 0.45, blue: 0.25, alpha: 1), .startDemo),
            ("Rescan Room", "Rebuild the floor & wall map", "", UIColor(red: 0.25, green: 0.75, blue: 0.95, alpha: 1), .rescanRoom),
            ("PC Stream", "Steam games from your gaming PC", PCBridge.shared.statusText, UIColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 1), .toggleStream),
            ("Exit VR", "End the session", "", UIColor(red: 0.9, green: 0.3, blue: 0.35, alpha: 1), .exitVR),
        ]

        for (i, def) in defs.enumerated() {
            let angle = Float(i - (defs.count - 1) / 2) * 0.34 // radians of arc
            let dir = normalize(fwd * cos(angle) + right * sin(angle))
            var center = origin + dir * 1.05
            center.y = eyeY
            let renderer = PanelTextRenderer(device: device)
            renderer.render(PanelTextRenderer.Content(title: def.0, subtitle: def.1,
                                                      statusLine: def.2, accent: def.3))
            let texId = core.compositor.registerPanelTexture(renderer.texture)
            let userDir = normalize(headPos - center)
            panels.append(Panel(id: i, center: center,
                                normal: normalize(SIMD3<Float>(userDir.x, 0, userDir.z)),
                                texId: texId, action: def.4, renderer: renderer))
        }
        panelsBuilt = true
    }

    private func drawPanels() {
        for panel in panels {
            let facing = quatFacing(normal: panel.normal) // +Z toward user
            let m = XRCMath.model(translation: panel.center, rotation: facing,
                                  scale: SIMD3<Float>(panel.hw * 2, panel.hh * 2, 1))
            var arr = XRCMath.floatArray(m)
            xrc_scene_push_panel(&arr, panel.texId, panel.hovered ? 1 : 0, 1, 1, 1, 1)
        }
    }

    /// Rotation with +Z aligned to `normal` (panels face the user), Y-up.
    private func quatFacing(normal: SIMD3<Float>) -> simd_quatf {
        let n = normalize(normal)
        var up = SIMD3<Float>(0, 1, 0)
        if abs(dot(n, up)) > 0.99 { up = SIMD3<Float>(0, 0, 1) }
        let right = normalize(cross(up, n))
        let up2 = cross(n, right)
        let m = simd_float4x4(simd_float4(right.x, right.y, right.z, 0),
                              simd_float4(up2.x, up2.y, up2.z, 0),
                              simd_float4(n.x, n.y, n.z, 0),
                              simd_float4(0, 0, 0, 1))
        return simd_quatf(m)
    }

    // MARK: - laser pointer input

    private func drawLaserAndHands() {
        for h in 0..<Int(XRC_HAND_COUNT) {
            var ctrl = xrc_controller_state()
            _ = xrc_get_controller(Int32(h), &ctrl)
            guard ctrl.is_tracked != 0 else { continue }
            let pose = XRCMath.fromXrc(ctrl.pose)
            let origin = pose.columns.3.xyz
            let dir = -pose.columns.2.xyz

            // Ray vs panels
            var hitT: Float = 2.2
            var hitPanel: Panel? = nil
            for p in panels {
                if let t = raycast(origin: origin, dir: dir, panel: p), t < hitT {
                    hitT = t
                    hitPanel = p
                }
            }
            panels.forEach { $0.hovered = false }
            hitPanel?.hovered = true

            // laser beam
            let mid = origin + dir * (hitT * 0.5)
            let beamM = XRCMath.model(translation: mid, rotation: XRCMath.quatLooking(direction: dir),
                                      scale: SIMD3<Float>(0.006, 0.006, hitT))
            var bArr = XRCMath.floatArray(beamM)
            let glow: Float = hitPanel != nil ? 1 : 0.5
            xrc_scene_push_box(&bArr, 0.95 * glow + 0.05, 0.55, 0.2, 0.85)
            // wrist ball
            var sArr = XRCMath.floatArray(XRCMath.model(translation: origin, scale: SIMD3<Float>(repeating: 0.028)))
            xrc_scene_push_sphere(&sArr, 0.6, 0.65, 0.75, 1)
        }
    }

    private func raycast(origin: SIMD3<Float>, dir: SIMD3<Float>, panel: Panel) -> Float? {
        let d = dot(panel.normal, dir)
        guard abs(d) > 1e-4 else { return nil }
        let t = dot(panel.normal, panel.center - origin) / d
        guard t > 0.05, t < 3.0 else { return nil }
        let hit = origin + dir * t
        let local = hit - panel.center
        let m = simd_float4x4(quatFacing(normal: panel.normal))
        let rx = m.columns.0.xyz
        let uy = m.columns.1.xyz
        guard abs(dot(local, rx)) < panel.hw, abs(dot(local, uy)) < panel.hh else { return nil }
        return t
    }

    private func handleInput() {
        var ctrl = xrc_controller_state()
        _ = xrc_get_controller(Int32(XRC_HAND_RIGHT), &ctrl)
        let down = ctrl.is_tracked != 0 && ctrl.buttons & UInt32(XRC_BTN_TRIGGER) != 0
        defer { lastTriggerDown = down }
        guard down, !lastTriggerDown else { return }
        guard let panel = panels.first(where: { $0.hovered }) else { return }
        switch panel.action {
        case .startDemo:
            DispatchQueue.main.async { self.startDemo() }
        case .rescanRoom:
            DispatchQueue.main.async { self.startScan() }
        case .toggleStream:
            DispatchQueue.main.async { PCBridge.shared.toggle() }
            refreshPanelTextures()
        case .exitVR:
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .xrcExitRequested, object: nil)
            }
        }
    }

    private func refreshPanelTextures() {
        for panel in panels where panel.action == .toggleStream {
            panel.renderer.render(PanelTextRenderer.Content(
                title: "PC Stream",
                subtitle: "Steam games from your gaming PC",
                statusLine: PCBridge.shared.statusText,
                accent: UIColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 1)))
        }
    }

    private var lastStreamRefresh = 0.0
    private func refreshStreamPanel() {
        // live status line while streaming state changes
        let now = CACurrentMediaTime()
        if now - lastStreamRefresh > 1.0 {
            lastStreamRefresh = now
            refreshPanelTextures()
        }
    }
}

extension Notification.Name {
    static let xrcExitRequested = Notification.Name("iios.exitRequested")
}
