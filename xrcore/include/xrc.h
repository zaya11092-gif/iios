// xrc.h — iios stable C ABI for XR clients (native games, and the Phase 3
// Windows/OpenXR shim).
//
// Conventions (OpenXR-like):
//   * Right-handed world space, +Y up at session start (ARKit gravity alignment).
//   * Orientation quaternions are (x, y, z, w); -Z is "forward" for a posed
//     object (i.e. forward = -(q * (0,0,1))).
//   * Matrices are column-major, 16 floats, compatible with Metal/SIMD.
//   * All coordinates are in meters.
//
// Threading: all functions may be called from any thread; the runtime
// synchronizes internally. Renderers must push scene items between
// xrc_scene_begin()/xrc_scene_end() and must do so from the frame callback
// (see xrc_set_frame_callback).
//
// Phase-1 note: the scene API exposes push-style primitives (boxes/spheres).
// A full per-eye swapchain surface for native renderers lands with the
// Phase 3 shim path.

#ifndef XRC_H
#define XRC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- types -----------------------------------------------------------------

typedef enum xrc_result {
    XRC_OK = 0,
    XRC_ERR_NOT_READY = 1,
    XRC_ERR_INVALID = 2,
} xrc_result;

typedef struct xrc_vec3 { float x, y, z; } xrc_vec3;
typedef struct xrc_quat { float x, y, z, w; } xrc_quat;
typedef struct xrc_pose { xrc_vec3 position; xrc_quat orientation; } xrc_pose;

// column-major 4x4
typedef struct xrc_mat4 { float m[16]; } xrc_mat4;

enum {
    XRC_BTN_TRIGGER = 1 << 0,
    XRC_BTN_GRIP    = 1 << 1,
    XRC_BTN_PRIMARY = 1 << 2,   // thumb-to-middle pinch ("A"/"X")
    XRC_BTN_MENU    = 1 << 3,   // both triggers held (runtime gesture)
};

enum {
    XRC_HAND_LEFT = 0,
    XRC_HAND_RIGHT = 1,
    XRC_HAND_COUNT = 2,
};

enum {
    XRC_SPACE_LOCAL = 0,        // gravity-aligned space at session start
    XRC_SPACE_STAGE = 1,        // reserved (Phase 2+)
};

enum {
    XRC_EYE_LEFT = 0,
    XRC_EYE_RIGHT = 1,
};

typedef enum xrc_mode {
    XRC_MODE_VR = 0,            // dark background (immersive)
    XRC_MODE_AR = 1,            // camera passthrough background
} xrc_mode;

typedef struct xrc_controller_state {
    xrc_pose pose;              // -Z forward; saber tip ≈ pose.position + forward * 0.30
    uint32_t buttons;           // current button bits
    uint32_t buttons_changed;   // bits that changed since previous frame
    float trigger;              // 0..1 (index pinch)
    float grip;                 // 0..1 (finger curl)
    float tracking_confidence;  // 0..1 hand-pose confidence
    float hand_scale;           // apparent hand span in meters (pinhole estimate)
    uint8_t is_tracked;
    uint8_t reserved[3];
} xrc_controller_state;

// ---- lifecycle -------------------------------------------------------------

// Starts the runtime against the view currently attached by the host app.
// Returns XRC_ERR_NOT_READY when no view/ARSession is attached (the SwiftUI
// host calls XRCore.beginSession(view:) directly; this entry exists for the
// Phase 3 shim host).
xrc_result xrc_start(void);
void xrc_stop(void);
int xrc_is_running(void);

// Pause AR processing (menu open). Rendering keeps presenting the last frame.
void xrc_set_paused(int paused);
int xrc_is_paused(void);

// ---- poses -----------------------------------------------------------------

// Head (device) pose in world space. predicted_time_s may be the expected
// display time; Phase 1 returns the latest tracked pose (timewarp compensates).
xrc_result xrc_get_head_pose(double predicted_time_s, xrc_pose *out_pose);

// Projection matrix matching the compositor's calibrated FOV for `eye`.
// Games MUST use this so content lines up with the lens distortion pass.
xrc_result xrc_get_projection(int eye, float near_z, float far_z, xrc_mat4 *out);

// Head-to-world matrix (column-major) for XRC_SPACE_LOCAL.
xrc_result xrc_get_space_from_head(int space, double predicted_time_s, xrc_mat4 *out);

// ---- controllers -----------------------------------------------------------

// hand: XRC_HAND_LEFT / XRC_HAND_RIGHT. Returns 0 and clears state when the
// hand is not tracked this frame.
int xrc_get_controller(int hand, xrc_controller_state *out);

// ---- mode ------------------------------------------------------------------

void xrc_set_mode(xrc_mode mode);
xrc_mode xrc_get_mode(void);

// ---- frame loop ------------------------------------------------------------

// Registered once. Called every compositor frame AFTER head/controller state
// is updated for the frame; push scene items inside the callback.
typedef void (*xrc_frame_fn)(void *userdata, double predicted_display_time);
void xrc_set_frame_callback(xrc_frame_fn fn, void *userdata);

// ---- scene items -----------------------------------------------------------

void xrc_scene_begin(void);
void xrc_scene_push_box(const float *model_col_major, float r, float g, float b, float a);
void xrc_scene_push_sphere(const float *model_col_major, float r, float g, float b, float a);
void xrc_scene_end(void);

// ---- diagnostics -----------------------------------------------------------

double xrc_get_ar_fps(void);      // ARKit frame rate
double xrc_get_hand_fps(void);    // hand-tracking update rate
double xrc_get_render_fps(void);  // compositor frame rate

#ifdef __cplusplus
}
#endif

#endif // XRC_H
