import ARKit
import Foundation
import Metal
import MetalKit
import simd

// Extension used throughout for swizzling simd_float4 -> simd_float3.
extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3<Float>(self[0], self[1], self[2]) }
}

// Compositor-facing snapshot of one hand. Written by HandTracker (hand queue),
// read by the render loop and the xrc C API.
struct ControllerSnapshot {
    var pose = matrix_identity_float4x4
    var buttons: UInt32 = 0
    var buttonsPrev: UInt32 = 0
    var trigger: Float = 0
    var grip: Float = 0
    var confidence: Float = 0
    var handScale: Float = 0
    var isTracked = false
    // 21 joint positions in HandTracker.jointOrder (zeros where missing).
    var joints: [SIMD3<Float>] = []
    var hasJoints = false
    // Palm held flat (up or down) — the Quest-style menu/pinch-indicator pose.
    var palmFlat = false
}

// Lightweight FPS meters.
struct FPSMeter {
    private(set) var fps: Double = 0
    private var last: Double = 0

    mutating func tick(_ t: Double) {
        if last > 0 {
            let dt = t - last
            if dt > 1e-4 {
                let inst = 1 / dt
                fps = fps == 0 ? inst : fps * 0.9 + inst * 0.1
            }
        }
        last = t
    }

    mutating func reset() {
        fps = 0
        last = 0
    }
}

struct RuntimeStats {
    public private(set) var arFps = 0.0
    public private(set) var handFps = 0.0
    public private(set) var renderFps = 0.0
    public private(set) var handLatencyMs = 0.0

    mutating func tickAR(_ t: Double) { arFps = tickMeter(&arMeter, t) }
    mutating func tickHand(_ t: Double, latency: Double) {
        handFps = tickMeter(&handMeter, t)
        handLatencyMs = handLatencyMs * 0.9 + latency * 100 * 0.1
    }
    mutating func tickRender(_ t: Double) { renderFps = tickMeter(&renderMeter, t) }

    mutating func reset() {
        arFps = 0; handFps = 0; renderFps = 0; handLatencyMs = 0
        arMeter.reset(); handMeter.reset(); renderMeter.reset()
    }

    private var arMeter = FPSMeter()
    private var handMeter = FPSMeter()
    private var renderMeter = FPSMeter()
    private func tickMeter(_ m: inout FPSMeter, _ t: Double) -> Double {
        m.tick(t)
        return m.fps
    }
}

// Notification posted when the runtime toggles pause (both-triggers gesture
// or the UI). The SwiftUI shell listens and swaps to the menu overlay.
extension Notification.Name {
    static let xrcPauseToggled = Notification.Name("iios.pauseToggled")
    static let xrcSessionEnded = Notification.Name("iios.sessionEnded")
}

// XRCore — the heart of the runtime: owns the ARKit session, the Metal
// compositor and the hand tracker, and drives the frame loop:
//
//   grab latest ARFrame -> predict head pose -> sceneBegin ->
//   C frame callback (games push items) -> sceneEnd ->
//   encode passthrough -> encode scene -> encode distortion/timewarp -> present
@objc
final class XRCore: NSObject {

    static let shared = XRCore()

    let settings = XRSettings.shared
    let compositor = Compositor()
    let handTracker = HandTracker()
    let stats = RuntimeStatsHolder()

    private(set) var running = false
    private(set) var paused = false
    var mode: xrc_mode = XRC_MODE_VR

    private(set) weak var attachedView: MTKView?
    private let session = ARSession()
    private var sessionRunning = false

    // Latest AR frames (guarded by frameLock). prevFrame powers the cheap
    // rotational prediction used by timewarp.
    private let frameLock = NSLock()
    private var latestFrame: ARFrame?
    private var prevFrame: ARFrame?

    // C frame callback (xrc_set_frame_callback).
    var frameFn: xrc_frame_fn?
    var frameUserdata: UnsafeMutableRawPointer?

    // Scene items collected between xrc_scene_begin()/xrc_scene_end(). Only
    // touched from the render thread (the C API is documented render-thread-only).
    struct SceneItem {
        var kind: MeshKind
        var model: simd_float4x4
        var color: SIMD4<Float>
        var texIndex: Int32
        var glow: Float
    }
    private(set) var sceneItems: [SceneItem] = []
    private var sceneCollecting = false

