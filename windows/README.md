# windows (Phase 3 — on-device Steam / SteamVR)

Layout:

- `vendor/` — pinned forks: FEX (ios-port-2607), Wine (madeira-lgpl),
  DXMT (ios-port) — the same forks [Madeira](https://github.com/willfaust/madeira)
  builds for iOS — plus Khronos OpenXR-SDK headers for the shim.
- `host-bridge/ios_bridge.h` — ABI between the OpenXR shim (inside Wine) and
  the Swift host (XRCore). Single process, function pointers, no IPC.
- `openxr-shim/` — replacement `openxr_loader.dll`: OpenXR games talk to it;
  poses come from XRCore (ARKit + hand tracking), frames go to the iios
  compositor. The one marked hook left is the DXMT swapchain interop.
- `build-layer.sh` — `shim` (fast, builds the DLL via llvm-mingw) and
  `layer` (FEX+Wine+DXMT; follow the vendored forks'/Madeira's build docs).

See docs/ONDEVICE-STEAM.md for the architecture, status, and why we build on
Madeira's architecture instead of steamac's VM (Mac-only).

Note: vendoring GPL (Wine via Madeira's GPL forks) makes iios GPL-3.0-or-later.

