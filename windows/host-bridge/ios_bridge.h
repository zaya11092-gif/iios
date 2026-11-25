// ios_bridge.h — ABI between the OpenXR shim (running inside Wine/FEX on the
// device) and the iios host runtime (Swift/XRCore, same process — Madeira
// runs everything in one iOS app process; this is threads + function
// pointers, not IPC).
//
// Handoff mechanism: the shim locates the host vtable via
//   GetProcAddress(GetModuleHandleW(NULL), "ios_host_get_vtable")
// (the main executable exports it), then calls through the table. Everything
// is C, little-endian, arm64 native calling convention.
//
// Coordinate conventions match xrc.h: right-handed, +Y up at start,
// quaternions (x,y,z,w), -Z forward, meters.
#ifndef IOS_BRIDGE_H
#define IOS_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define IOS_BRIDGE_VERSION 1

typedef struct ios_pose {
    float pos[3];       // x, y, z (world space)
    float quat[4];      // x, y, z, w
} ios_pose;

typedef struct ios_controller {
    ios_pose pose;
    uint32_t buttons;   // bit0 trigger, bit1 grip, bit2 primary(A), bit3 menu
    float trigger;      // 0..1
    float grip;         // 0..1
    uint8_t tracked;
    uint8_t reserved[3];
} ios_controller;

// v1 function table. Host fills every pointer; guest checks non-NULL before
// calling. All calls may come from Wine render threads; the host
// synchronizes internally.
typedef struct ios_host_vtable {
    uint32_t version;

    // Predicted pose for display time `t` (seconds, guest clock ≈ host clock).
    void (*get_head_pose)(double t, ios_pose *out);
    void (*get_controller)(int32_t hand /*0 L, 1 R*/, double t, ios_controller *out);

    // Swapchain image management. The shim asks the host to create the
    // per-eye image sets (host allocates Metal textures compatible with
    // DXMT's Metal layer via its texture registry) and receives back an
    // opaque image handle per index, plus the number of images.
    // `intended_width/height` are per eye.
    int32_t (*create_swapchain)(uint32_t intended_width, uint32_t intended_height,
                                uint32_t *out_image_count, uint64_t *out_handles /*[8]*/);
    // Guest acquires the next free image; returns image index or -1.
    int32_t (*acquire_swapchain_image)(int32_t swapchain_id);
    // Guest finished rendering this index (content valid).
    void (*release_swapchain_image)(int32_t swapchain_id, uint32_t index);

    // Frame submission (xrEndFrame). `eye_handles[2]` = image handles the
    // guest rendered this frame; host composites them with distortion +
    // timewarp. Returns 0 on success.
    int32_t (*submit_frame)(double display_time,
                            const uint64_t eye_handles[2],
                            const ios_pose head_view[2] /* per-eye view poses */);

    // Session lifecycle from the app side (focus, exit request).
    void (*request_exit)(void);

    // Info
    void (*get_eye_render_size)(uint32_t *out_w, uint32_t *out_h);
} ios_host_vtable;

// Exported by the HOST main executable (Swift @_cdecl in WindowsHost.swift).
typedef const ios_host_vtable *(*ios_host_get_vtable_fn)(void);

#ifdef __cplusplus
}
#endif
#endif // IOS_BRIDGE_H
