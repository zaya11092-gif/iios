import ARKit
import Foundation
import Metal
import simd
import UIKit

// XRHome — the OS shell, ported 1:1 from brenpoly/CardboardXR's UX (Apache-2.0):
//
//   * gaze + pinch with reticle (primary input) + PinchRouter priority chain
//     (palm gear -> gazed button -> pointer button -> plain click)
//   * palm-summoned floating settings panel with lazy follow and X close
//   * app-library home: tiles grid, gaze-to-preview, pinch to open
//   * room scan on startup: continuous surface detection until convergence,
//     Skip button, SHORT re-scan (floor only) on re-entries, and a Scan Room
//     toggle in the settings panel that "scans again, or ends a scan"
//   * boundary grids drawn on detected surfaces in VR (their boundaryCm
//     warning) and the checkerboard lobby floor
//   * hand skeleton wireframe while immersive
//
// States: scanning / home / demo. Owns the xrc frame callback and the whole
// scene-item lifecycle.
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
    /// VR Mode: full 3D environment (skeleton hands) vs passthrough.
    @Published var vrMode = false
    /// Floating settings panel visibility (palm pinch / both-triggers / X).
    @Published var panelVisible = false

    private var state: UIState = .booting            // render-thread mirror
    private var vrModeMirror = false                 // render-thread mirror
    private var scanStartedAt: Double = 0
    private var scanDwellOK: Double = 0
    private var shortScan = false                    // CardboardXR: re-entry scans run until floor only
    private var lastMenuToggle: Double = 0
    private var uiBuilt = false
    private var lastRouterPinchDown = [false, false]

    // Buttons drive the app-library tiles and the settings panel.
    private final class MenuButton {
        let action: Action
        let renderer: PanelTextRenderer
        var texId: Int32 = 0
        var hovered = false

        enum Action { case goHome, startDemo, toggleVR, toggleStream, rescanRoom, launchWindows, exitVR,
                      brightCycle, speedCycle, spawnCycle, closePanel }

        init(action: Action, renderer: PanelTextRenderer) {
            self.action = action
            self.renderer = renderer
        }
    }

    private var libraryButtons: [MenuButton] = []    // app-library home tiles
    private var panelButtons: [MenuButton] = []      // floating settings panel
    private var palmIconRenderer: PanelTextRenderer!
    private var palmIconTexId: Int32 = 0
    private var reticleTexId: Int32 = 0

    // Floating panels share one lazy-follow implementation.
    private var panelButtonsBuilt = false
    private var libraryBuilt = false
    private var panelPos = SIMD3<Float>(0, 1.2, -0.65)
    private var panelFacing = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var libPos = SIMD3<Float>(0, 1.2, -0.65)
    private var libFacing = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var lastPanelT: Double = 0
    private var panelMirror = false

    private var settings: XRSettings { XRSettings.shared }
    private let core = XRCore.shared

    // MARK: - lifecycle

    func sessionDidStart() {
        xrc_set_frame_callback({ _userdata, predictedTime in
            XRHome.shared.frame(predictedTime)
        }, nil)

        if RoomStore.shared.hasMap {
            setState(.home)
            // CardboardXR: re-entries run only a SHORT scan until the floor
            // is found (saves CPU for hand tracking). If the restored map
            // produced no floor within 3 s, run it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self, self.state == .home else { return }
                if self.core.planeCounts.horizontal == 0 {
                    self.startScan(short: true)
                }
            }
        } else {
            startScan(short: false)
        }
    }

    func shutdown() {
        xrc_set_frame_callback(nil, nil)
        libraryButtons.removeAll()
        panelButtons.removeAll()
        uiBuilt = false
        BeatDemo.shared.deactivate()
        DispatchQueue.main.async {
            self.uiState = .booting
            self.panelVisible = false
            self.vrMode = false
        }
        state = .booting
        vrModeMirror = false
        panelMirror = false
    }

    // MARK: - state transitions

    private func setState(_ s: UIState) {
        state = s
        DispatchQueue.main.async { self.uiState = s }
    }

    /// CardboardXR: `short` scans complete as soon as the floor is found;
    /// full scans (first launch / manual) want floor + walls.
    func startScan(short: Bool) {
        BeatDemo.shared.deactivate()
        shortScan = short
        scanStartedAt = CACurrentMediaTime()
        scanDwellOK = 0
        setState(.scanning)
        SessionLog.log("scan started (\(short ? "short" : "full"))")
    }

    func finishScan() {
        core.saveRoomMap { [weak self] ok in
            DispatchQueue.main.async {
                self?.roomScanSaved = ok
                SessionLog.log("scan saved: \(ok)")
            }
        }
        backToHome()
    }

    func backToHome() {
        BeatDemo.shared.deactivate()
        setState(.home)
    }

    func startDemo() {
        BeatDemo.shared.activate()
        setState(.demo)
        SessionLog.log("demo started")
    }

    /// CardboardXR's settings-panel Scan Room toggle: "scans again, or ends
    /// a scan."
    func toggleScanRoom() {
        if state == .scanning {
            finishScan()
        } else {
            startScan(short: false)
        }
    }

    // MARK: - frame callback (render thread)

    func frame(_ t: Double) {
        let dt = lastPanelT == 0 ? 1.0 / 60.0 : min(max(t - lastPanelT, 0.001), 0.2)
        lastPanelT = t

        switch state {
        case .scanning:
            core.compositor.sceneBackgroundMode = 0 // passthrough always in scan
            drawScan(t)
        case .home:
            core.compositor.sceneBackgroundMode = vrModeMirror ? 2 : 0
            drawEnvironment()
            drawLibrary(dt: dt)
            drawSkeletonIfVR()
        case .demo:
            core.compositor.sceneBackgroundMode = vrModeMirror ? 2 : 0
            drawEnvironment()
            drawSkeletonIfVR()
            BeatDemo.shared.frame(t)
        case .booting:
            core.compositor.sceneBackgroundMode = 1
        }

        drawPalmIcons()
        drawSettingsPanel(dt: dt)
        routeInput()
    }

    // MARK: - room scan (CardboardXR flow)

    private func drawScan(_ t: Double) {
        drawScanPlanes()

        let elapsed = CACurrentMediaTime() - scanStartedAt
        let c = core.planeCounts
        // Full scan: floor + >= 2 walls held 0.6 s after 3 s minimum.
        // Short scan (re-entry): floor alone, or 4 s cap.
        let ok = shortScan ? c.horizontal >= 1 : (c.horizontal >= 1 && c.vertical >= 2)
        let cap = shortScan ? 4.0 : Double.infinity
        if elapsed > (shortScan ? 1.0 : 3.0), ok, scanDwellOK == 0 {
            scanDwellOK = CACurrentMediaTime()
        }
        if elapsed > cap { finishScan() }
        if scanDwellOK > 0, CACurrentMediaTime() - scanDwellOK > 0.6 {
            finishScan()
        }
    }

    /// Translucent blue grid mesh over detected surfaces (scan visual).
    private func drawScanPlanes() {
        let fill = SIMD4<Float>(0.30, 0.62, 1.00, 0.10)
        let grid = SIMD4<Float>(0.35, 0.68, 1.00, 0.42)
        let gridFloor = SIMD4<Float>(0.30, 0.80, 1.00, 0.55)
        let lineSpacing: Float = 0.5
        let maxInteriorLines = 10

        for (anchor, vertical) in core.planeAnchors {
            let e = anchor.extent
            let hx = max(e.x * 0.5, 0.15)
            let hy = max(e.y * 0.5, 0.15)
            let at = anchor.transform
            let color = vertical ? grid : gridFloor

            var fillArr = XRCMath.floatArray(at * XRCMath.model(
                translation: anchor.center, scale: SIMD3<Float>(hx * 2, hy * 2, 0.015)))
            xrc_scene_push_box(&fillArr, fill.x, fill.y, fill.z, fill.w)

            for (dx, dy, sx, sy) in [(0, hy, hx * 2, 1), (0, -hy, hx * 2, 1),
                                     (hx, 0, 1, hy * 2), (-hx, 0, 1, hy * 2)] as [(Float, Float, Float, Float)] {
                var line = XRCMath.floatArray(at * XRCMath.model(
                    translation: anchor.center + SIMD3<Float>(dx, dy, 0),
                    scale: SIMD3<Float>(sx == 1 ? 0.015 : sx, sy == 1 ? 0.015 : sy, 0.02)))
                xrc_scene_push_box(&line, color.x, color.y, color.z, 0.85)
            }

            let nx = min(Int(hx / lineSpacing), maxInteriorLines / 2)
            let ny = min(Int(hy / lineSpacing), maxInteriorLines / 2)
            for i in 1...max(nx, 1) {
                let x = -hx + (2 * hx) * Float(i) / Float(max(nx, 1) + 1)
                var l = XRCMath.floatArray(at * XRCMath.model(
                    translation: anchor.center + SIMD3<Float>(x, 0, 0),
                    scale: SIMD3<Float>(0.01, hy * 2, 0.012)))
                xrc_scene_push_box(&l, color.x, color.y, color.z, color.w)
            }
            for i in 1...max(ny, 1) {
                let y = -hy + (2 * hy) * Float(i) / Float(max(ny, 1) + 1)
                var l = XRCMath.floatArray(at * XRCMath.model(
                    translation: anchor.center + SIMD3<Float>(0, y, 0),
                    scale: SIMD3<Float>(hx * 2, 0.01, 0.012)))
                xrc_scene_push_box(&l, color.x, color.y, color.z, color.w)
            }
        }
    }

    // MARK: - environment

    /// CardboardXR lobby: checkerboard floor; plus boundary grids drawn ON
    /// detected surfaces while immersive (their boundaryCm proximity warning).
    private func drawEnvironment() {
        guard vrModeMirror else { return }
        let floor = core.floorY ?? 0

        // checkerboard lobby floor (±2 m, 0.5 m tiles)
        let light = SIMD4<Float>(0.62, 0.63, 0.66, 0.85)
        let dark = SIMD4<Float>(0.16, 0.17, 0.20, 0.85)
        for ix in -4...3 {
            for iz in -4...3 {
                let x = (Float(ix) + 0.5) * 0.5
                let z = (Float(iz) + 0.5) * 0.5
                let c = (ix + iz) % 2 == 0 ? light : dark
                var t = XRCMath.floatArray(XRCMath.model(translation: SIMD3<Float>(x, floor + 0.003, z),
                                                         scale: SIMD3<Float>(0.5, 0.02, 0.5)))
                xrc_scene_push_box(&t, c.x, c.y, c.z, c.w)
            }
        }

        // boundary grids on real surfaces (CardboardXR boundaryCm warning)
        let bGrid = SIMD4<Float>(0.95, 0.55, 0.20, 0.30)
        for (anchor, _) in core.planeAnchors {
            let e = anchor.extent
            let hx = max(e.x * 0.5, 0.15)
            let hy = max(e.y * 0.5, 0.15)
            let at = anchor.transform
            for i in -1...1 {
                let fx = hx * Float(i) * 0.6
                var l1 = XRCMath.floatArray(at * XRCMath.model(
                    translation: anchor.center + SIMD3<Float>(fx, 0, 0),
                    scale: SIMD3<Float>(0.012, hy * 2, 0.014)))
                xrc_scene_push_box(&l1, bGrid.x, bGrid.y, bGrid.z, bGrid.w)
                let fy = hy * Float(i) * 0.6
                var l2 = XRCMath.floatArray(at * XRCMath.model(
                    translation: anchor.center + SIMD3<Float>(0, fy, 0),
                    scale: SIMD3<Float>(hx * 2, 0.012, 0.014)))
                xrc_scene_push_box(&l2, bGrid.x, bGrid.y, bGrid.z, bGrid.w)
            }
        }
    }

    // MARK: - hand skeleton (VR Mode)

    private func drawSkeletonIfVR() {
        guard vrModeMirror else { return }
        let bone = SIMD4<Float>(0.55, 0.90, 1.00, 0.55)
        let joint = SIMD4<Float>(0.75, 0.95, 1.00, 0.85)
        let thick: Float = 0.007

        for h in 0..<Int(XRC_HAND_COUNT) {
            let s = core.handTracker.snapshot(for: Int32(h))
            guard s.isTracked, s.hasJoints, s.joints.count == 21 else { continue }
            for (i, j) in HandTracker.bonePairs {
                let a = s.joints[i]
                let b = s.joints[j]
                let len = simd_length(a - b)
                guard len > 1e-4 else { continue }
                let dir = normalize(b - a)
                let m = XRCMath.model(translation: (a + b) * 0.5,
                                      rotation: XRCMath.quatLooking(direction: dir),
                                      scale: SIMD3<Float>(thick, thick, len))
                var arr = XRCMath.floatArray(m)
                xrc_scene_push_box(&arr, bone.x, bone.y, bone.z, bone.w)
            }
            for p in s.joints {
                var arr = XRCMath.floatArray(XRCMath.model(translation: p,
                                                           scale: SIMD3<Float>(repeating: 0.013)))
                xrc_scene_push_sphere(&arr, joint.x, joint.y, joint.z, joint.w)
            }
        }
    }

    // MARK: - palm gesture indicator

    private func drawPalmIcons() {
        guard state == .home || state == .demo else { return }
        guard let headPose = core.headPose() else { return }
        let headPos = headPose.columns.3.xyz

        for h in 0..<Int(XRC_HAND_COUNT) {
            let s = core.handTracker.snapshot(for: Int32(h))
            guard s.isTracked, s.hasJoints, s.palmFlat,
                  s.joints.count == 21 else { continue }
            let thumbTip = s.joints[4]
            let indexTip = s.joints[8]
            let iconPos = (thumbTip + indexTip) * 0.5
            let towardUser = normalize(headPos - iconPos)
            let m = XRCMath.model(translation: iconPos + towardUser * 0.03,
                                  rotation: quatFacing(normal: towardUser),
                                  scale: SIMD3<Float>(0.055, 0.055, 1))
            var arr = XRCMath.floatArray(m)
            xrc_scene_push_panel(&arr, palmIconTexId, 1, 1, 1, 1, 1)
        }
    }

    // MARK: - shared panel construction

    private func buildUIIfNeeded() {
        guard !uiBuilt else { return }
        let device = core.compositor.device
        let orange = UIColor(red: 0.95, green: 0.45, blue: 0.25, alpha: 1)
        let blue = UIColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 1)
        let green = UIColor(red: 0.3, green: 0.85, blue: 0.6, alpha: 1)
        let red = UIColor(red: 0.9, green: 0.3, blue: 0.35, alpha: 1)
        let purple = UIColor(red: 0.55, green: 0.35, blue: 1.0, alpha: 1)

        func make(_ action: MenuButton.Action, _ title: String, _ status: String = "", _ accent: UIColor,
                  into list: inout [MenuButton]) {
            let r = PanelTextRenderer(device: device, width: 256, height: 256, style: .button)
            r.render(PanelTextRenderer.Content(title: title, statusLine: status, accent: accent))
            let b = MenuButton(action: action, renderer: r)
            b.texId = core.compositor.registerPanelTexture(r.texture)
            list.append(b)
        }

        // App library (home tiles, CardboardXR lobby): the "apps".
        make(.startDemo, "Beat Demo", "", orange, into: &libraryButtons)
        make(.toggleStream, "PC Stream", PCBridge.shared.status.label, blue, into: &libraryButtons)
        make(.launchWindows, "Windows", WindowsHost.shared.status.label, purple, into: &libraryButtons)
        make(.rescanRoom, "Scan Room", "", blue, into: &libraryButtons)
        make(.toggleVR, "VR Mode", "OFF", blue, into: &libraryButtons)
        make(.exitVR, "Exit", "", red, into: &libraryButtons)

        // Settings panel (palm gear): custom options.
        make(.toggleVR, "VR Mode", "OFF", blue, into: &panelButtons)
        make(.brightCycle, "Brightness", String(format: "%.1f", settings.ptBrightness), blue, into: &panelButtons)
        make(.speedCycle, "Speed", String(format: "%.1f", settings.demoSpeed), orange, into: &panelButtons)
        make(.spawnCycle, "Spawns", String(format: "%.1f", settings.demoSpawnRate), orange, into: &panelButtons)
        make(.rescanRoom, "Scan Room", "", green, into: &panelButtons)
        make(.toggleStream, "PC Stream", PCBridge.shared.status.label, blue, into: &panelButtons)
        make(.launchWindows, "Windows", WindowsHost.shared.status.label, purple, into: &panelButtons)
        make(.goHome, "Home", "", green, into: &panelButtons)
        make(.exitVR, "Exit", "", red, into: &panelButtons)
        make(.closePanel, "Close", "", red, into: &panelButtons)

        let icon = PanelTextRenderer(device: device, width: 128, height: 128, style: .menuIcon)
        icon.render(PanelTextRenderer.Content(title: "", accent: orange))
        palmIconTexId = core.compositor.registerPanelTexture(icon.texture)
        palmIconRenderer = icon

        let reticle = PanelTextRenderer(device: device, width: 128, height: 128, style: .reticle)
        reticle.render(PanelTextRenderer.Content(title: "", accent: UIColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 1)))
        reticleTexId = core.compositor.registerPanelTexture(reticle.texture)

        uiBuilt = true
    }

    /// Re-renders every button with `action` (panel + library) with a new
    /// status line. Called from the main thread.
    private func rerenderStatus(_ action: MenuButton.Action, title: String, status: String, accent: UIColor) {
        for b in panelButtons + libraryButtons where b.action == action {
            b.renderer.render(PanelTextRenderer.Content(title: title, statusLine: status, accent: accent))
        }
    }

    // MARK: - floating panels (lazy follow)

    private func drawGridPanel(_ buttons: [MenuButton], pos: SIMD3<Float>, facing: simd_quatf,
                               cols: Int, cell: Float, size: Float) {
        let right = simd_act(facing, SIMD3<Float>(1, 0, 0))
        let up = simd_act(facing, SIMD3<Float>(0, 1, 0))
        let rows = (buttons.count + cols - 1) / cols
        for (i, b) in buttons.enumerated() {
            let row = i / cols
            let col = i % cols
            let rx = (Float(col) - Float(cols - 1) * 0.5) * cell
            let ry = (Float(rows) * 0.5 - Float(row) - 0.5) * cell
            let p = pos + right * rx + up * ry
            let m = XRCMath.model(translation: p, rotation: facing, scale: SIMD3<Float>(size, size, 1))
            var arr = XRCMath.floatArray(m)
            xrc_scene_push_panel(&arr, b.texId, b.hovered ? 1 : 0, 1, 1, 1, 1)
        }
    }

    private func drawLibrary(dt: Double) {
        buildUIIfNeeded()
        guard let headPose = core.headPose() else { return }
        let head = headPose.columns.3.xyz
        var fwd = -headPose.columns.2.xyz
        fwd.y = 0
        if simd_length(fwd) < 0.05 { fwd = SIMD3<Float>(0, 0, -1) }
        fwd = normalize(fwd)
        let floor = core.floorY ?? (head.y - 1.4)
        let alpha = Float(min(1, dt * 9))

        let targetY = max(floor + 1.0, head.y - 0.1)
        libPos += (SIMD3<Float>(head.x + fwd.x * 0.66, targetY, head.z + fwd.z * 0.66) - libPos) * alpha
        libFacing = simd_slerp(libFacing, quatFacing(normal: SIMD3<Float>(-fwd.x, -0.08, -fwd.z)), alpha)

        drawGridPanel(libraryButtons, pos: libPos, facing: libFacing, cols: 2, cell: 0.19, size: 0.17)
    }

    private func drawSettingsPanel(dt: Double) {
        guard panelMirror else { return }
        buildUIIfNeeded()
        guard let headPose = core.headPose() else { return }
        let head = headPose.columns.3.xyz
        var fwd = -headPose.columns.2.xyz
        fwd.y = 0
        if simd_length(fwd) < 0.05 { fwd = SIMD3<Float>(0, 0, -1) }
        fwd = normalize(fwd)
        let floor = core.floorY ?? (head.y - 1.4)
        let alpha = Float(min(1, dt * 9))

        let targetY = max(floor + 0.9, head.y - 0.18)
        panelPos += (SIMD3<Float>(head.x + fwd.x * 0.62, targetY, head.z + fwd.z * 0.62) - panelPos) * alpha
        panelFacing = simd_slerp(panelFacing, quatFacing(normal: SIMD3<Float>(-fwd.x, -0.12, -fwd.z)), alpha)

        drawGridPanel(panelButtons, pos: panelPos, facing: panelFacing, cols: 3, cell: 0.145, size: 0.13)
    }

    /// Entry point for the both-triggers system gesture (XRCore): toggles
    /// the floating settings panel in every mode.
    func togglePanelFromGesture() {
        panelMirror.toggle()
        let v = panelMirror
        DispatchQueue.main.async { self.panelVisible = v }
    }

    // MARK: - transforms for raycasts

    private func buttonTransform(_ i: Int, buttons: [MenuButton], layout: ButtonLayout) -> (SIMD3<Float>, simd_quatf, Float) {
        switch layout {
        case .panel:
            let cell: Float = 0.145
            let cols = 3
            let row = i / cols
            let col = i % cols
            let rx = (Float(col) - Float(cols - 1) * 0.5) * cell
            let ry = (Float(buttons.count / cols) * 0.5 - Float(row) - 0.5) * cell
            let pos = panelPos + simd_act(panelFacing, SIMD3<Float>(1, 0, 0)) * rx
                    + simd_act(panelFacing, SIMD3<Float>(0, 1, 0)) * ry
            return (pos, panelFacing, 0.065)
        case .library:
            let cell: Float = 0.19
            let cols = 2
            let row = i / cols
            let col = i % cols
            let rx = (Float(col) - Float(cols - 1) * 0.5) * cell
            let ry = (Float(buttons.count / cols) * 0.5 - Float(row) - 0.5) * cell
            let pos = libPos + simd_act(libFacing, SIMD3<Float>(1, 0, 0)) * rx
                    + simd_act(libFacing, SIMD3<Float>(0, 1, 0)) * ry
            return (pos, libFacing, 0.085)
        }
    }

    private enum ButtonLayout { case panel, library }

    private func firstRayHit(_ buttons: [MenuButton], layout: ButtonLayout,
                             origin: SIMD3<Float>, dir: SIMD3<Float>) -> (index: Int, point: SIMD3<Float>)? {
        var best: (Int, Float, SIMD3<Float>)?
        for (i, _) in buttons.enumerated() {
            let (pos, facing, half) = buttonTransform(i, buttons: buttons, layout: layout)
            let normal = simd_act(facing, SIMD3<Float>(0, 0, 1))
            let d = dot(normal, dir)
            guard abs(d) > 1e-4 else { continue }
            let t = dot(normal, pos - origin) / d
            guard t > 0.05, t < 2.0 else { continue }
            let hit = origin + dir * t
            let local = hit - pos
            let m = simd_float4x4(facing)
            if abs(dot(local, m.columns.0.xyz)) < half, abs(dot(local, m.columns.1.xyz)) < half {
                if best == nil || t < best!.1 { best = (i, t, hit) }
            }
        }
        return best.map { (index: $0.0, point: $0.2) }
    }

    // MARK: - unified input router (CardboardXR PinchRouter pattern)
    //
    // Priority chain per pinch rising edge:
    //   1. palm-flat pinch  -> toggle the settings panel
    //   2. gazed button     -> activate (reticle marks the target)
    //   3. pointer button   -> activate (laser beam from the pointing hand)
    //   4. plain click      -> falls through (demo sabers handle contact)

    private func routeInput() {
        guard state == .home || state == .demo else {
            lastRouterPinchDown = [false, false]
            return
        }

        let active: (buttons: [MenuButton], layout: ButtonLayout)?
        if panelMirror {
            active = (panelButtons, .panel)
        } else if state == .home {
            active = (libraryButtons, .library)
        } else {
            active = nil
        }

        var hoverList: [MenuButton]?
        var hover: Int? = nil
        var hitPoint: SIMD3<Float>? = nil
        var viaGaze = false

        if let a = active {
            for b in a.buttons { b.hovered = false }
            if let g = gazeRay(), let hit = firstRayHit(a.buttons, layout: a.layout, origin: g.0, dir: g.1) {
                hoverList = a.buttons
                hover = hit.index
                hitPoint = hit.point
                viaGaze = true
            }
            if hover == nil, let hand = bestPointerHand() {
                var ctrl = xrc_controller_state()
                _ = xrc_get_controller(hand, &ctrl)
                if ctrl.is_tracked != 0 {
                    let pose = XRCMath.fromXrc(ctrl.pose)
                    let origin = pose.columns.3.xyz
                    let dir = -pose.columns.2.xyz
                    if let hit = firstRayHit(a.buttons, layout: a.layout, origin: origin, dir: dir) {
                        hoverList = a.buttons
                        hover = hit.index
                        hitPoint = hit.point
                        drawBeam(from: origin, dir: dir, to: hit.point)
                    }
                }
            }
            if let list = hoverList, let i = hover {
                list[i].hovered = true
            }
            if viaGaze, let hp = hitPoint, let headPose = core.headPose() {
                let toward = normalize(headPose.columns.3.xyz - hp)
                let m = XRCMath.model(translation: hp + toward * 0.012,
                                      rotation: quatFacing(normal: toward),
                                      scale: SIMD3<Float>(0.03, 0.03, 1))
                var arr = XRCMath.floatArray(m)
                xrc_scene_push_panel(&arr, reticleTexId, 0, 1, 1, 1, 1)
            }
        }

        for h in 0..<Int(XRC_HAND_COUNT) {
            let s = core.handTracker.snapshot(for: Int32(h))
            let down = s.isTracked && s.buttons & UInt32(XRC_BTN_TRIGGER) != 0
            let rising = down && !lastRouterPinchDown[h]
            lastRouterPinchDown[h] = down
            guard rising else { continue }

            if s.palmFlat {
                lastMenuToggle = CACurrentMediaTime()
                panelMirror.toggle()
                let v = panelMirror
                DispatchQueue.main.async { self.panelVisible = v }
                return
            }
            if let list = hoverList, let i = hover {
                activate(list[i].action)
                return
            }
        }
    }

    private func gazeRay() -> (origin: SIMD3<Float>, dir: SIMD3<Float>)? {
        guard let headPose = core.headPose() else { return nil }
        let dir = normalize(-headPose.columns.2.xyz)
        return (headPose.columns.3.xyz, dir)
    }

    private func bestPointerHand() -> Int32? {
        let r = core.handTracker.snapshot(for: Int32(XRC_HAND_RIGHT))
        if r.isTracked { return Int32(XRC_HAND_RIGHT) }
        let l = core.handTracker.snapshot(for: Int32(XRC_HAND_LEFT))
        if l.isTracked { return Int32(XRC_HAND_LEFT) }
        return nil
    }

    private func drawBeam(from origin: SIMD3<Float>, dir: SIMD3<Float>, to point: SIMD3<Float>) {
        let along = max(simd_dot(point - origin, dir), 0.05)
        let mid = origin + dir * (along * 0.5)
        let bm = XRCMath.model(translation: mid, rotation: XRCMath.quatLooking(direction: dir),
                               scale: SIMD3<Float>(0.005, 0.005, along))
        var bArr = XRCMath.floatArray(bm)
        xrc_scene_push_box(&bArr, 1.0, 0.85, 0.4, 0.9)
    }

    // MARK: - actions

    private func activate(_ action: MenuButton.Action) {
        switch action {
        case .goHome:
            DispatchQueue.main.async { self.backToHome() }
        case .startDemo:
            DispatchQueue.main.async { self.startDemo() }
        case .toggleVR:
            DispatchQueue.main.async {
                self.vrMode.toggle()
                let v = self.vrMode
                self.vrModeMirror = v
                SessionLog.log("vr mode: \(v ? "on" : "off")")
                self.rerenderStatus(.toggleVR, title: "VR Mode", status: v ? "ON" : "OFF",
                                    accent: UIColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 1))
            }
        case .toggleStream:
            DispatchQueue.main.async { PCBridge.shared.toggle() }
            rerenderStatus(.toggleStream, title: "PC Stream", status: PCBridge.shared.status.label,
                           accent: UIColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 1))
        case .launchWindows:
            DispatchQueue.main.async {
                WindowsHost.shared.launch(exePath: self.settings.winExePath)
                self.rerenderStatus(.launchWindows, title: "Windows", status: WindowsHost.shared.status.label,
                                    accent: UIColor(red: 0.55, green: 0.35, blue: 1.0, alpha: 1))
            }
        case .rescanRoom:
            DispatchQueue.main.async { self.toggleScanRoom() }
        case .brightCycle:
            DispatchQueue.main.async {
                let presets = [0.5, 0.8, 1.0, 1.3]
                let cur = presets.first(where: { abs($0 - self.settings.ptBrightness) < 0.01 })
                let next = presets[(presets.firstIndex(where: { $0 == cur }) ?? presets.count - 1 + 1) % presets.count]
                self.settings.ptBrightness = next
                self.rerenderPanelButton(.brightCycle, status: String(format: "%.1f", next))
            }
        case .speedCycle:
            DispatchQueue.main.async {
                let presets = [0.5, 1.0, 1.5, 2.0]
                let cur = presets.first(where: { abs($0 - self.settings.demoSpeed) < 0.01 })
                let next = presets[(presets.firstIndex(where: { $0 == cur }) ?? presets.count - 1 + 1) % presets.count]
                self.settings.demoSpeed = next
                self.rerenderPanelButton(.speedCycle, status: String(format: "%.1f", next))
            }
        case .spawnCycle:
            DispatchQueue.main.async {
                let presets = [0.5, 1.0, 1.5, 2.5]
                let cur = presets.first(where: { abs($0 - self.settings.demoSpawnRate) < 0.01 })
                let next = presets[(presets.firstIndex(where: { $0 == cur }) ?? presets.count - 1 + 1) % presets.count]
                self.settings.demoSpawnRate = next
                self.rerenderPanelButton(.spawnCycle, status: String(format: "%.1f", next))
            }
        case .closePanel:
            panelMirror = false
            DispatchQueue.main.async { self.panelVisible = false }
        case .exitVR:
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .xrcExitRequested, object: nil)
            }
        }
    }

    private func rerenderPanelButton(_ action: MenuButton.Action, status: String) {
        let titles: [MenuButton.Action: String] = [
            .brightCycle: "Brightness", .speedCycle: "Speed", .spawnCycle: "Spawns",
        ]
        rerenderStatus(action, title: titles[action] ?? "?", status: status,
                       accent: action == .brightCycle
                           ? UIColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 1)
                           : UIColor(red: 0.95, green: 0.45, blue: 0.25, alpha: 1))
    }

    /// Rotation with +Z aligned to `normal`, Y-up reference.
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
}

extension Notification.Name {
    static let xrcExitRequested = Notification.Name("iios.exitRequested")
}
