import ARKit
import Foundation
import ImageIO
import simd
import Vision

// HandTracker — converts Vision hand-pose output into Quest-style virtual
// controllers.
//
// Pipeline (on a serial queue, ~30 Hz):
//   ARFrame.capturedImage -> VNDetectHumanHandPoseRequest (21 joints, 2 hands)
//   -> Vision normalized (bottom-left origin, oriented image)
//   -> buffer-normalized coords (orientation-corrected)
//   -> monocular unprojection: camera ray through joint, distance from
//      apparent wrist->middle-MCP span vs. the known ~9.5 cm physical span
//   -> One-Euro filtering of wrist position, palm-forward direction, distance
//   -> controller pose (-Z along palm-forward), analog trigger/grip from
//      normalized pinch/curl ratios, digital buttons with thresholds
//
// All positions are planar approximations: every joint of a hand gets the
// same depth. This is the honest limit of monocular tracking — see
// docs/LIMITATIONS.md.
final class HandTracker {

    private let handQueue = DispatchQueue(label: "dev.iios.handtracking", qos: .userInteractive)
    private let lock = NSLock()
    // Coalescing flag: only one Vision pass may be in flight at a time.
    private let busyLock = NSLock()
    private var busyFlag = false

    private var snapshots: [ControllerSnapshot] = [ControllerSnapshot(), ControllerSnapshot()]
    private var debugPoints: [SIMD2<Float>] = []

    // Per-hand filter state. Index 0 = left, 1 = right.
    private struct HandFilterState {
        var wristPos = OneEuroVec3()
        var forward = OneEuroVec3()
        var distance = OneEuroFilter()
        var triggerAnalog = OneEuroFilter()
        var gripAnalog = OneEuroFilter()
        var primaryAnalog = OneEuroFilter()
        var lastSeen: Double = 0
        var wasTracked = false
    }
    private var filters: [HandFilterState] = [HandFilterState(), HandFilterState()]

    // Physical reference: wrist -> middle-MCP knuckle ≈ 9.5 cm for adults.
    private static let refSpanMeters: Float = 0.095
    private static let refSpanMetersVarianceTolerance: Float = 2.2 // accept kids->big hands

    private static let minDistance: Float = 0.15
    private static let maxDistance: Float = 0.70

