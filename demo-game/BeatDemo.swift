import Foundation
import simd

// BeatDemo — beat-saber-lite: cubes fly toward the player; slash them with the
// saber matching their color (left hand = red targets, right hand = blue).
//
// Deliberately written against the raw xrc C ABI (via the bridging header) so
// it exercises exactly the surface the Phase 3 OpenXR shim will use.

final class BeatDemo {

    static let shared = BeatDemo()

    struct Cube {
        var pos: SIMD3<Float>
        var dir: SIMD3<Float>       // flight direction (unit)
        var rotation: simd_quatf    // faces the player at spawn
        var isLeftColor: Bool
        var alive = true
        var traveled: Float = 0
    }

    // HUD-facing state (read by HudOverlay).
    private(set) var score = 0
    private(set) var combo = 0
    private(set) var bestCombo = 0
    private(set) var misses = 0
    private(set) var cubeCount = 0

    private var cubes: [Cube] = []
    private var spawnTimer: Double = 0
    private var lastTime: Double = 0
    private var lastTips: [SIMD3<Float>?] = [nil, nil]
    private var hitFlash: Double = 0

    private var active = false

    private var settings: XRSettings { XRSettings.shared }

    // MARK: lifecycle

    // XRHome owns the xrc frame callback and routes it here in demo state.
    func activate() {
        active = true
        cubes.removeAll()
        score = 0; combo = 0; bestCombo = 0; misses = 0
        lastTime = 0
        spawnTimer = 0.5
        lastTips = [nil, nil]
    }

    func deactivate() {
        active = false
    }

    // MARK: frame (render thread, invoked by XRHome)

