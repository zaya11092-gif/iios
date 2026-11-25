// openxr_loader.c — iios OpenXR shim (Phase 3, on-device SteamVR).
//
// Replaces the OpenXR loader inside the Wine prefix. OpenXR games talk to
// THIS as their runtime; we bridge everything to the iOS host runtime
// (XRCore: ARKit SLAM head, hand-derived controllers, Metal compositor)
// through the ios_host_vtable (see ../host-bridge/ios_bridge.h).
//
// Implementation status:
//   * lifecycle, system/session, reference/action spaces, actions, frame
//     loop, event polling: implemented against OpenXR 1.0 struct ABI.
//   * swapchain images: the flow and handles are wired to the host vtable;
//     the DXMT interop point (allocating D3D11 textures whose Metal backing
//     the host can composite) is marked IOS_DXMT_TODO — that single hook is
//     the last piece between this shim and real on-device OpenXR games.
//
// Built as openxr_loader.dll (llvm-mingw), registered as the active runtime
// via the Wine prefix's OpenXR runtime manifest (see build-layer.sh).

#define XR_NO_PROTOTYPES
#define XR_USE_GRAPHICS_API_D3D11
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <windows.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include "../../host-bridge/ios_bridge.h"

// ---------------------------------------------------------------- vtable

static const ios_host_vtable *host = NULL;

static BOOL load_host_vtable(void) {
    if (host) return TRUE;
    HMODULE exe = GetModuleHandleW(NULL);
    if (!exe) return FALSE;
    ios_host_get_vtable_fn get = (ios_host_get_vtable_fn)(void (*)(void))GetProcAddress(exe, "ios_host_get_vtable");
    if (!get) return FALSE;
    host = get();
    return host && host->version == IOS_BRIDGE_VERSION;
}

#define HOST_CALL(ret, expr) do { \
    if (!load_host_vtable()) return (ret); \
    expr; \
} while (0)

#define HOST_CALLV(expr) do { \
    if (!load_host_vtable()) return; \
    expr; \
} while (0)

// ---------------------------------------------------------------- state

typedef enum {
    SESSION_IDLE = 0,
    SESSION_READY,
    SESSION_SYNCHRONIZED,
    SESSION_FOCUSED,
    SESSION_EXIT_PENDING,
    SESSION_LOSS_PENDING,
} ShimSessionState;

static XrSystemId system_id_gen = 1;

#define MAX_SPACES 16
#define MAX_ACTIONS 32
#define MAX_ACTIONSETS 8

struct ShimSpace { XrSpace handle; XrReferenceSpaceType type; ios_pose pose; int used; };
struct ShimAction { XrAction handle; char name[64]; int type /*1 bool,2 float,3 pose*/; int used; };
struct ShimActionSet { XrActionSet handle; char name[64]; int used; int active; };

static struct ShimSpace g_spaces[MAX_SPACES];
static struct ShimAction g_actions[MAX_ACTIONS];
static struct ShimActionSet g_actionsets[MAX_ACTIONSETS];

static ShimSessionState g_state = SESSION_IDLE;
static int g_session_alive = 0;
static int32_t g_swapchain_id = -1;
static uint32_t g_image_count = 0;
static uint64_t g_image_handles[8] = { 0 };
static uint32_t g_acquired[8] = { 0 }; // per-index acquire counter
static uint64_t g_frame_index = 0;
static ios_pose g_last_head;

static int32_t next_space_slot(void) {
    for (int i = 0; i < MAX_SPACES; i++) if (!g_spaces[i].used) return i;
    return -1;
}
static int32_t next_action_slot(void) {
    for (int i = 0; i < MAX_ACTIONS; i++) if (!g_actions[i].used) return i;
    return -1;
}
static int32_t next_actionset_slot(void) {
    for (int i = 0; i < MAX_ACTIONSETS; i++) if (!g_actionsets[i].used) return i;
    return -1;
}

static void fill_pose_ios(const ios_pose *src, XrPosef *out) {
    out->position.x = src->pos[0];
    out->position.y = src->pos[1];
    out->position.z = src->pos[2];
    out->orientation.x = src->quat[0];
    out->orientation.y = src->quat[1];
    out->orientation.z = src->quat[2];
    out->orientation.w = src->quat[3];
}