    private var lastPauseToggle = 0.0

    // --- room sensing (Quest-style Space Setup equivalent) ---
    // Discovered surfaces from ARKit plane detection; floorY anchors the home
    // environment. Restored ARWorldMap anchors reappear through didAdd too.
    private let anchorLock = NSLock()
    private var horizontalPlanes: [ARPlaneAnchor] = []
    private var verticalPlanes: [ARPlaneAnchor] = []
    private(set) var worldMapRestored = false

    /// Y of the detected floor in world space (nil until a floor is found or
    /// restored). Home environment sits on this plane.
    var floorY: Float? {
        anchorLock.withLock {
            horizontalPlanes.map { $0.transform.columns.3.y }.min()
        }
    }

    var planeCounts: (horizontal: Int, vertical: Int) {
        anchorLock.withLock { (horizontalPlanes.count, verticalPlanes.count) }
    }

    /// Detected plane summaries for scan visualization (render thread).
    var planeAnchors: [(anchor: ARPlaneAnchor, vertical: Bool)] {
        anchorLock.withLock {
            horizontalPlanes.map { ($0, false) } + verticalPlanes.map { ($0, true) }
        }
    }

    // MARK: lifecycle

    func attachView(_ view: MTKView) {
        attachedView = view
    }

    func beginSession(view: MTKView) {
        guard !running else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            NotificationCenter.default.post(name: .xrcSessionEnded, object: nil)
            return
        }

        compositor.attach(view: view)
        view.delegate = self
        view.isPaused = false

        anchorLock.withLock {
            horizontalPlanes.removeAll()
            verticalPlanes.removeAll()
        }
        worldMapRestored = false

        session.delegate = self
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        // Room sensing: surfaces for the home environment + scan flow.
        config.planeDetection = [.horizontal, .vertical]
        // Quest-style persistence: restore the saved room scan so the home
        // lands in the same place every launch without re-scanning.
        if let map = RoomStore.shared.load() {
            config.initialWorldMap = map
        }
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        sessionRunning = true

        handTracker.reset()
        stats.reset()
        running = true
        paused = false
    }

    func endSession() {
        guard running else { return }
        running = false
        if sessionRunning {
            session.pause()
            sessionRunning = false
        }
        attachedView?.isPaused = true
        NotificationCenter.default.post(name: .xrcSessionEnded, object: nil)
    }

    func setPaused(_ p: Bool) {
        guard paused != p else { return }
        paused = p
        attachedView?.isPaused = p
        if p { handTracker.reset() }
        NotificationCenter.default.post(name: .xrcPauseToggled, object: nil)
    }

    // MARK: state accessors

    func headPose() -> simd_float4x4? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return latestFrame?.camera.transform
    }

    /// Persists the current room scan (Quest-style Space Setup).
    func saveRoomMap(completion: ((Bool) -> Void)? = nil) {
        RoomStore.shared.save(session, completion: completion)
    }

    func clearRoomMap() {
        RoomStore.shared.clear()
    }

    /// Pose + timestamp of the last two AR frames, for prediction.
    func headPosePair() -> (a: simd_float4x4, ta: Double, b: simd_float4x4, tb: Double)? {
        frameLock.lock()
        defer { frameLock.unlock() }
        guard let cur = latestFrame else { return nil }
        let a = prevFrame?.camera.transform ?? cur.camera.transform
        let ta = prevFrame?.timestamp ?? cur.timestamp
        return (a, ta, cur.camera.transform, cur.timestamp)
    }

    // MARK: scene collection (render thread only)

    func sceneBegin() {
        sceneCollecting = true
        sceneItems.removeAll(keepingCapacity: true)
    }

    func scenePush(kind: MeshKind, model: simd_float4x4, color: SIMD4<Float>, texIndex: Int32, glow: Float = 0) {
        guard sceneCollecting else { return }
        sceneItems.append(SceneItem(kind: kind, model: model, color: color, texIndex: texIndex, glow: glow))
    }

    func sceneEnd() {
        sceneCollecting = false
    }
}

// MARK: - stats holder (published to the HUD)

final class RuntimeStatsHolder {
    private var s = RuntimeStats()
    private let lock = NSLock()

