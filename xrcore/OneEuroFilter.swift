import Foundation

// One-Euro filter (Casiez et al. 2012) — the standard low-jitter / low-latency
// smoothing used for noisy hand-tracking input.
struct OneEuroFilter {
    var minCutoff: Float = 1.7   // lower = smoother but laggier
    var beta: Float = 0.35       // speed coefficient: raise to cut lag on fast motion
    var dCutoff: Float = 1.0

    private(set) var value: Float = 0
    private var initialized = false
    private var prevRaw: Float = 0
    private var prevDeriv: Float = 0
    private var prevTime: Double = 0

    private static func alpha(_ cutoff: Float, _ dt: Float) -> Float {
        let tau = 1 / (2 * Float.pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    private static func lowpass(_ a: Float, _ x: Float, _ prev: Float) -> Float {
        a * x + (1 - a) * prev
    }

    mutating func filter(_ x: Float, at t: Double) -> Float {
        if !initialized {
            initialized = true
            value = x
            prevRaw = x
            prevTime = t
            return x
        }
        let dt = Float(max(t - prevTime, 1e-3))
        prevTime = t
        let dx = (x - prevRaw) / dt
        let edx = Self.lowpass(Self.alpha(dCutoff, dt), dx, prevDeriv)
        prevRaw = x
        prevDeriv = edx
        let cutoff = minCutoff + beta * abs(edx)
        let a = Self.alpha(cutoff, dt)
        value = Self.lowpass(a, x, value)
        return value
    }

    mutating func reset() {
        initialized = false
        value = 0
        prevDeriv = 0
    }
}

// Three-axis wrapper for positions/directions.
struct OneEuroVec3 {
    var x = OneEuroFilter()
    var y = OneEuroFilter()
    var z = OneEuroFilter()

    mutating func filter(_ v: SIMD3<Float>, at t: Double) -> SIMD3<Float> {
        SIMD3<Float>(x.filter(v.x, at: t), y.filter(v.y, at: t), z.filter(v.z, at: t))
    }

    mutating func reset() {
        x.reset(); y.reset(); z.reset()
    }
}
