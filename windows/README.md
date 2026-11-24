# windows (Phase 3)

Stub. Will vendor the [Madeira](https://github.com/willfaust/madeira) stack
(its pinned FEX / Wine-ARM64EC / DXMT forks, GPL-3.0 + Madeira Converter
Exception — vendoring them makes iios GPL-3.0) and add the iios-specific part:

- `openxr-shim/` — a replacement `openxr_loader.dll` implementing the common
  OpenXR subset (instance/session/spaces/actions/swapchain), bridging eye
  render targets and hand-derived controller poses to XRCore in-process
  (Madeira runs everything single-process; this is threads, not IPC).
- Flat 2D games rendered onto a big virtual screen (theater mode), input via
  virtual XInput from gestures.
- Validation order: Khronos `hello_xr` → one simple OpenXR game → 2D Steam game.

JIT is required for FEX — see docs/SIDELOADING.md.
