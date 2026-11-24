import simd

// Scalar clamp (Swift has no stdlib scalar clamp; simd_clamp is vector-only).
@inline(__always)
func clampF(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
    min(max(v, lo), hi)
}

// Math helpers shared by the runtime and the demo game.
enum XRCMath {

    /// Right-handed perspective projection looking down -Z (Metal clip space,
    /// z in [0,1]).
    static func perspective(fovYDeg: Float, aspect: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
        let fovy = fovYDeg * .pi / 180
        let f = 1 / tan(fovy * 0.5)
        let nf = 1 / (nearZ - farZ)
        var m = matrix_identity_float4x4
        m.columns.0 = simd_float4(f / aspect, 0, 0, 0)
        m.columns.1 = simd_float4(0, f, 0, 0)
        m.columns.2 = simd_float4(0, 0, farZ * nf, -1)
        m.columns.3 = simd_float4(0, 0, farZ * nearZ * nf, 0)
        return m
    }

    /// Perspective from a horizontal FOV (the way lens FOV is usually quoted).
    static func perspectiveX(fovXDeg: Float, aspect: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
        let fovY = 2 * atan(tan(fovXDeg * .pi / 180 * 0.5) / aspect) * 180 / .pi
        return perspective(fovYDeg: fovY, aspect: aspect, nearZ: nearZ, farZ: farZ)
    }

    /// Rotation quaternion aligning an object's -Z axis to `direction`
    /// (roll-free, world-up reference). Convention: forward = -(q * (0,0,1)).
    static func quatLooking(direction: SIMD3<Float>) -> simd_quatf {
        let f = normalize(direction)
        var up = SIMD3<Float>(0, 1, 0)
        if abs(dot(f, up)) > 0.99 { up = SIMD3<Float>(0, 0, 1) }
        let right = normalize(cross(up, f))
        let up2 = cross(f, right)
        // Column-major basis: X=right, Y=up2, Z=-f (camera-style -Z forward)
        let m = simd_float4x4(simd_float4(right.x, right.y, right.z, 0),
                              simd_float4(up2.x, up2.y, up2.z, 0),
                              simd_float4(-f.x, -f.y, -f.z, 0),
                              simd_float4(0, 0, 0, 1))
        return simd_quatf(m)
    }

    /// Translation * rotation * scale matrix.
    static func model(translation: SIMD3<Float>, rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                      scale: SIMD3<Float> = SIMD3<Float>(repeating: 1)) -> simd_float4x4 {
        let t = matrix_identity_float4x4
        let rs = simd_float4x4(rotation) * simd_float4x4(diagonal: SIMD4<Float>(scale.x, scale.y, scale.z, 1))
        var m = t * rs
        m.columns.3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        return m
    }

    /// Writes a simd_float4x4 as 16 column-major floats (xrc_mat4 layout).
    static func write(_ m: simd_float4x4, into out: UnsafeMutablePointer<Float>) {
        for c in 0..<4 {
            let col = m[c]
            for r in 0..<4 {
                out[c * 4 + r] = col[r]
            }
        }
    }

    /// Reads 16 column-major floats into a simd matrix.
    static func read(_ src: UnsafePointer<Float>) -> simd_float4x4 {
        func col(_ c: Int) -> simd_float4 {
            simd_float4(src[c * 4], src[c * 4 + 1], src[c * 4 + 2], src[c * 4 + 3])
        }
        return simd_float4x4(col(0), col(1), col(2), col(3))
    }

    /// simd matrix -> 16-float column-major array for xrc_* C calls.
    static func floatArray(_ m: simd_float4x4) -> [Float] {
        var a = [Float](repeating: 0, count: 16)
        a.withUnsafeMutableBufferPointer { buf in
            if let base = buf.baseAddress {
                write(m, into: base)
            }
        }
        return a
    }

    /// xrc_pose -> simd model matrix.
    static func fromXrc(_ p: xrc_pose) -> simd_float4x4 {
        let q = simd_quatf(vector: SIMD4<Float>(p.orientation.x, p.orientation.y, p.orientation.z, p.orientation.w))
        return model(translation: SIMD3<Float>(p.position.x, p.position.y, p.position.z), rotation: q)
    }

    static func toXrc(_ v: SIMD3<Float>) -> xrc_vec3 { xrc_vec3(x: v.x, y: v.y, z: v.z) }
    static func toXrc(_ q: simd_quatf) -> xrc_quat { xrc_quat(x: q.vector.x, y: q.vector.y, z: q.vector.z, w: q.vector.w) }

    static func toXrc(position: SIMD3<Float>, orientation: simd_quatf) -> xrc_pose {
        xrc_pose(position: toXrc(position), orientation: toXrc(orientation))
    }

    /// View matrix from a camera pose (inverse of the camera model matrix).
    static func viewFromPose(_ pose: simd_float4x4) -> simd_float4x4 {
        pose.inverse
    }

    /// Linear extrapolation of two poses (rotation via slerp). Used to build a
    /// cheap predicted head pose for rotational timewarp.
    static func extrapolate(_ a: simd_float4x4, at ta: Double, _ b: simd_float4x4, at tb: Double, to t: Double) -> simd_float4x4 {
        let span = tb - ta
        guard span > 1e-6 else { return b }
        let alpha = Float((t - tb) / span)
        let qa = simd_quatf(a), qb = simd_quatf(b)
        // Rotation: slerp clamped (no overshoot); position extrapolates freely.
        let q = simd_slerp(qa, qb, min(max(alpha, 0), 1))
        let pa = SIMD3<Float>(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        let pb = SIMD3<Float>(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        let p = pb + (pb - pa) * alpha
        var m = simd_float4x4(q)
        m.columns.3 = SIMD4<Float>(p.x, p.y, p.z, 1)
        return m
    }
}