    // Canonical joint order for skeleton data (indices into snapshot.joints).
    static let jointOrder: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]
    private static let jointIndex: [VNHumanHandPoseObservation.JointName: Int] = {
        var d: [VNHumanHandPoseObservation.JointName: Int] = [:]
        for (i, n) in jointOrder.enumerated() { d[n] = i }
        return d
    }()

    /// Bone connectivity for the wireframe overlay (index pairs into jointOrder).
    static let bonePairs: [(Int, Int)] = [
        // thumb
        (0, 1), (1, 2), (2, 3), (3, 4),
        // index
        (0, 5), (5, 6), (6, 7), (7, 8),
        // middle
        (0, 9), (9, 10), (10, 11), (11, 12),
        // ring
        (0, 13), (13, 14), (14, 15), (15, 16),
        // little
        (0, 17), (17, 18), (18, 19), (19, 20),
        // knuckle web
        (5, 9), (9, 13), (13, 17),
    ]

    // MARK: - entry point

    /// Called from the ARSession delegate; hops to the hand queue and returns
    /// immediately. `completion` (timestamp seconds, latency seconds) reports
    /// throughput for the stats HUD.
    ///
    /// CRITICAL: submissions are coalesced — if the previous Vision pass is
    /// still running, the frame is dropped. Without this, a 20ms Vision pass
    /// at 60fps ARKit arrival grows the queue without bound (the source of a
    /// memory-exhaustion crash). Vision also runs at half the AR rate.
    private var visionFrameCounter = 0

    func process(frame: ARFrame, settings: XRSettings, completion: @escaping (Double, Double) -> Void) {
        // Half rate: hand pose at ~30 Hz is plenty (and saves thermal budget).
        visionFrameCounter &+= 1
        if visionFrameCounter % 2 == 0 { return }

        busyLock.lock()
        if busyFlag {
            busyLock.unlock()
            return // previous Vision pass still running -> drop this frame
        }
        busyFlag = true
        busyLock.unlock()

        handQueue.async { [weak self] in
            defer {
                self?.busyLock.lock()
                self?.busyFlag = false
                self?.busyLock.unlock()
            }
            guard let self = self else { return }
            let start = CACurrentMediaTime()
            self.update(frame: frame, settings: settings)
            completion(frame.timestamp, CACurrentMediaTime() - start)
        }
    }

    func snapshot(for hand: Int32) -> ControllerSnapshot {
        lock.withLock {
            guard hand >= 0 && Int(hand) < snapshots.count else { return ControllerSnapshot() }
            return snapshots[Int(hand)]
        }
    }

    /// Buffer-normalized 2D joint points for the passthrough debug overlay.
    func debugJoints() -> [SIMD2<Float>] {
        lock.withLock { debugPoints }
    }

    func reset() {
        lock.withLock {
            snapshots = [ControllerSnapshot(), ControllerSnapshot()]
            debugPoints = []
        }
        handQueue.async { [weak self] in
            guard let self = self else { return }
            self.filters = [HandFilterState(), HandFilterState()]
        }
    }

    // MARK: - core update (hand queue)

    private func update(frame: ARFrame, settings: XRSettings) {
        let t = frame.timestamp

        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        let orientation = CGImagePropertyOrientation(rawValue: UInt32(settings.visionOrient)) ?? .right
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage, orientation: orientation, options: [:])

        var observations: [VNHumanHandPoseObservation] = []
        do {
            try handler.perform([request])
            observations = request.results ?? []
        } catch {
            observations = []
        }

        // Visual handedness: rear camera is not mirrored, so physical left
        // appears on the buffer's left. Sort observations by wrist buffer-x.
        // Hand observations use recognizedPoints(.all); keys are the
        // strongly-typed VNHumanHandPoseObservation.JointName constants.
        struct HandObs {
            var joints: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint] // top-left norm in buffer space
            var centroidX: Float
            var confidence: Float
        }

        let intr = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let fx = intr[0][0], fy = intr[1][1]
        let cx = intr[2][0], cy = intr[2][1]
        let camTransform = frame.camera.transform
        let camPos = camTransform.columns.3.xyz

        func toBufferNorm(_ p: CGPoint) -> SIMD2<Float> {
            // Vision locations: normalized, origin bottom-left of oriented image.
            let up = SIMD2<Float>(Float(p.x), 1 - Float(p.y))
            // Orientation-correct into RAW buffer normalized coords (top-left origin).
            switch orientation {
            case .up: return up
            case .right: return SIMD2<Float>(up.y, 1 - up.x)
            case .down: return SIMD2<Float>(1 - up.x, 1 - up.y)
            case .left: return SIMD2<Float>(1 - up.y, up.x)
            default: return up
            }
        }

        func rayDir(_ bn: SIMD2<Float>) -> SIMD3<Float> {
            let px = Float(bn.x) * Float(res.width)
            let py = Float(bn.y) * Float(res.height)
            let d = SIMD3<Float>((px - cx) / fx, -(py - cy) / fy, -1)
            // Camera space (+X right, +Y up, -Z forward) -> world.
            return normalize((camTransform * SIMD4<Float>(d.x, d.y, d.z, 0)).xyz)
        }

        var hands: [HandObs] = []
        for obs in observations {
            guard obs.confidence > 0.2, let jointsRaw = try? obs.recognizedPoints(.all) else { continue }
            var joints: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint] = [:]
            var sumX: Float = 0
            var count = 0
            var minConf: Float = 1
            for (name, pt) in jointsRaw where pt.confidence > 0.1 {
                joints[name] = pt
                sumX += toBufferNorm(pt.location).x
                count += 1
                minConf = min(minConf, pt.confidence)
            }
            guard count >= 15, let w = joints[.wrist] else { continue }
            hands.append(HandObs(joints: joints,
                                 centroidX: toBufferNorm(w.location).x,
                                 confidence: minConf))
        }

        // Assign to left/right slots.
        var assigned: [HandObs?] = [nil, nil]
        if hands.count >= 2 {
            let sorted = hands.sorted { $0.centroidX < $1.centroidX }
            assigned[0] = sorted[0] // left
            assigned[1] = sorted[1] // right
        } else if hands.count == 1 {
            let side = hands[0].centroidX < 0.5 ? 0 : 1
            assigned[side] = hands[0]
        }

        let baseSnaps = lock.withLock { snapshots }
        var newSnaps = baseSnaps
        var jointsDebug: [SIMD2<Float>] = []

        for (slot, handObs) in assigned.enumerated() {
            var st = filters[slot]

            guard let obs = handObs else {
                if t - st.lastSeen > 0.4 {
                    st.wristPos.reset(); st.forward.reset(); st.distance.reset()
                    st.triggerAnalog.reset(); st.gripAnalog.reset(); st.primaryAnalog.reset()
                    st.wasTracked = false
                }
                st.lastSeen = t
                filters[slot] = st
                var s = newSnaps[slot]
                s.buttonsPrev = s.buttons
                s.buttons = 0
                s.trigger = 0; s.grip = 0; s.confidence = 0
                s.isTracked = false
                newSnaps[slot] = s
                continue
            }

            let j = obs.joints
            func bn(_ name: VNHumanHandPoseObservation.JointName) -> SIMD2<Float> {
                j[name].map { toBufferNorm($0.location) } ?? SIMD2<Float>(0, 0)
            }
            func px(_ name: VNHumanHandPoseObservation.JointName) -> SIMD2<Float> {
                bn(name) * SIMD2<Float>(Float(res.width), Float(res.height))
            }
            func dir(_ name: VNHumanHandPoseObservation.JointName) -> SIMD3<Float> {
                rayDir(bn(name))
            }

            // distance from apparent span (pinhole): dist = f * realSpan / spanPx
            let wristPx = px(.wrist)
            let midPx = px(.middleMCP)
            let spanPx = max(simd_length(midPx - wristPx), 1)
            let rawDist = (fx * HandTracker.refSpanMeters / spanPx)
            guard rawDist >= HandTracker.minDistance * 0.5,
                  rawDist <= HandTracker.maxDistance * HandTracker.refSpanMetersVarianceTolerance else {
                // Implausible distance — treat as lost.
                var s = newSnaps[slot]
                s.buttonsPrev = s.buttons
                s.buttons = 0
                s.isTracked = false
                newSnaps[slot] = s
                st.lastSeen = t
                filters[slot] = st
                continue
            }

            let dist = clampF(st.distance.filter(rawDist, at: t),
                              HandTracker.minDistance, HandTracker.maxDistance)

            // 3D joints (planar approximation: shared depth) — all 21 for the
            // skeleton overlay + palm pose.
            var joints3D = [SIMD3<Float>](repeating: .zero, count: HandTracker.jointOrder.count)
            for (name, pt) in j {
                guard let idx = HandTracker.jointIndex[name] else { continue }
                joints3D[idx] = camPos + dir(name) * dist
            }
            let wrist3 = joints3D[0]
            let indexMCP3 = joints3D[5]
            let littleMCP3 = joints3D[17]
            let middleMCP3 = joints3D[9]

            // Palm-flat pose (palm facing up or down, fingers roughly
            // horizontal) — shows the pinch indicator and arms the menu
            // gesture, like the Quest system gesture.
            let palmSpanVec = indexMCP3 - littleMCP3
            let fingersUp = normalize(middleMCP3 - wrist3)
            let palmNormal = normalize(cross(palmSpanVec, middleMCP3 - wrist3))
            let palmFlat = abs(palmNormal.y) > 0.5 && abs(fingersUp.y) < 0.6

            // Palm-forward direction: wrist -> middle knuckle, smoothed.
            let rawForward = normalize(middleMCP3 - wrist3)
            let forward = normalize(st.forward.filter(rawForward, at: t))
            let wrist = st.wristPos.filter(wrist3, at: t)

            // Analog inputs: isotropic pixel-space ratios normalized by the span.
            let pinchIdx = simd_length(px(.thumbTip) - px(.indexTip)) / spanPx
            let pinchMid = simd_length(px(.thumbTip) - px(.middleTip)) / spanPx
            let curlMid = simd_length(px(.middleTip) - wristPx) / spanPx

            let triggerRaw = analogDown(raw: pinchIdx, lo: Float(settings.pinchThresh), hi: Float(settings.pinchThresh) * 1.9)
            let primaryRaw = analogDown(raw: pinchMid, lo: Float(settings.pinchThresh) * 1.15, hi: Float(settings.pinchThresh) * 2.1)
            // curl: extended middle tip ≈ 2.2 spans from wrist, curled ≈ 1.0
            let gripRaw = analogUp(raw: curlMid, lo: 1.0, hi: 2.0)

            let trigger = st.triggerAnalog.filter(triggerRaw, at: t)
            let primary = st.primaryAnalog.filter(primaryRaw, at: t)
            let grip = st.gripAnalog.filter(gripRaw, at: t)

            var buttons: UInt32 = 0
            if trigger > 0.5 { buttons |= UInt32(XRC_BTN_TRIGGER) }
            if grip > 0.5 { buttons |= UInt32(XRC_BTN_GRIP) }
            if primary > 0.5 { buttons |= UInt32(XRC_BTN_PRIMARY) }

            // Persist filter state BEFORE storing it back.
            st.lastSeen = t
            st.wasTracked = true
            filters[slot] = st

            var s = newSnaps[slot]
            s.buttonsPrev = s.buttons
            s.buttons = buttons
            s.trigger = clampF(trigger, 0, 1)
            s.grip = clampF(grip, 0, 1)
            s.confidence = obs.confidence
            s.handScale = dist
            s.isTracked = true
            s.palmFlat = palmFlat
            s.joints = joints3D
            s.hasJoints = true
            s.pose = XRCMath.model(translation: wrist, rotation: XRCMath.quatLooking(direction: forward))
            newSnaps[slot] = s

            if jointsDebug.count < 42 {
                for (_, pt) in j {
                    jointsDebug.append(toBufferNorm(pt.location))
                }
            }
        }

        lock.withLock {
            snapshots = newSnaps
            debugPoints = jointsDebug
        }
    }

    /// Normalized distance shrinks toward `lo` as the pinch closes -> 1 at
    /// `lo`, 0 at `hi`.
    private func analogDown(raw: Float, lo: Float, hi: Float) -> Float {
        1 - clampF((raw - lo) / (hi - lo), 0, 1)
    }

    /// Extent grows toward `hi` -> 1 at `lo` (curled), 0 at `hi` (extended).
    private func analogUp(raw: Float, lo: Float, hi: Float) -> Float {
        1 - clampF((raw - lo) / (hi - lo), 0, 1)
    }
}
