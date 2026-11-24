# iios

A sideloaded iOS app that turns a base iPhone 15 into a Quest-like headset:

- **XRCore runtime** — ARKit 6DoF SLAM, Metal stereoscopic compositor with lens
  distortion + rotational timewarp, monoscopic camera passthrough, and
  **hand-tracking-as-controllers** (Vision framework, 21 joints → virtual Touch
  controllers: pinch = trigger, finger curl = grip, thumb pinch = A button).
- **Demo game** — beat-saber-lite that exercises the whole stack.
- **Phase 2** — ALVR-compatible PC streaming client (real SteamVR titles from
  your PC, like Quest does PCVR).
- **Phase 3** — on-device Windows/x86 games via the
  [Madeira](https://github.com/willfaust/madeira) stack (FEX-Emu + Wine
  ARM64EC + DXMT) plus a custom OpenXR shim so VR games feed our compositor.

## Status

| Phase | Scope | State |
|-------|-------|-------|
| 0 | Repo, XcodeGen project, GitHub Actions unsigned `.ipa` | ✅ |
| 1 | XRCore MVP + demo game + hands-as-controllers | ✅ code, needs device validation |
| 2 | ALVR streaming client | ⬜ |
| 3 | Madeira integration + OpenXR shim | ⬜ |
| 4 | Polish, per-game profiles, controller tuning | ⬜ |

See [docs/BUILDING.md](docs/BUILDING.md), [docs/SIDELOADING.md](docs/SIDELOADING.md)
and — read this one — [docs/LIMITATIONS.md](docs/LIMITATIONS.md).

## Repo layout

```
app/          SwiftUI shell (home, settings, VR container, HUD)
xrcore/       XR runtime: ARKit session, hand tracking, Metal compositor, xrc C API
demo-game/    beat-saber-lite demo targeting the xrc API
alvr-client/  Phase 2 (stub)
windows/      Phase 3 (stub)
ci/           local build helper
docs/         building / sideloading / honest limitations
```

## Quick start

1. Push this repo to GitHub — CI builds `iios-unsigned.ipa` on every commit.
2. Download the artifact, sign + sideload per [docs/SIDELOADING.md](docs/SIDELOADING.md).
3. Strap the phone into cheap VR goggles (landscape, camera facing out).
4. Home screen → **Enter VR**. First run calibrates hand tracking — raise both
   palms to the camera.
