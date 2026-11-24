import Foundation
import simd

// Swift implementations of the xrc C ABI declared in xrcore/include/xrc.h.
// Exported with @_cdecl so the symbols exist with exact C names — the demo
// game consumes the API through the bridging header exactly like a foreign
// client (the Phase 3 OpenXR shim) will.

@_cdecl("xrc_start")
public func xrc_impl_start() -> Int32 {
    guard let view = XRCore.shared.attachedView else { return Int32(XRC_ERR_NOT_READY) }
    XRCore.shared.beginSession(view: view)
    return Int32(XRC_OK)
}

@_cdecl("xrc_stop")
public func xrc_impl_stop() {
    XRCore.shared.endSession()
}

@_cdecl("xrc_is_running")
public func xrc_impl_is_running() -> Int32 {
    XRCore.shared.running ? 1 : 0
}

@_cdecl("xrc_set_paused")
public func xrc_impl_set_paused(_ paused: Int32) {
    XRCore.shared.setPaused(paused != 0)
}

@_cdecl("xrc_is_paused")
public func xrc_impl_is_paused() -> Int32 {
    XRCore.shared.paused ? 1 : 0
}

@_cdecl("xrc_get_head_pose")
public func xrc_impl_get_head_pose(_ predicted_time_s: Double, _ out_pose: UnsafeMutablePointer<xrc_pose>!) -> Int32 {
    guard let pose = XRCore.shared.headPose() else { return Int32(XRC_ERR_NOT_READY) }
    let q = simd_quatf(pose)
    out_pose.pointee = XRCMath.toXrc(position: pose.columns.3.xyz, orientation: q)
    return Int32(XRC_OK)
}

@_cdecl("xrc_get_projection")
public func xrc_impl_get_projection(_ eye: Int32, _ near_z: Float, _ far_z: Float,
                                    _ out: UnsafeMutablePointer<xrc_mat4>!) -> Int32 {
    guard XRCore.shared.running else { return Int32(XRC_ERR_NOT_READY) }
    let m = XRCore.shared.compositor.projection(eye: Int(eye), nearZ: near_z, farZ: far_z)
    withUnsafePointer(to: m) { ptr in
        // simd_float4x4 is column-major; reinterpret as 16 floats.
        ptr.withMemoryRebound(to: Float.self, capacity: 16) { floatPtr in
            for i in 0..<16 { out.pointee.m[i] = floatPtr[i] }
        }
    }
    return Int32(XRC_OK)
}

@_cdecl("xrc_get_space_from_head")
public func xrc_impl_get_space_from_head(_ space: Int32, _ predicted_time_s: Double,
                                         _ out: UnsafeMutablePointer<xrc_mat4>!) -> Int32 {
    guard let pose = XRCore.shared.headPose() else { return Int32(XRC_ERR_NOT_READY) }
    withUnsafePointer(to: pose) { ptr in
        ptr.withMemoryRebound(to: Float.self, capacity: 16) { floatPtr in
            for i in 0..<16 { out.pointee.m[i] = floatPtr[i] }
        }
    }
    return Int32(XRC_OK)
}

@_cdecl("xrc_get_controller")
public func xrc_impl_get_controller(_ hand: Int32, _ out: UnsafeMutablePointer<xrc_controller_state>!) -> Int32 {
    let idx = Int(hand)
    guard idx >= 0 && idx < XRC_HAND_COUNT else { return Int32(XRC_ERR_INVALID) }
    let snap = XRCore.shared.handTracker.snapshot(for: idx)
    let forward = -(snap.pose.columns.2.xyz)
    let q = XRCMath.quatLooking(direction: forward)
    out.pointee = xrc_controller_state(
        pose: XRCMath.toXrc(position: snap.pose.columns.3.xyz, orientation: q),
        buttons: snap.buttons,
        buttons_changed: UInt32(snap.buttons ^ snap.buttonsPrev),
        trigger: snap.trigger,
        grip: snap.grip,
        tracking_confidence: snap.confidence,
        hand_scale: snap.handScale,
        is_tracked: snap.isTracked ? 1 : 0,
        reserved: (0, 0, 0))
    return Int32(XRC_OK)
}

@_cdecl("xrc_set_mode")
public func xrc_impl_set_mode(_ mode: xrc_mode) {
    XRCore.shared.mode = mode
}

@_cdecl("xrc_get_mode")
public func xrc_impl_get_mode() -> xrc_mode {
    XRCore.shared.mode
}

@_cdecl("xrc_set_frame_callback")
public func xrc_impl_set_frame_callback(_ fn: xrc_frame_fn?, _ userdata: UnsafeMutableRawPointer?) {
    XRCore.shared.frameFn = fn
    XRCore.shared.frameUserdata = userdata
}

@_cdecl("xrc_scene_begin")
public func xrc_impl_scene_begin() {
    XRCore.shared.sceneBegin()
}

@_cdecl("xrc_scene_push_box")
public func xrc_impl_scene_push_box(_ model_col_major: UnsafePointer<Float>!, _ r: Float, _ g: Float, _ b: Float, _ a: Float) {
    XRCore.shared.scenePush(kind: .box, model: XRCMath.read(model_col_major), color: SIMD4<Float>(r, g, b, a))
}

@_cdecl("xrc_scene_push_sphere")
public func xrc_impl_scene_push_sphere(_ model_col_major: UnsafePointer<Float>!, _ r: Float, _ g: Float, _ b: Float, _ a: Float) {
    XRCore.shared.scenePush(kind: .sphere, model: XRCMath.read(model_col_major), color: SIMD4<Float>(r, g, b, a))
}

@_cdecl("xrc_scene_end")
public func xrc_impl_scene_end() {
    XRCore.shared.sceneEnd()
}

@_cdecl("xrc_get_ar_fps")
public func xrc_impl_get_ar_fps() -> Double { XRCore.shared.stats.arFps }

@_cdecl("xrc_get_hand_fps")
public func xrc_impl_get_hand_fps() -> Double { XRCore.shared.stats.handFps }

@_cdecl("xrc_get_render_fps")
public func xrc_impl_get_render_fps() -> Double { XRCore.shared.stats.renderFps }
