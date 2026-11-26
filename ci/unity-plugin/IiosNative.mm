// IiosNative.mm — the Unity-facing half of the iios native layer. Compiled as
// a static lib by the unity-ipa workflow and force-linked into UnityFramework;
// implements the C ABI from windows/host-bridge/ios_bridge.h.
//
// Phase-3 status: standalone fallback path works (ARKit head tracking via its
// own ARSession). When the full iios runtime is linked alongside (host vtable
// present), head/hand data delegate to it and SteamVR frame submission routes
// into the Metal compositor (see docs/UNITY-STEAMVR.md).

#import <UIKit/UIKit.h>
#import <ARKit/ARKit.h>
#include <dlfcn.h>
#include <simd/simd.h>
#include "../../windows/host-bridge/ios_bridge.h"

static ARSession *g_session = nil;
static NSObject *g_lock = nil;

// Host vtable (Swift side). Absent in the pure-Unity build → fallback path.
static ios_host_vtable *g_host = nil;

static void loadHost(void) {
    if (g_host) return;
    // Resolve the host vtable pointer from the main executable when the full
    // iios runtime is linked alongside Unity. Absent otherwise.
    void *sym = dlsym(RTLD_MAIN_ONLY, "ios_host_vtable_ptr");
    if (sym) {
        g_host = *(ios_host_vtable **)sym;
    }
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

    loadHost();
    if (g_host && g_host->get_head_pose) {
        g_host->get_head_pose(t, out);
        return;
    }
    @synchronized (g_lock) {
        if (g_session) {
            simd_float4x4 tf = g_session.currentFrame.camera.transform;
            out->pos[0] = (float)tf.columns[3][0];
            out->pos[1] = (float)tf.columns[3][1];
            out->pos[2] = (float)tf.columns[3][2];
            simd_float3x3 r3 = simd_matrix(tf.columns[0].xyz, tf.columns[1].xyz, tf.columns[2].xyz);
            simd_quatf q = simd_quatf(r3);
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
    loadHost();
    if (g_host && g_host->get_controller) {
        g_host->get_controller(hand, t, out);
    }
    // Fallback (no host runtime): untracked — Unity shows default controllers.
}

int32_t iios_submit_frame(double displayTime) {
    loadHost();
    if (g_host && g_host->submit_frame) {
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