    var arFps: Double { lock.withLock { s.arFps } }
    var handFps: Double { lock.withLock { s.handFps } }
    var renderFps: Double { lock.withLock { s.renderFps } }
    var handLatencyMs: Double { lock.withLock { s.handLatencyMs } }

    func tickAR(_ t: Double) { lock.withLock { s.tickAR(t) } }
    func tickHand(_ t: Double, latency: Double) { lock.withLock { s.tickHand(t, latency: latency) } }
    func tickRender(_ t: Double) { lock.withLock { s.tickRender(t) } }
    func reset() { lock.withLock { s.reset() } }
}

extension NSLock {
    @inline(__always) func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

// MARK: - ARSessionDelegate

extension XRCore: ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameLock.lock()
        prevFrame = latestFrame
        latestFrame = frame
        frameLock.unlock()

        stats.tickAR(frame.timestamp)
        // Hand tracking on its own queue so Vision latency never stalls ARKit.
        handTracker.process(frame: frame, settings: settings) { [weak self] t, latency in
            self?.stats.tickHand(t, latency: latency)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        // Tracking hard-failed (camera permission denied, sensor error).
        endSession()
    }

    // MARK: room sensing (plane anchors)

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let planes = anchors.compactMap { $0 as? ARPlaneAnchor }
        guard !planes.isEmpty else { return }
        anchorLock.withLock {
            for p in planes {
                if p.alignment == .horizontal {
                    if !horizontalPlanes.contains(where: { $0.identifier == p.identifier }) {
                        horizontalPlanes.append(p)
                    }
                } else if !verticalPlanes.contains(where: { $0.identifier == p.identifier }) {
                    verticalPlanes.append(p)
                }
            }
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let planes = anchors.compactMap { $0 as? ARPlaneAnchor }
        anchorLock.withLock {
            for p in planes {
                if let i = horizontalPlanes.firstIndex(where: { $0.identifier == p.identifier }) {
                    horizontalPlanes[i] = p
                } else if let i = verticalPlanes.firstIndex(where: { $0.identifier == p.identifier }) {
                    verticalPlanes[i] = p
                }
            }
        }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let ids = Set(anchors.compactMap { $0 as? ARPlaneAnchor }.map { $0.identifier })
        guard !ids.isEmpty else { return }
        anchorLock.withLock {
            horizontalPlanes.removeAll { ids.contains($0.identifier) }
            verticalPlanes.removeAll { ids.contains($0.identifier) }
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        // Leave running; SwiftUI shows the menu overlay and the user resumes.
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }
}

// MARK: - MTKViewDelegate (the frame loop)

extension XRCore: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        compositor.resize(to: size)
    }

    func draw(in view: MTKView) {
        guard running, !paused else { return }

        frameLock.lock()
        let frame = latestFrame
        frameLock.unlock()
        guard let frame = frame else { return }

        stats.tickRender(CACurrentMediaTime())

        // --- predicted head pose (rotational only; timewarp compensates) ---
        let pair = headPosePair()
        let displayTime = frame.timestamp + 1.0 / 120.0
        let predictedHead: simd_float4x4
        if settings.timewarp, let pair = pair {
            predictedHead = XRCMath.extrapolate(pair.a, at: pair.ta, pair.b, at: pair.tb, to: displayTime)
        } else {
            predictedHead = frame.camera.transform
        }

        // --- collect scene items from clients ---
        sceneBegin()
        if let fn = frameFn {
            fn(frameUserdata, displayTime)
        }
        sceneEnd()

        // --- pause gesture: both triggers held (debounced) ---
        let l = handTracker.snapshot(for: Int32(XRC_HAND_LEFT))
        let r = handTracker.snapshot(for: Int32(XRC_HAND_RIGHT))
        let bothTriggers = l.buttons & UInt32(XRC_BTN_TRIGGER) != 0 && r.buttons & UInt32(XRC_BTN_TRIGGER) != 0
        let now = CACurrentMediaTime()
        if bothTriggers, now - lastPauseToggle > 0.8 {
            lastPauseToggle = now
            DispatchQueue.main.async { [weak self] in
                self?.setPaused(!(self?.paused ?? false))
            }
        }

        // --- render ---
        compositor.encodeFrame(
            view: view,
            arFrame: frame,
            predictedHead: predictedHead,
            items: sceneItems,
            joints: handTracker.debugJoints(),
            jointsActive: settings.showJoints)
    }
}
