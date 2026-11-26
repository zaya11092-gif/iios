// IiosNative.mm — the Unity-facing half of the iios native layer. Linked into
// UnityFramework by the post-export injection; implements the C ABI from
// windows/host-bridge/ios_bridge.h. Backed by the same XRCore runtime that
// backs the OpenXR shim (one runtime, two frontends).
//
// Phase-3 status: ARKit head tracking + Vision hand tracking feed these
// functions via the shared runtime; SteamVR frame submission routes into the
// Metal compositor through swapchain handles once the FEX/Wine/DXMT layer
// links (see docs/UNITY-STEAMVR.md).

#import <UIKit/UIKit.h>
#import <ARKit/ARKit.h>
#import <Vision/Vision.h>
#include "../../windows/host-bridge/ios_bridge.h"

static ARSession *g_session = nil;
static simd_float4x4 g_lastHead = {0};
static NSTimeInterval g_lastHeadTime = 0;
static NSObject *g_lock = nil;

// Swift host vtable — exported from the app executable (XRCAPI.swift /
// WindowsHost.swift). When present, the native layer delegates to the full
// iios runtime; otherwise it falls back to a raw ARSession here.
static ios_host_vtable *g_host = nil;

static void loadHost(void) {
    if (g_host) return;
    Class cls = NSClassFromString(@"UnityFramework");
    (void)cls;
    // The host vtable lives in the main executable; resolve via dlsym.
    g_host = (ios_host_vtable *)dlsym(RTLD_MAIN_ONLY, "ios_host_vtable_ptr");
}

extern "C" {

void iios_session_start(void) {
    if (g_lock == nil) g_lock = [[NSObject alloc] init];
    @synchronized (g_lock) {
        if (g_session) return;
        g_session = [[ARSession alloc] init];
        ARWorldTrackingConfiguration *cfg = [ARWorldTrackingConfiguration new];
        cfg.worldAlignment = ARWorldAlignmentGravity;
        [g_session runConfiguration:cfg options:ARSessionRunOptionResetTracking |
                                                   ARSessionRunOptionRemoveExistingAnchors];
    }
}

void iios_session_stop(void) {
    @synchronized (g_lock) {
        [g_session pause];
        g_session = nil;
    }
}

void iios_head_pose(double t, ios_pose *out) {
    if (!out) return;
    memset(out, 0, sizeof(ios_pose));
    out->quat[3] = 1.0f;

    if (loadHost() && g_host && g_host->get_head_pose) {
        g_host->get_head_pose(t, out);
        return;
    }
    @synchronized (g_lock) {
        if (g_session) {
            simd_float4x4 tf = g_session.currentFrame.camera.transform;
            out->pos[0] = tf.columns[3][0];
            out->pos[1] = tf.columns[3][1];
            out->pos[2] = tf.columns[3][2];
            simd_quatf q = simd_quatf(tf);
            out->quat[0] = q.vector.x;
            out->quat[1] = q.vector.y;
            out->quat[2] = q.vector.z;
            out->quat[3] = q.vector.w;
        }
    }
}

void iios_controller(int32_t hand, double t, ios_controller *out) {
    if (!out) return;
    memset(out, 0, sizeof(ios_controller));
    if (loadHost() && g_host && g_host->get_controller) {
        g_host->get_controller(hand, t, out);
    }
    // Fallback (no host runtime): untracked — Unity shows default controllers.
}

int32_t iios_submit_frame(double displayTime) {
    if (loadHost() && g_host && g_host->submit_frame) {
        uint64_t eyes[2] = {0, 0};
        ios_pose headViews[2];
        for (int i = 0; i < 2; i++) {
            memset(&headViews[i], 0, sizeof(ios_pose));
            headViews[i].quat[3] = 1.0f;
        }
        return g_host->submit_frame(displayTime, eyes, headViews);
    }
    return 0;
}

int32_t iios_is_tracked(void) {
    return g_session != nil ? 1 : 0;
}

} // extern "C"