    func frame(_ predictedTime: Double) {
        guard active else { return }
        let dt = lastTime == 0 ? 1.0 / 60.0 : min(max(predictedTime - lastTime, 0.001), 0.1)
        lastTime = predictedTime

        var headPose = xrc_pose()
        guard xrc_get_head_pose(predictedTime, &headPose) == XRC_OK else { return }
        let head = XRCMath.fromXrc(headPose)
        let headPos = head.columns.3.xyz
        let headForward = -head.columns.2.xyz

        // --- controllers through the C ABI ---
        var ctrl: [xrc_controller_state] = [xrc_controller_state(), xrc_controller_state()]
        for h in 0..<Int(XRC_HAND_COUNT) {
            _ = xrc_get_controller(Int32(h), &ctrl[h])
        }

        // --- spawn ---
        spawnTimer -= dt
        if spawnTimer <= 0 {
            spawnTimer = 1.0 / max(Double(settings.demoSpawnRate), 0.2)
            spawnCube(headPos: headPos, headForward: headForward)
        }

        // --- update cubes ---
        let speed = Float(1.2 * settings.demoSpeed)
        for i in cubes.indices where cubes[i].alive {
            let step = cubes[i].dir * speed * Float(dt)
            cubes[i].pos += step
            cubes[i].traveled += simd_length(step)
            // reached the player -> miss
            if simd_distance(cubes[i].pos, headPos) < 0.18 {
                cubes[i].alive = false
                misses += 1
                combo = 0
            } else if cubes[i].traveled > 4.5 {
                cubes[i].alive = false
            }
        }

        // --- saber collision ---
        let reach = Float(settings.reachMeters)
        for h in 0..<Int(XRC_HAND_COUNT) {
            let c = ctrl[h]
            guard c.is_tracked != 0 else {
                lastTips[h] = nil
                continue
            }
            let pose = XRCMath.fromXrc(c.pose)
            let tip = pose.columns.3.xyz + (-pose.columns.2.xyz) * reach
            defer { lastTips[h] = tip }

            guard let prev = lastTips[h] else { continue }
            let isLeftSaber = h == Int(XRC_HAND_LEFT)
            for i in cubes.indices where cubes[i].alive {
                if segmentHit(a: prev, b: tip, point: cubes[i].pos, radius: 0.13) {
                    cubes[i].alive = false
                    if cubes[i].isLeftColor == isLeftSaber {
                        score += 1 + min(combo, 10)
                        combo += 1
                        bestCombo = max(bestCombo, combo)
                        hitFlash = 0.25
                    } else {
                        misses += 1
                        combo = 0
                    }
                }
            }
        }
        cubes.removeAll { !$0.alive }
        cubeCount = cubes.count
        if hitFlash > 0 { hitFlash -= dt }

        // --- draw through the scene API ---
        xrc_scene_begin()

        let leftColor = SIMD4<Float>(1.0, 0.25, 0.25, 1)
        let rightColor = SIMD4<Float>(0.3, 0.5, 1.0, 1)
        for cube in cubes {
            let s: Float = 0.16
            let m = XRCMath.model(translation: cube.pos, rotation: cube.rotation, scale: SIMD3<Float>(repeating: s))
            let c = cube.isLeftColor ? leftColor : rightColor
            var arr = XRCMath.floatArray(m)
            xrc_scene_push_box(&arr, c.x, c.y, c.z, c.w)
            // thin white outline slab behind each cube for depth legibility
            let back = cube.pos + cube.dir * 0.09
            let m2 = XRCMath.model(translation: back, rotation: cube.rotation, scale: SIMD3<Float>(s * 0.6, s * 0.6, 0.02))
            var arr2 = XRCMath.floatArray(m2)
            xrc_scene_push_box(&arr2, 1, 1, 1, 1)
        }

        // sabers + wrist markers
        let saberColors: [SIMD4<Float>] = [SIMD4<Float>(0.2, 1.0, 0.3, 1), SIMD4<Float>(1.0, 0.7, 0.2, 1)]
        for h in 0..<Int(XRC_HAND_COUNT) where ctrl[h].is_tracked != 0 {
            let pose = XRCMath.fromXrc(ctrl[h].pose)
            let glowOn = ctrl[h].buttons & UInt32(XRC_BTN_TRIGGER) != 0
            let glow: Float = glowOn ? 1.6 : 1.0
            let c = saberColors[h] * glow
            // blade: box stretched along -Z of the controller pose
            let mid = pose.columns.3.xyz + (-pose.columns.2.xyz) * (reach * 0.5)
            let bladeM = XRCMath.model(translation: mid, rotation: simd_quatf(pose),
                                       scale: SIMD3<Float>(0.022, 0.022, reach))
            var bArr = XRCMath.floatArray(bladeM)
            xrc_scene_push_box(&bArr, c.x, c.y, c.z, 1)
            // wrist ball
            let ballM = XRCMath.model(translation: pose.columns.3.xyz, scale: SIMD3<Float>(repeating: 0.03))
            var sArr = XRCMath.floatArray(ballM)
            xrc_scene_push_sphere(&sArr, c.x * 0.7, c.y * 0.7, c.z * 0.7, 1)
        }

        // simple ground grid hint so cubes are judgeable against a floor
        let floorY = XRCore.shared.floorY ?? (headPos.y - 1.5)
        let gridColor = SIMD4<Float>(0.25, 0.25, 0.3, 1)
        for i in -4...4 {
            let x = Float(i) * 0.5
            let mLine = XRCMath.model(translation: SIMD3<Float>(x, floorY + 0.003, headPos.z - 3.0),
                                      scale: SIMD3<Float>(0.02, 0.02, 6))
            var la = XRCMath.floatArray(mLine)
            xrc_scene_push_box(&la, gridColor.x, gridColor.y, gridColor.z, 1)
        }

        xrc_scene_end()
    }

    // MARK: helpers

    private func spawnCube(headPos: SIMD3<Float>, headForward: SIMD3<Float>) {
        let lateral = Float.random(in: -0.55...0.55)
        let vertical = headPos.y + Float.random(in: -0.15...0.35)
        var fwd = normalize(SIMD3<Float>(headForward.x, 0, headForward.z))
        if !fwd.x.isFinite || simd_length(fwd) < 0.1 { fwd = SIMD3<Float>(0, 0, -1) }
        let right = SIMD3<Float>(-fwd.z, 0, fwd.x)
        let spawn = headPos + fwd * 2.6 + right * lateral
        let target = SIMD3<Float>(headPos.x, vertical, headPos.z)
        let dir = normalize(target - spawn)
        let facing = XRCMath.quatLooking(direction: normalize(headPos - spawn))
        let isLeft = Bool.random()
        cubes.append(Cube(pos: SIMD3<Float>(spawn.x, vertical, spawn.z),
                          dir: dir,
                          rotation: facing,
                          isLeftColor: isLeft))
    }

    /// Segment (a-b) vs. sphere (point, radius).
    private func segmentHit(a: SIMD3<Float>, b: SIMD3<Float>, point: SIMD3<Float>, radius: Float) -> Bool {
        let ab = b - a
        let t = clampF(simd_dot(point - a, ab) / max(simd_dot(ab, ab), 1e-6), 0, 1)
        let closest = a + ab * t
        return simd_distance(closest, point) < radius
    }
}
