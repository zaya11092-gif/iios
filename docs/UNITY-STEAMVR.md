# Unity + SteamVR integration (literal CardboardXR port)

**Core decision:** we do NOT reimplement CardboardXR in Swift. We build
CardboardXR itself on this machine (Unity 6000.6.8f1 + iOS module are
installed; their repo is vendored at `unity/CardboardXR`), export the Xcode
project, then inject the SteamVR/FEX/Wine/DXMT on-device layer into the
exported iOS app. iios's Swift runtime becomes the native host backing
(ARKit head + Metal compositor), while Unity renders SteamVR frames.

## What we have on this machine

- Unity Editor `6000.6.8f1` — `C:\Program Files\Unity\Hub\Editor\6000.6.8f1\Editor\Unity.exe`
  (their project's exact version; installed with Android + iOS modules)
- Active Unity license (`C:\ProgramData\Unity\Unity_lic.ulf`)
- CardboardXR source → `unity/CardboardXR` (submodule, pinned
  `2cb46a2`, Apache-2.0 — third-party notices at
  `unity/CardboardXR/THIRD_PARTY_NOTICES.md`)
- iios native layer → `windows/vendor/{FEX, Wine, DXMT, OpenXR-SDK}` +
  `windows/openxr-shim/`

## Build CardboardXR for iPhone (their script)

From a Mac with Xcode signed into an Apple ID, iPhone connected/trusted,
Developer Mode on the phone:

```bash
cd unity/CardboardXR
CARDBOARDXR_BUNDLE_ID=com.example.iios TEAM=<10-char-team-id> \
    zsh Tools/ios_build_and_run.sh
```

What it does:
1. `make_videos.sh` — prepares video assets
2. Unity batch export: `-batchmode -quit -projectPath <cardboardxr> -buildTarget iOS
   -executeMethod ProjectBootstrap.StereoBuilder.BuildIos`
   → `Builds/iOS/Unity-iPhone.xcodeproj` (a normal Xcode project)
3. `xcodebuild` archive + sign → install + launch on iPhone
4. Launch options passed last as `-ei <name> <value>` (dof, passthrough,
   handHz, predictionMs, renderScale …)

iOS build from **Windows is not supported** — Unity can write the Xcode
project from Windows, but compiling it requires macOS + Xcode. The iOS step
must run on a Mac (or Mac runner).

## Injection points — where SteamVR goes

CardboardXR already has:
- ARKit 6DoF + camera passthrough + surface detection + hand tracking
- its own stereo renderer (ported from Google Cardboard SDK, lens distortion)
- launch-option system (their `ProjectBootstrap` handles `--ei` args)
- scene pipeline (Core lobby → additive demos)

Our layer replaces/replaces-on-top:

### 1. OpenXR runtime → our shim (`windows/openxr-shim/`)

CardboardXR talks to an OpenXR runtime via AR Foundation's XR loader. In the
exported Xcode project we:

- Add `windows/dist/shim/openxr_loader.dll` (built by
  `windows/build-layer.sh shim` via llvm-mingw) to the app bundle and
  register it as the active OpenXR runtime (their app's
  `ActiveRuntime.xml` / runtime manifest).
- The shim implements OpenXR 1.0 (instance/session/spaces/actions/frame
  loop/swapchain) and bridges into our Swift host through `ios_bridge.h`:
  `ios_host_get_vtable()` — head pose, hand controller poses, swapchain
  image handles, `submit_frame`.
- That gives SteamVR *controller input* (hands-derived trigger/grip/buttons)
  and *eye render targets* back to our Metal compositor — SteamVR games run
  thinking they're on a real headset.

iOS-side `XRCAPI.swift` exports `ios_host_get_vtable` from the main
executable (already written; the table is populated once the native layer
links).

### 2. FEX (x86-64 → ARM64) + Wine ARM64EC (`windows/vendor/`)

Madeira's pinned forks, same as they use:

- `vendor/FEX` (`ios-port-2607`): JIT x86-64 translation → arm64. Requires
  the JIT entitlement (see docs/SIDELOADING.md; AltStore/SideStore StikDebug).
- `vendor/Wine` (`madeira-lgpl`): Win32 → ARM64EC; game code runs through
  FEX, Wine runs native.
- `vendor/DXMT` (`ios-port`): D3D9/10/11 → Metal. SteamVR games render
  through DXMT into Metal textures that our compositor presents.

Build order (Madeira recipes apply directly — these are its forks):
1. FEXCore static lib + JIT support → `windows/dist/fex/`
2. Wine ARM64EC → `windows/dist/wine/`
3. DXMT → `windows/dist/dxmt/`
4. `build-layer.sh layer` runs all three + assembles the Wine prefix

### 3. SteamVR inside Wine

The Windows game (SteamVR title) runs unmodified in Wine/FEX:
- Steam client + SteamVR runtime execute under Wine ARM64EC
- OpenXR calls hit our `openxr_loader.dll` shim (registered as runtime)
- DXMT converts its D3D calls to Metal; Metal frames flow to iios's
  compositor via `ios_host_vtable.submit_frame`
- Hand-derived virtual Touch controllers stream back as OpenXR actions

This is the same stack Madeira runs single-process inside one iOS app; we
merge it with Unity/CardboardXR by putting both in the same exported Xcode
project and bridging through the host vtable.

## Two deployment shapes

**A. Standalone Unity+iios app (recommended for SteamVR)**

CardboardXR Unity app is the iOS app. iios's Swift runtime is embedded as
a native plugin in the exported Xcode project:
- `ios_host_get_vtable` exported from the main executable
- Metal device shared between Unity (DXMT textures) and our compositor
- Unity renders the game; our compositor does lens distortion/timewarp
- Hands come from our Vision-based tracker (or Unity's XR Hands — either
  feeds the same controller poses)

**B. Hybrid (iios shell hosts Unity view)**

If the Unity view must live inside our SwiftUI shell: export Unity as a
native iOS library/framework, embed it in `iios.xcodeproj`, and the
host vtable bridges both. More plumbing; same SteamVR flow.

## What remains

| Step | Detail |
|------|--------|
| Build FEX/Wine/DXMT layer | `windows/build-layer.sh layer` on Mac (hours first time; recipes = Madeira's) |
| Link layer into exported Xcode project | Add vendor dylibs + Wine prefix to `Builds/iOS/` bundle; set DYLD paths |
| Register OpenXR runtime | `ActiveRuntime.xml` → our shim DLL path in the Unity app |
| Metal device sharing | Unity's DXMT-created textures → our compositor via swapchain handles |
| Test | `hello_xr` through shim → simple OpenXR game → full SteamVR title |

## Licensing

CardboardXR is Apache-2.0 (notices at `THIRD_PARTY_NOTICES.md`). The Windows
layer vendored from Madeira is GPL-3.0 (+ Madeira Converter Exception for
Metal Shader Converter). Embedding Wine/FEX/DXMT makes the combined app
GPL-3.0-or-later — fine for personal sideloading, not App Store.
