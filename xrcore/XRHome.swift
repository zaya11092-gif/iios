import ARKit
import Foundation
import Metal
import simd
import UIKit

// XRHome — the OS shell: Quest-style system gesture (palm up + pinch opens
// the menu bar), universal menu bar with a VR Mode toggle, hand skeleton
// wireframe in immersive mode, and the Quest-look room scan (blue grid mesh).
//
// States:
//   scanning — passthrough + Quest-blue grid over detected planes.
//   home     — menu bar; background is the VR environment (vrMode on) or
//              passthrough (vrMode off).
//   demo     — BeatDemo gameplay; menu bar appears on the system gesture.
//
// Owns the xrc frame callback and the whole scene-item lifecycle.
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
    /// Universal menu bar visibility (home state shows it by default).
    @Published var menuVisible = true
    /// CardboardXR-style floating settings panel (palm-up pinch / both-triggers).
    @Published var panelVisible = false

    private var state: UIState = .booting            // render-thread mirror
    private var vrModeMirror = false                 // render-thread mirror
    private var menuVisibleMirror = true
    private var scanStartedAt: Double = 0
    private var scanDwellOK: Double = 0
    private var lastMenuToggle: Double = 0
    private var menuBuilt = false

    // Menu bar buttons (world-relative to head each frame).
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

    private var menuButtons: [MenuButton] = []
    private var palmIconRenderer: PanelTextRenderer!
    private var palmIconTexId: Int32 = 0
    private var streamButtonIndex: Int = -1
    private var vrButtonIndex: Int = -1
    private var windowsButtonIndex: Int = -1
    private var reticleTexId: Int32 = 0

    // Floating settings panel (lazy-follow, CardboardXR-style).
    private var panelButtons: [MenuButton] = []
    private var panelBuilt = false
    private var panelPos = SIMD3<Float>(0, 1.2, -0.65)
    private var panelFacing = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
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
            buildMenuIfNeeded()
            // If the saved room map fails to relocalize (no surfaces within
            // 3 s), fall back to a fresh scan.
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
        menuButtons.removeAll()
        panelButtons.removeAll()
        menuBuilt = false
        panelBuilt = false
        BeatDemo.shared.deactivate()
        DispatchQueue.main.async {
            self.uiState = .booting
            self.menuVisible = true
            self.panelVisible = false
            self.vrMode = false
        }
        state = .booting
        vrModeMirror = false
        menuVisibleMirror = true
        panelMirror = false
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

    func finishScan() {
        core.saveRoomMap { [weak self] ok in
            DispatchQueue.main.async { self?.roomScanSaved = ok }
        }
        backToHome()
    }

    func backToHome() {
        BeatDemo.shared.deactivate()
        DispatchQueue.main.async { self.menuVisible = true }
        menuVisibleMirror = true
        setState(.home)
    }

    func startDemo() {
        BeatDemo.shared.activate()
        setState(.demo)
    }

    // MARK: - frame callback (render thread)

    func frame(_ t: Double) {
        // Scene lifecycle (begin/end) is owned by XRCore.draw, which invokes
        // this as the xrc frame callback — we only push items here.
        switch state {
        case .scanning:
            core.compositor.sceneBackgroundMode = 0 // passthrough always in scan
            drawScan(t)
        case .home:
            drawMenu(t)
            drawSkeletonIfVR()
        case .demo:
            drawMenu(t)
            drawSkeletonIfVR()
            BeatDemo.shared.frame(t)
        case .booting:
            core.compositor.sceneBackgroundMode = 1
        }

        let dt = lastPanelT == 0 ? 1.0 / 60.0 : min(max(t - lastPanelT, 0.001), 0.2)
        lastPanelT = t
        drawPanel(dt: dt)
        drawPalmIcons()
        routeInput()
    }

    private func syncBackgroundMode() {
        // VR Mode -> full 3D environment everywhere; otherwise passthrough
        // (falling back to dark if the camera feed is unavailable).
        core.compositor.sceneBackgroundMode = vrModeMirror ? 2 : 0
    }

    // MARK: - room scan (Quest Space Setup look)

    private func drawScan(_ t: Double) {
        drawScanPlanes()

        // Auto-complete: floor + >= 2 walls held for 0.6 s after 3 s minimum.
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

    /// Quest-style translucent blue grid mesh over detected surfaces.
    private func drawScanPlanes() {
        let fill = SIMD4<Float>(0.30, 0.62, 1.00, 0.10)
        let grid = SIMD4<Float>(0.35, 0.68, 1.00, 0.42)
        let gridFloor = SIMD4<Float>(0.30, 0.80, 1.00, 0.55)
        let lineSpacing: Float = 0.5
        let maxInteriorLines = 10

        for (anchor, vertical) in core.planeAnchors {
            let e = anchor.extent                      // x/y = extents, z ≈ 0
            let hx = max(e.x * 0.5, 0.15)
            let hy = max(e.y * 0.5, 0.15)
            let at = anchor.transform
            let color = vertical ? grid : gridFloor

            // translucent fill slab
            var fillArr = XRCMath.floatArray(at * XRCMath.model(
                translation: anchor.center, scale: SIMD3<Float>(hx * 2, hy * 2, 0.015)))
            xrc_scene_push_box(&fillArr, fill.x, fill.y, fill.z, fill.w)

            // boundary frame
            for (dx, dy, sx, sy) in [(0, hy, hx * 2, 1), (0, -hy, hx * 2, 1),
                                     (hx, 0, 1, hy * 2), (-hx, 0, 1, hy * 2)] as [(Float, Float, Float, Float)] {
                var line = XRCMath.floatArray(at * XRCMath.model(
                    translation: anchor.center + SIMD3<Float>(dx, dy, 0),
                    scale: SIMD3<Float>(sx == 1 ? 0.015 : sx, sy == 1 ? 0.015 : sy, 0.02)))
                xrc_scene_push_box(&line, color.x, color.y, color.z, 0.85)
            }

            // interior grid lines
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

        if let fy = core.floorY {
            drawFloorGrid(floorY: fy, color: SIMD4<Float>(0.30, 0.70, 1.00, 0.30))
        }
    }

    private func drawFloorGrid(floorY: Float, color: SIMD4<Float>) {
        for i in -6...6 {
            let x = Float(i) * 0.5
            var a = XRCMath.floatArray(XRCMath.model(translation: SIMD3<Float>(x, floorY + 0.004, 0),
                                                     scale: SIMD3<Float>(0.02, 0.02, 6)))
            xrc_scene_push_box(&a, color.x, color.y, color.z, color.w)
            var b = XRCMath.floatArray(XRCMath.model(translation: SIMD3<Float>(0, floorY + 0.004, x),
                                                     scale: SIMD3<Float>(6, 0.02, 0.02)))
            xrc_scene_push_box(&b, color.x, color.y, color.z, color.w)
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
                guard let a = s.joints.indices.contains(i) ? s.joints[i] : nil,
                      let b = s.joints.indices.contains(j) ? s.joints[j] : nil,
                      simd_length(a - b) > 1e-4 else { continue }
                let dir = normalize(b - a)
                let len = simd_length(b - a)
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

    // MARK: - floating settings panel (CardboardXR-style palm-summoned UI)

    /// Called from the system gestures (palm pinch / both triggers). In
    /// goggles the 2D pause overlay is unreadable, so this in-VR panel is the
    /// pause/settings surface; Phone Mode keeps the 2D overlay instead.
    func togglePanelFromGesture() {
        panelMirror.toggle()
        let v = panelMirror
        DispatchQueue.main.async { self.panelVisible = v }
    }

    private func buildPanelIfNeeded() {
        guard !panelBuilt else { return }
        let device = core.compositor.device
        let orange = UIColor(red: 0.95, green: 0.45, blue: 0.25, alpha: 1)
        let blue = UIColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 1)
        let green = UIColor(red: 0.3, green: 0.85, blue: 0.6, alpha: 1)
        let red = UIColor(red: 0.9, green: 0.3, blue: 0.35, alpha: 1)
        let purple = UIColor(red: 0.55, green: 0.35, blue: 1.0, alpha: 1)

        func make(_ action: MenuButton.Action, _ title: String, _ status: String = "", _ accent: UIColor) -> MenuButton {
            let r = PanelTextRenderer(device: device, width: 256, height: 256, style: .button)
            r.render(PanelTextRenderer.Content(title: title, statusLine: status, accent: accent))
            let b = MenuButton(action: action, renderer: r)
            b.texId = core.compositor.registerPanelTexture(r.texture)
            return b
        }

        // Custom options (iios): environment, game tuning, room, streaming.
        panelButtons = [
            make(.goHome, "Home", "", green),
            make(.startDemo, "Beat Demo", "", orange),
            make(.toggleVR, "VR Mode", vrModeMirror ? "ON" : "OFF", blue),
            make(.brightCycle, "Brightness", String(format: "%.1f", settings.ptBrightness), blue),
            make(.speedCycle, "Speed", String(format: "%.1f", settings.demoSpeed), orange),
            make(.spawnCycle, "Spawns", String(format: "%.1f", settings.demoSpawnRate), orange),
            make(.rescanRoom, "Rescan", "", blue),
            make(.toggleStream, "PC Stream", PCBridge.shared.status.label, blue),
            make(.launchWindows, "Windows", WindowsHost.shared.status.label, purple),
            make(.closePanel, "Close", "", red),
        ]
        panelBuilt = true
    }

    /// Lazily-follows the head (CardboardXR behavior): eases toward a point
    /// in front of the gaze instead of snapping, so it never swims.
    private func drawPanel(dt: Double) {
        guard panelMirror else { return }
        buildPanelIfNeeded()
        guard let headPose = core.headPose() else { return }
        let head = headPose.columns.3.xyz
        var fwd = -headPose.columns.2.xyz
        fwd.y = 0
        if simd_length(fwd) < 0.05 { fwd = SIMD3<Float>(0, 0, -1) }
        fwd = normalize(fwd)
        let floor = core.floorY ?? (head.y - 1.4)
        let desiredY = max(floor + 0.9, head.y - 0.18)
        let target = SIMD3<Float>(head.x + fwd.x * 0.62, desiredY, head.z + fwd.z * 0.62)
        let targetY = desiredY

        // lazy follow (position ease + yaw slerp)
        let alpha = Float(min(1, dt * 9))
        panelPos += (SIMD3<Float>(target.x, targetY, target.z) - panelPos) * alpha
        let want = quatFacing(normal: SIMD3<Float>(-fwd.x, -0.12, -fwd.z))
        panelFacing = simd_slerp(panelFacing, want, alpha)

        // Buttons draw with hover flags set by routeInput() (the unified
        // gaze/pinch router runs after all draws).
        let cell: Float = 0.145
        let size: Float = 0.13
        let cols = 3
        let right = simd_act(panelFacing, SIMD3<Float>(1, 0, 0))
        let up = simd_act(panelFacing, SIMD3<Float>(0, 1, 0))
        for (i, b) in panelButtons.enumerated() {
            let row = i / cols
            let col = i % cols
            let rx = (Float(col) - Float(cols - 1) * 0.5) * cell
            let ry = (Float(panelButtons.count / cols) * 0.5 - Float(row) - 0.5) * cell
            let pos = panelPos + right * rx + up * ry
            let m = XRCMath.model(translation: pos, rotation: panelFacing,
                                  scale: SIMD3<Float>(size, size, 1))
            var arr = XRCMath.floatArray(m)
            xrc_scene_push_panel(&arr, b.texId, b.hovered ? 1 : 0, 1, 1, 1, 1)
        }
    }

    /// One ray-vs-buttons pass shared by the panel and the menu bar.
    private enum ButtonLayout { case panel, bar }
    private func firstRayHit(_ buttons: [MenuButton], layout: ButtonLayout,
                             origin: SIMD3<Float>, dir: SIMD3<Float>) -> (index: Int, point: SIMD3<Float>)? {
        var best: (Int, Float, SIMD3<Float>)?
        for (i, b) in buttons.enumerated() {
            let (pos, facing, half) = layout == .panel
                ? panelButtonTransform(i, buttons: buttons)
                : barButtonTransform(i)
            // facing is a quaternion; the button's plane normal is its +Z axis.
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

    private func panelButtonTransform(_ i: Int, buttons: [MenuButton]) -> (SIMD3<Float>, simd_quatf, Float) {
        let cell: Float = 0.145
        let cols = 3
        let row = i / cols
        let col = i % cols
        let rx = (Float(col) - Float(cols - 1) * 0.5) * cell
        let ry = (Float(buttons.count / cols) * 0.5 - Float(row) - 0.5) * cell
        let pos = panelPos + simd_act(panelFacing, SIMD3<Float>(1, 0, 0)) * rx
                + simd_act(panelFacing, SIMD3<Float>(0, 1, 0)) * ry
        return (pos, panelFacing, 0.065)
    }

    private func barButtonTransform(_ i: Int) -> (SIMD3<Float>, simd_quatf, Float) {
        guard let headPose = core.headPose() else { return (SIMD3<Float>(0, 0, -1), panelFacing, 0.07) }
        let head = headPose.columns.3.xyz
        var fwd = -headPose.columns.2.xyz
        fwd.y = 0
        if simd_length(fwd) < 0.05 { fwd = SIMD3<Float>(0, 0, -1) }
        fwd = normalize(fwd)
        let floor = core.floorY ?? (head.y - 1.4)
        let barY = max(floor + 0.55, head.y - 0.34)
        let right = normalize(SIMD3<Float>(-fwd.z, 0, fwd.x))
        let spacing: Float = 0.155
        let center = head + fwd * 0.72
        var pos = center - right * (spacing * Float(menuButtons.count - 1) * 0.5) + right * (spacing * Float(i))
        pos.y = barY
        let facing = quatFacing(normal: SIMD3<Float>((head - pos).x, 0.18, (head - pos).z))
        return (pos, facing, 0.07)
    }

    // MARK: - system gesture + menu bar

    private func drawPalmIcons() {
        guard state == .home || state == .demo else { return }
        guard let headPose = core.headPose() else { return }
        let headPos = headPose.columns.3.xyz

        for h in 0..<Int(XRC_HAND_COUNT) {
            let s = core.handTracker.snapshot(for: Int32(h))
            guard s.isTracked, s.hasJoints, s.palmFlat,
                  s.joints.count == 21,
                  let thumbTip = s.joints.indices.contains(4) ? s.joints[4] : nil,
                  let indexTip = s.joints.indices.contains(8) ? s.joints[8] : nil else { continue }
            let iconPos = (thumbTip + indexTip) * 0.5
            let towardUser = normalize(headPos - iconPos)
            let m = XRCMath.model(translation: iconPos + towardUser * 0.03,
                                  rotation: quatFacing(normal: towardUser),
                                  scale: SIMD3<Float>(0.055, 0.055, 1))
            var arr = XRCMath.floatArray(m)
            xrc_scene_push_panel(&arr, palmIconTexId, 1, 1, 1, 1, 1)
        }
    }

    // MARK: - unified input router (CardboardXR PinchRouter pattern)
    //
    // Priority chain per pinch rising edge:
    //   1. palm-flat pinch  -> toggle the floating settings panel
    //   2. gazed button     -> activate (reticle marks the target)
    //   3. pointer button   -> activate (laser beam from the pointing hand)
    //   4. plain click      -> falls through (demo sabers handle contact)
    //
    // Hover: gaze ray first (primary input, like CardboardXR), pointer ray
    // second. The reticle ring marks the gaze target; the laser only appears
    // when the pointer hand is the one hovering.

    private var lastRouterPinchDown = [false, false]

    private func routeInput() {
        guard state == .home || state == .demo else {
            lastRouterPinchDown = [false, false]
            return
        }

        let active: (buttons: [MenuButton], layout: ButtonLayout)?
        if panelMirror {
            active = (panelButtons, .panel)
        } else if menuVisibleMirror, state == .home {
            active = (menuButtons, .bar)
        } else {
            active = nil
        }

        // --- hover: gaze first, pointer second ---
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
            // gaze reticle (CardboardXR): ring at the target under the crosshair
            if viaGaze, let hp = hitPoint, let headPose = core.headPose() {
                let toward = normalize(headPose.columns.3.xyz - hp)
                let m = XRCMath.model(translation: hp + toward * 0.012,
                                      rotation: quatFacing(normal: toward),
                                      scale: SIMD3<Float>(0.03, 0.03, 1))
                var arr = XRCMath.floatArray(m)
                xrc_scene_push_panel(&arr, reticleTexId, 0, 1, 1, 1, 1)
            }
        }

        // --- pinch chain ---
        for h in 0..<Int(XRC_HAND_COUNT) {
            let s = core.handTracker.snapshot(for: Int32(h))
            let down = s.isTracked && s.buttons & UInt32(XRC_BTN_TRIGGER) != 0
            let rising = down && !lastRouterPinchDown[h]
            lastRouterPinchDown[h] = down
            guard rising else { continue }

            // 1. palm gear
            if s.palmFlat {
                lastMenuToggle = CACurrentMediaTime()
                panelMirror.toggle()
                let v = panelMirror
                DispatchQueue.main.async { self.panelVisible = v }
                return
            }
            // 2/3. gazed or pointed button
            if let list = hoverList, let i = hover {
                activate(list[i].action)
                return
            }
            // 4. plain click falls through (demo contact interaction)
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

    private func buildMenuIfNeeded() {
        guard !menuBuilt else { return }

        let device = core.compositor.device
        let orange = UIColor(red: 0.95, green: 0.45, blue: 0.25, alpha: 1)
        let blue = UIColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 1)
        let green = UIColor(red: 0.3, green: 0.85, blue: 0.6, alpha: 1)
        let red = UIColor(red: 0.9, green: 0.3, blue: 0.35, alpha: 1)

        func makeButton(_ action: MenuButton.Action, title: String, status: String = "", accent: UIColor) -> MenuButton {
            let r = PanelTextRenderer(device: device, width: 256, height: 256, style: .button)
            r.render(PanelTextRenderer.Content(title: title, statusLine: status, accent: accent))
            let b = MenuButton(action: action, renderer: r)
            b.texId = core.compositor.registerPanelTexture(r.texture)
            return b
        }

        let home = makeButton(.goHome, title: "Home", accent: green)
        let demo = makeButton(.startDemo, title: "Beat Demo", accent: orange)
        let vr = makeButton(.toggleVR, title: "VR Mode", status: "OFF", accent: blue)
        let pc = makeButton(.toggleStream, title: "PC Stream", status: PCBridge.shared.status.label, accent: blue)
        let windows = makeButton(.launchWindows, title: "Windows", status: WindowsHost.shared.status.label, accent: UIColor(red: 0.55, green: 0.35, blue: 1.0, alpha: 1))
        let rescan = makeButton(.rescanRoom, title: "Rescan", accent: blue)
        let exit = makeButton(.exitVR, title: "Exit", accent: red)

        menuButtons = [home, demo, vr, pc, windows, rescan, exit]
        vrButtonIndex = 2
        streamButtonIndex = 3
        windowsButtonIndex = 4

        let icon = PanelTextRenderer(device: device, width: 128, height: 128, style: .menuIcon)
        icon.render(PanelTextRenderer.Content(title: "", accent: orange))
        palmIconTexId = core.compositor.registerPanelTexture(icon.texture)
        palmIconRenderer = icon

        let reticle = PanelTextRenderer(device: device, width: 128, height: 128, style: .reticle)
        reticle.render(PanelTextRenderer.Content(title: "", accent: UIColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 1)))
        reticleTexId = core.compositor.registerPanelTexture(reticle.texture)

        menuBuilt = true
    }

    /// Menu bar: head-relative each frame so it always stays in view
    /// (bottom of FOV, like the Quest universal menu).
    private func drawMenu(_ t: Double) {
        syncBackgroundMode()
        buildMenuIfNeeded()

        guard menuVisibleMirror else { return }
        guard let headPose = core.headPose() else { return }
        let head = headPose.columns.3.xyz
        var fwd = -headPose.columns.2.xyz
        fwd.y = 0
        if simd_length(fwd) < 0.05 { fwd = SIMD3<Float>(0, 0, -1) }
        fwd = normalize(fwd)
        let floor = core.floorY ?? (head.y - 1.4)
        let barY = max(floor + 0.55, head.y - 0.34)

        let right = normalize(SIMD3<Float>(-fwd.z, 0, fwd.x))
        let spacing: Float = 0.155
        let buttonSize: Float = 0.14
        let center = head + fwd * 0.72
        let origin = center - right * (spacing * Float(menuButtons.count - 1) * 0.5)

        for (i, button) in menuButtons.enumerated() {
            var pos = origin + right * (spacing * Float(i))
            pos.y = barY
            let towardUser = normalize(head - pos)
            let facing = quatFacing(normal: SIMD3<Float>(towardUser.x, 0.18, towardUser.z))
            let scale = button.hovered ? buttonSize * 1.12 : buttonSize
            let m = XRCMath.model(translation: pos, rotation: facing, scale: SIMD3<Float>(scale, scale, 1))
            var arr = XRCMath.floatArray(m)
            xrc_scene_push_panel(&arr, button.texId, button.hovered ? 1 : 0, 1, 1, 1, 1)
        }
    }

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
                if self.vrButtonIndex >= 0 {
                    let b = self.menuButtons[self.vrButtonIndex]
                    b.renderer.render(PanelTextRenderer.Content(
                        title: "VR Mode", statusLine: v ? "ON" : "OFF",
                        accent: UIColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 1)))
                }
            }
        case .toggleStream:
            DispatchQueue.main.async { PCBridge.shared.toggle() }
            if streamButtonIndex >= 0 {
                let b = menuButtons[streamButtonIndex]
                b.renderer.render(PanelTextRenderer.Content(
                    title: "PC Stream", statusLine: PCBridge.shared.status.label,
                    accent: UIColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 1)))
            }
        case .rescanRoom:
            DispatchQueue.main.async { self.startScan() }
        case .launchWindows:
            DispatchQueue.main.async {
                WindowsHost.shared.launch(exePath: self.settings.winExePath)
                if self.windowsButtonIndex >= 0 {
                    let b = self.menuButtons[self.windowsButtonIndex]
                    b.renderer.render(PanelTextRenderer.Content(
                        title: "Windows", statusLine: WindowsHost.shared.status.label,
                        accent: UIColor(red: 0.55, green: 0.35, blue: 1.0, alpha: 1)))
                }
            }
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
        guard let b = panelButtons.first(where: { $0.action == action }) else { return }
        let titles: [MenuButton.Action: String] = [
            .brightCycle: "Brightness", .speedCycle: "Speed", .spawnCycle: "Spawns",
        ]
        b.renderer.render(PanelTextRenderer.Content(
            title: titles[action] ?? "?", statusLine: status,
            accent: action == .brightCycle
                ? UIColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 1)
                : UIColor(red: 0.95, green: 0.45, blue: 0.25, alpha: 1)))
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
