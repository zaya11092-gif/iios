# On-device Steam / SteamVR (Phase 3)

Goal: run Windows games — including OpenXR/SteamVR titles — directly on the
iPhone, no PC in the loop.

## Why not steamac's approach

[steamac](https://github.com/fxgl/steamac) (the referenced project) runs
Valve's ARM64 SteamOS inside a VM on **Hypervisor.framework** — macOS 15+
only, ~150 GB of disk, Apple Silicon Mac required. iPhones expose no VM API
to apps, so that architecture cannot be ported. We take steamac's
**component selection** — FEX (x86-64→ARM64), Wine, DXMT (D3D→Metal, its
opt-in "Allow DXMT" feature) — and run it the only way iOS allows: the
[Madeira](https://github.com/willfaust/madeira) single-process architecture,
where FEXCore, Wine and DXMT all run as libraries inside one iOS app.

## Stack (vendored under windows/vendor/, same pinned forks Madeira uses)

```
x86-64 Windows game (SteamVR/OpenXR or flat)
├─ openxr_loader.dll  ← iios shim (windows/openxr-shim/): poses from XRCore,
│                       frames composited by iios — replaces SteamVR entirely
├─ D3D9/10/11 ── DXMT ──→ Metal (shared with iios's compositor device)
├─ Win32 ── Wine 11 (ARM64EC: Wine native, game code translated)
└─ x86-64 ── FEX-Emu ──→ arm64 (JIT; requires JIT entitlement, see SIDELOADING.md)
```

Flat 2D Steam games run through the same stack minus the shim, rendered onto
a big virtual screen in the home environment (theater mode).

## What exists now

| Piece | State |
|-------|-------|
| Submodules (FEX ios-port-2607 / wine madeira-lgpl / dxmt ios-port / OpenXR-SDK) | ✅ vendored |
| Bridge ABI (`windows/host-bridge/ios_bridge.h`) — vtable the shim uses to reach XRCore | ✅ specified |
| OpenXR shim (`windows/openxr-shim/`) — lifecycle, spaces, actions, frame loop, session events | ✅ written; the **DXMT swapchain interop** is the one marked hook (`IOS_DXMT_TODO`) |
| `windows/build-layer.sh` (shim stage fast / layer stage = Madeira recipes) | ✅ scaffolded |
| CI `windows-layer.yml` (manual) builds the shim DLL with llvm-mingw | ✅ |
| `WindowsHost.swift` + Windows button in the VR menu bar + Settings (game path, status) | ✅ shell present |
| FEX+Wine+DXMT actually built & linked, DXMT texture interop | ⬜ **the remaining work** |

## Remaining work, in order

1. **Build the layer** — run Madeira's build recipes against our vendored
   forks (its docs/BUILDING.md + tools/build-ipa.sh apply directly since
   these are its forks). Best on a Mac; the CI stage is a scaffold. Output
   embeds into the app bundle at `dist/{fex,wine,dxmt}`.
2. **Link + init** — implement `IOS_LAYER_TODO` in WindowsHost: FEXCore
   context init, Wine process launch of the configured exe (settings →
   Windows layer → Game path).
3. **DXMT swapchain interop** — implement the `IOS_DXMT_TODO` in the shim:
   allocate swapchain D3D11 textures on the game's DXMT device, hand their
   Metal backing to the host `create_swapchain`, feed `submit_frame` into
   the compositor (same path the streaming client uses).
4. **Validate**: Khronos `hello_xr` through the shim → a simple OpenXR game
   → flat 2D Steam game in theater mode.
5. Expectation setting: an A16 plays lightweight/indie titles at best;
   heavy SteamVR games remain a streaming (Phase 2) job.

## Licensing

Wine (LGPL) + FEX (BSD-ish per fork) + DXMT (MIT) are fine to embed; Madeira
itself is **GPL-3.0 + Madeira Converter Exception**, and since we vendor its
forks and follow its architecture, iios is effectively GPL-3.0-or-later from
this point. Fine for a personal sideloaded project — do not App-Store this.