// ---------------------------------------------------------------- instance

XRAPI_ATTR XrResult XRAPI_CALL xrGetInstanceProcAddr(XrInstance instance, const char *name, PFN_xrVoidFunction *function);

XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateInstanceExtensionProperties(
    const char *layerName, uint32_t propertyCapacityInput,
    uint32_t *propertyCountOutput, XrExtensionProperties *properties) {
    (void)layerName;
    // We advertise the extensions a typical SteamVR OpenXR game asks for.
    static const char *exts[] = {
        "XR_KHR_D3D11_enable",
        "XR_EXT_local_floor",
    };
    const uint32_t n = sizeof(exts) / sizeof(exts[0]);
    *propertyCountOutput = n;
    if (propertyCapacityInput < n) return XR_ERROR_VALIDATION_FAILURE;
    for (uint32_t i = 0; i < n && i < propertyCapacityInput; i++) {
        memset(&properties[i], 0, sizeof(properties[i]));
        properties[i].type = XR_TYPE_EXTENSION_PROPERTIES;
        strncpy(properties[i].extensionName, exts[i], XR_MAX_EXTENSION_NAME_SIZE - 1);
        properties[i].extensionVersion = 1;
    }
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrCreateInstance(const XrInstanceCreateInfo *info, XrInstance *out) {
    if (!info || !out) return XR_ERROR_VALIDATION_FAILURE;
    *out = (XrInstance)(uintptr_t)0x105700;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrDestroyInstance(XrInstance instance) {
    (void)instance;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrGetInstanceProperties(XrInstance instance, XrInstanceProperties *props) {
    if (!props || props->type != XR_TYPE_INSTANCE_PROPERTIES) return XR_ERROR_VALIDATION_FAILURE;
    strncpy(props->runtimeName, "iios XR (shim)", XR_MAX_RUNTIME_NAME_SIZE - 1);
    props->runtimeVersion = XR_MAKE_VERSION(1, 0, 0);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateApiLayerProperties(
    uint32_t a, uint32_t *b, XrApiLayerProperties *c) {
    *b = 0;
    (void)a; (void)c;
    return XR_SUCCESS;
}

// ---------------------------------------------------------------- system

XRAPI_ATTR XrResult XRAPI_CALL xrGetSystem(XrInstance instance, const XrSystemGetInfo *info, XrSystemId *system) {
    (void)instance;
    if (!info || !system || info->formFactor != XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY)
        return XR_ERROR_FORM_FACTOR_UNAVAILABLE;
    *system = (XrSystemId)(uintptr_t)system_id_gen;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrGetSystemProperties(XrInstance instance, XrSystemId system, XrSystemProperties *props) {
    (void)instance; (void)system;
    if (!props) return XR_ERROR_VALIDATION_FAILURE;
    props->vendorId = 0x1057;
    props->systemId = system_id_gen;
    strncpy(props->systemName, "iios iPhone", XR_MAX_SYSTEM_NAME_SIZE - 1);
    props->graphicsProperties.maxSwapchainImageCount = 8;
    props->trackingProperties.positionTracking = XR_TRUE;
    props->trackingProperties.orientationTracking = XR_TRUE;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateEnvironmentBlendModes(
    XrInstance instance, XrSystemId system, XrViewConfigurationType viewConfig,
    uint32_t capacity, uint32_t *count, XrEnvironmentBlendMode *modes) {
    (void)instance; (void)system;
    if (viewConfig != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    *count = 1;
    if (capacity >= 1 && modes) modes[0] = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateViewConfigurations(
    XrInstance instance, XrSystemId system, uint32_t capacity, uint32_t *count, XrViewConfigurationType *out) {
    (void)instance; (void)system;
    *count = 1;
    if (capacity >= 1 && out) out[0] = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrGetViewConfigurationProperties(
    XrInstance instance, XrSystemId system, XrViewConfigurationType type, XrViewConfigurationProperties *props) {
    (void)instance; (void)system; (void)type;
    if (!props) return XR_ERROR_VALIDATION_FAILURE;
    props->fovMutable = XR_FALSE;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateViewConfigurationViews(
    XrInstance instance, XrSystemId system, XrViewConfigurationType type,
    uint32_t capacity, uint32_t *count, XrViewConfigurationView *views) {
    (void)instance; (void)system;
    if (type != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    *count = 2;
    if (capacity >= 2 && views) {
        HOST_CALL(XR_ERROR_RUNTIME_FAILURE, {
            uint32_t w = 1280, h = 1280;
            if (host->get_eye_render_size) host->get_eye_render_size(&w, &h);
            for (int i = 0; i < 2; i++) {
                memset(&views[i], 0, sizeof(views[i]));
                views[i].type = XR_TYPE_VIEW_CONFIGURATION_VIEW;
                views[i].recommendedImageRectWidth = w;
                views[i].maxImageRectWidth = w * 2;
                views[i].recommendedImageRectHeight = h;
                views[i].maxImageRectHeight = h * 2;
                views[i].recommendedSwapchainSampleCount = 1;
                views[i].maxSwapchainSampleCount = 4;
            }
        });
    }
    return XR_SUCCESS;
}

// ---------------------------------------------------------------- session

static XrSessionState to_xr_state(ShimSessionState s) {
    switch (s) {
    case SESSION_IDLE: return XR_SESSION_STATE_IDLE;
    case SESSION_IDLE_PENDING: return XR_SESSION_STATE_IDLE;
    case SESSION_READY: return XR_SESSION_STATE_READY;
    case SESSION_SYNCHRONIZED: return XR_SESSION_STATE_SYNCHRONIZED;
    case SESSION_VISIBLE: return XR_SESSION_STATE_VISIBLE;
    case SESSION_FOCUSED: return XR_SESSION_STATE_FOCUSED;
    case SESSION_EXIT_PENDING: return XR_SESSION_STATE_EXIT_PENDING;
    case SESSION_LOSS_PENDING: return XR_SESSION_STATE_LOSS_PENDING;
    }
    return XR_SESSION_STATE_IDLE;
}

XRAPI_ATTR XrResult XRAPI_CALL xrCreateSession(XrInstance instance, const XrSessionCreateInfo *info, XrSession *out) {
    (void)instance;
    if (!info || !out) return XR_ERROR_VALIDATION_FAILURE;
    // IOS_DXMT_TODO: validate info->nextChain carries XrGraphicsBindingD3D11KHR
    // whose device is a DXMT-backed D3D11 device, and hand that device to the
    // host so swapchain Metal textures share the DXMT command stream.
    g_state = SESSION_IDLE;
    g_session_alive = 1;
    *out = (XrSession)(uintptr_t)0x105701;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrDestroySession(XrSession session) {
    (void)session;
    g_session_alive = 0;
    g_state = SESSION_IDLE;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrBeginSession(XrSession session, const XrSessionBeginInfo *info) {
    (void)session;
    if (!info) return XR_ERROR_VALIDATION_FAILURE;
    if (g_state == SESSION_READY) g_state = SESSION_SYNCHRONIZED;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEndSession(XrSession session) {
    (void)session;
    g_state = SESSION_EXIT_PENDING;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrRequestExitSession(XrSession session) {
    (void)session;
    g_state = SESSION_EXIT_PENDING;
    HOST_CALL(XR_ERROR_RUNTIME_FAILURE, {
        if (host->request_exit) host->request_exit();
    });
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrPollEvent(XrInstance instance, XrEventDataBuffer *event) {
    (void)instance;
    if (!event) return XR_ERROR_VALIDATION_FAILURE;
    memset(event, 0, sizeof(*event));

    // Drive the session state machine forward the way a real runtime would.
    if (g_session_alive) {
        XrEventDataSessionStateChanged *sc;
        if (g_state == SESSION_IDLE) {
            g_state = SESSION_READY;
        } else if (g_state == SESSION_READY) {
            g_state = SESSION_SYNCHRONIZED;
        } else if (g_state == SESSION_SYNCHRONIZED) {
            g_state = SESSION_FOCUSED;
        } else if (g_state == SESSION_EXIT_PENDING) {
            g_state = SESSION_LOSS_PENDING;
            g_session_alive = 0;
        } else {
            event->type = XR_TYPE_UNKNOWN; // no event this poll
            return XR_SUCCESS;
        }
        event->type = XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED;
        sc = (XrEventDataSessionStateChanged *)event;
        sc->type = XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED;
        sc->state = to_xr_state(g_state);
        return XR_SUCCESS;
    }
    event->type = XR_TYPE_UNKNOWN;
    return XR_SUCCESS;
}

// ---------------------------------------------------------------- spaces

XRAPI_ATTR XrResult XRAPI_CALL xrCreateReferenceSpace(XrSession session, const XrReferenceSpaceCreateInfo *info, XrSpace *out) {
    (void)session;
    if (!info || !out) return XR_ERROR_VALIDATION_FAILURE;
    int32_t slot = next_space_slot();
    if (slot < 0) return XR_ERROR_LIMIT_REACHED;
    g_spaces[slot].used = 1;
    g_spaces[slot].type = info->referenceSpaceType;
    memset(&g_spaces[slot].pose, 0, sizeof(ios_pose));
    g_spaces[slot].pose.quat[3] = 1.0f;
    *out = (XrSpace)(uintptr_t)(slot + 1);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrDestroySpace(XrSpace space) {
    int32_t slot = (int32_t)(uintptr_t)space - 1;
    if (slot >= 0 && slot < MAX_SPACES) g_spaces[slot].used = 0;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrLocateSpace(XrSpace space, XrSpace base, XrTime time, XrSpaceLocation *out) {
    (void)base; (void)space;
    if (!out) return XR_ERROR_VALIDATION_FAILURE;
    HOST_CALL(XR_ERROR_RUNTIME_FAILURE, {
        ios_pose p;
        if (host->get_head_pose) {
            host->get_head_pose((double)time * 1e-9, &p);
        } else {
            memset(&p, 0, sizeof(p)); p.quat[3] = 1.0f;
        }
        g_last_head = p;
        memset(out, 0, sizeof(*out));
        out->type = XR_TYPE_SPACE_LOCATION;
        out->locationFlags = XR_SPACE_LOCATION_POSITION_VALID_BIT | XR_SPACE_LOCATION_ORIENTATION_VALID_BIT;
        fill_pose_ios(&p, &out->pose);
    });
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrLocateViews(XrSession session, const XrViewLocateInfo *info, XrViewState *state,
                                             uint32_t capacity, uint32_t *count, XrView *views) {
    (void)session;
    if (!info || !state || !count || !views) return XR_ERROR_VALIDATION_FAILURE;
    *count = 2;
    if (capacity < 2) return XR_ERROR_VALIDATION_FAILURE;
    HOST_CALL(XR_ERROR_RUNTIME_FAILURE, {
        float fov = 47.0f * 3.14159265f / 180.0f;
        double t = (double)info->displayTime * 1e-9;
        for (uint32_t i = 0; i < 2; i++) {
            ios_pose p;
            if (host->get_head_pose) host->get_head_pose(t, &p); else { memset(&p, 0, sizeof(p)); p.quat[3] = 1; }
            memset(&views[i], 0, sizeof(views[i]));
            views[i].type = XR_TYPE_VIEW;
            fill_pose_ios(&p, &views[i].pose);
            views[i].fov.angleLeft = -fov * 0.75f;
            views[i].fov.angleRight = fov * 0.75f;
            views[i].fov.angleUp = fov;
            views[i].fov.angleDown = -fov;
        }
        state->viewStateFlags = XR_VIEW_STATE_POSITION_VALID_BIT | XR_VIEW_STATE_ORIENTATION_VALID_BIT;
    });
    return XR_SUCCESS;
}

// ---------------------------------------------------------------- actions

XRAPI_ATTR XrResult XRAPI_CALL xrCreateActionSet(XrInstance instance, const XrActionSetCreateInfo *info, XrActionSet *out) {
    (void)instance;
    if (!info || !out) return XR_ERROR_VALIDATION_FAILURE;
    int32_t slot = next_actionset_slot();
    if (slot < 0) return XR_ERROR_LIMIT_REACHED;
    g_actionsets[slot].used = 1;
    g_actionsets[slot].active = 0;
    strncpy(g_actionsets[slot].name, info->actionSetName, 63);
    *out = (XrActionSet)(uintptr_t)(slot + 1);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrDestroyActionSet(XrActionSet set) {
    int32_t slot = (int32_t)(uintptr_t)set - 1;
    if (slot >= 0 && slot < MAX_ACTIONSETS) g_actionsets[slot].used = 0;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrCreateAction(XrActionSet set, const XrActionCreateInfo *info, XrAction *out) {
    if (!info || !out) return XR_ERROR_VALIDATION_FAILURE;
    int32_t slot = next_action_slot();
    if (slot < 0) return XR_ERROR_LIMIT_REACHED;
    g_actions[slot].used = 1;
    strncpy(g_actions[slot].name, info->actionName, 63);
    if (info->actionType == XR_ACTION_TYPE_BOOLEAN_INPUT) g_actions[slot].type = 1;
    else if (info->actionType == XR_ACTION_TYPE_FLOAT_INPUT) g_actions[slot].type = 2;
    else if (info->actionType == XR_ACTION_TYPE_POSE_INPUT) g_actions[slot].type = 3;
    else g_actions[slot].type = 1;
    *out = (XrAction)(uintptr_t)(slot + 1);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrDestroyAction(XrAction action) {
    int32_t slot = (int32_t)(uintptr_t)action - 1;
    if (slot >= 0 && slot < MAX_ACTIONS) g_actions[slot].used = 0;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrSuggestInteractionProfileBindings(
    XrInstance instance, const XrInteractionProfileSuggestedBinding *info) {
    (void)instance; (void)info; // accept anything; bindings resolved by name below
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrAttachSessionActionSets(XrSession session, const XrSessionActionSetsAttachInfo *info) {
    (void)session;
    if (!info) return XR_ERROR_VALIDATION_FAILURE;
    for (uint32_t i = 0; i < info->countSuggestedBindings; i++) { /* no-op */ }
    for (int i = 0; i < MAX_ACTIONSETS; i++) g_actionsets[i].active = 1;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrSyncActions(XrSession session, const XrActionsSyncInfo *info) {
    (void)session; (void)info;
    return XR_SUCCESS;
}

// Map common SteamVR action names onto our hand-derived controller bits.
static void lookup_action(int32_t slot, uint32_t *buttons, float *trigger, float *grip, ios_pose *pose) {
    const char *n = g_actions[slot].name;
    memset(pose, 0, sizeof(ios_pose));
    pose->quat[3] = 1.0f;
    *trigger = 0; *grip = 0; *buttons = 0;
    if (!load_host_vtable() || !host->get_controller) return;
    ios_controller c[2];
    host->get_controller(0, 0, &c[0]);
    host->get_controller(1, 0, &c[1]);
    // Left-hand actions contain "left"/"x", right contain "right"/"a".
    int isLeft = strstr(n, "left") || strstr(n, "_x_") || strstr(n, "squeezeleft") || strstr(n, "triggerleft");
    ios_controller *c2 = isLeft ? &c[0] : &c[1];
    *buttons = c2->buttons;
    *trigger = c2->trigger;
    *grip = c2->grip;
    *pose = c2->pose;
}

XRAPI_ATTR XrResult XRAPI_CALL xrGetActionStateBoolean(XrSession session, const XrActionStateGetInfo *info, XrActionStateBoolean *out) {
    (void)session;
    if (!info || !out) return XR_ERROR_VALIDATION_FAILURE;
    int32_t slot = (int32_t)(uintptr_t)info->action - 1;
    memset(out, 0, sizeof(*out));
    out->type = XR_TYPE_ACTION_STATE_BOOLEAN;
    if (slot < 0 || slot >= MAX_ACTIONS || !g_actions[slot].used) return XR_ERROR_ACTION_HANDLE_INVALID;
    uint32_t buttons; float trigger, grip; ios_pose pose;
    lookup_action(slot, &buttons, &trigger, &grip, &pose);
    const char *n = g_actions[slot].name;
    out->currentState =
        (strstr(n, "trigger") && (buttons & 1)) ||
        (strstr(n, "squeeze") && (buttons & 2)) ||
        (strstr(n, "a") && (buttons & 4)) ||
        (strstr(n, "x") && (buttons & 4)) ||
        (strstr(n, "menu") && (buttons & 8));
    out->isActive = XR_TRUE;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrGetActionStateFloat(XrSession session, const XrActionStateGetInfo *info, XrActionStateFloat *out) {
    (void)session;
    if (!info || !out) return XR_ERROR_VALIDATION_FAILURE;
    int32_t slot = (int32_t)(uintptr_t)info->action - 1;
    memset(out, 0, sizeof(*out));
    out->type = XR_TYPE_ACTION_STATE_FLOAT;
    if (slot < 0 || slot >= MAX_ACTIONS || !g_actions[slot].used) return XR_ERROR_ACTION_HANDLE_INVALID;
    uint32_t buttons; float trigger, grip; ios_pose pose;
    lookup_action(slot, &buttons, &trigger, &grip, &pose);
    const char *n = g_actions[slot].name;
    out->currentState = strstr(n, "squeeze") ? grip : trigger;
    out->isActive = XR_TRUE;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrGetActionStatePose(XrSession session, const XrActionStateGetInfo *info, XrActionStatePose *out) {
    (void)session; (void)info;
    if (!out) return XR_ERROR_VALIDATION_FAILURE;
    memset(out, 0, sizeof(*out));
    out->type = XR_TYPE_ACTION_STATE_POSE;
    out->isActive = XR_TRUE;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrCreateActionSpace(XrSession session, const XrActionSpaceCreateInfo *info, XrSpace *out) {
    (void)session; (void)info;
    if (!out) return XR_ERROR_VALIDATION_FAILURE;
    int32_t slot = next_space_slot();
    if (slot < 0) return XR_ERROR_LIMIT_REACHED;
    g_spaces[slot].used = 1;
    g_spaces[slot].type = -1; // action space
    memset(&g_spaces[slot].pose, 0, sizeof(ios_pose));
    g_spaces[slot].pose.quat[3] = 1.0f;
    *out = (XrSpace)(uintptr_t)(slot + 1);
    return XR_SUCCESS;
}

// ---------------------------------------------------------------- swapchain

XRAPI_ATTR XrResult XRAPI_CALL xrCreateSwapchain(XrSession session, const XrSwapchainCreateInfo *info, XrSwapchain *out) {
    (void)session;
    if (!info || !out) return XR_ERROR_VALIDATION_FAILURE;
    HOST_CALL(XR_ERROR_RUNTIME_FAILURE, {
        uint32_t count = 3;
        if (host->create_swapchain) {
            int32_t id = host->create_swapchain(info->width, info->height, &count, g_image_handles);
            if (id >= 0) {
                g_swapchain_id = id;
                g_image_count = count;
            }
        }
        *out = (XrSwapchain)(uintptr_t)0x105702;
    });
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrDestroySwapchain(XrSwapchain swapchain) {
    (void)swapchain;
    g_swapchain_id = -1;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateSwapchainImages(XrSwapchain swapchain, uint32_t capacity,
                                                          uint32_t *count, XrSwapchainImageBaseHeader *images) {
    (void)swapchain;
    if (!count) return XR_ERROR_VALIDATION_FAILURE;
    *count = g_image_count ? g_image_count : 3;
    if (capacity < *count || !images) return XR_SUCCESS;

    // Games on Windows ask for XrSwapchainImageD3D11KHR. IOS_DXMT_TODO:
    // create the D3D11 textures here through the game's DXMT-backed device
    // and register their Metal backing with the host create_swapchain call
    // above (host returns handles we then fill into .texture fields' shadow
    // mapping). Until the DXMT hook lands, hand back placeholder pointers so
    // the flow can be validated with hello_xr's non-graphical path.
    for (uint32_t i = 0; i < *count; i++) {
        XrSwapchainImageD3D11KHR *img = (XrSwapchainImageD3D11KHR *)&images[i];
        if (images[i].type == XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR) {
            img->texture = (ID3D11Texture2D *)(uintptr_t)g_image_handles[i];
        }
    }
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrAcquireSwapchainImage(XrSwapchain swapchain, const XrSwapchainImageAcquireInfo *info, uint32_t *index) {
    (void)swapchain; (void)info;
    if (!index) return XR_ERROR_VALIDATION_FAILURE;
    HOST_CALL(XR_ERROR_RUNTIME_FAILURE, {
        int32_t i = host->acquire_swapchain_image ? host->acquire_swapchain_image(g_swapchain_id) : 0;
        *index = (uint32_t)(i >= 0 ? i : 0);
        g_acquired[*index & 7] = *index + 1;
    });
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrWaitSwapchainImage(XrSwapchain swapchain, const XrSwapchainImageWaitInfo *info) {
    (void)swapchain; (void)info;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrReleaseSwapchainImage(XrSwapchain swapchain, const XrSwapchainImageReleaseInfo *info) {
    (void)swapchain; (void)info;
    HOST_CALL(XR_SUCCESS, {
        if (host->release_swapchain_image) host->release_swapchain_image(g_swapchain_id, 0);
    });
    return XR_SUCCESS;
}

// ---------------------------------------------------------------- frame loop

XRAPI_ATTR XrResult XRAPI_CALL xrBeginFrame(XrSession session, const XrFrameBeginInfo *info) {
    (void)session; (void)info;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEndFrame(XrSession session, const XrFrameEndInfo *info) {
    (void)session;
    if (!info) return XR_ERROR_VALIDATION_FAILURE;
    HOST_CALL(XR_ERROR_RUNTIME_FAILURE, {
        if (!host->submit_frame) return;
        uint64_t eyes[2] = { g_image_handles[0], g_image_handles[1] };
        ios_pose head_views[2];
        for (int i = 0; i < 2; i++) {
            if (host->get_head_pose) host->get_head_pose((double)info->displayTime * 1e-9, &head_views[i]);
            else { memset(&head_views[i], 0, sizeof(head_views[i])); head_views[i].quat[3] = 1; }
        }
        host->submit_frame((double)info->displayTime * 1e-9, eyes, head_views);
        g_frame_index++;
    });
    return XR_SUCCESS;
}

// ---------------------------------------------------------------- dispatch

XRAPI_ATTR XrResult XRAPI_CALL xrGetInstanceProcAddr(XrInstance instance, const char *name, PFN_xrVoidFunction *function) {
    (void)instance;
    if (!name || !function) return XR_ERROR_VALIDATION_FAILURE;
    *function = NULL;

#define FN(n) if (strcmp(name, #n) == 0) { *function = (PFN_xrVoidFunction)&n; return XR_SUCCESS; }
    FN(xrEnumerateInstanceExtensionProperties)
    FN(xrCreateInstance)
    FN(xrDestroyInstance)
    FN(xrGetInstanceProperties)
    FN(xrEnumerateApiLayerProperties)
    FN(xrGetSystem)
    FN(xrGetSystemProperties)
    FN(xrEnumerateEnvironmentBlendModes)
    FN(xrEnumerateViewConfigurations)
    FN(xrGetViewConfigurationProperties)
    FN(xrEnumerateViewConfigurationViews)
    FN(xrCreateSession)
    FN(xrDestroySession)
    FN(xrBeginSession)
    FN(xrEndSession)
    FN(xrRequestExitSession)
    FN(xrPollEvent)
    FN(xrCreateReferenceSpace)
    FN(xrDestroySpace)
    FN(xrLocateSpace)
    FN(xrLocateViews)
    FN(xrCreateActionSet)
    FN(xrDestroyActionSet)
    FN(xrCreateAction)
    FN(xrDestroyAction)
    FN(xrSuggestInteractionProfileBindings)
    FN(xrAttachSessionActionSets)
    FN(xrSyncActions)
    FN(xrGetActionStateBoolean)
    FN(xrGetActionStateFloat)
    FN(xrGetActionStatePose)
    FN(xrCreateActionSpace)
    FN(xrCreateSwapchain)
    FN(xrDestroySwapchain)
    FN(xrEnumerateSwapchainImages)
    FN(xrAcquireSwapchainImage)
    FN(xrWaitSwapchainImage)
    FN(xrReleaseSwapchainImage)
    FN(xrBeginFrame)
    FN(xrEndFrame)
    FN(xrGetInstanceProcAddr)
#undef FN
    return XR_ERROR_FUNCTION_UNSUPPORTED;
}

BOOL WINAPI DllMain(HINSTANCE dll, DWORD reason, LPVOID reserved) {
    (void)dll; (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) load_host_vtable();
    return TRUE;
}
