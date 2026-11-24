# Building

You cannot build this project on Windows directly — iOS apps require Apple's
toolchain. Two supported paths:

## GitHub Actions (recommended, no Mac needed)

1. Create a GitHub repo, push the project (the generated `iios.xcodeproj` is
   gitignored; CI regenerates it from `project.yml`).
2. The `build-ipa` workflow runs on a macOS runner and uploads an
   **unsigned** `iios-unsigned-ipa` artifact.
3. Download the artifact and sign + sideload it — see [SIDELOADING.md](SIDELOADING.md).

## Locally on a Mac

```bash
brew install xcodegen
xcodegen generate
open iios.xcodeproj          # set your dev team, then Cmd+R on a device
```

Notes:

- The Xcode project is **generated** from `project.yml` (XcodeGen). Edit
  `project.yml`, never the `.xcodeproj`.
- `xrcore/include/xrc.h` is the stable C ABI for games (and, later, the
  Windows/OpenXR shim). Swift sees it through the bridging header
  `app/iios-Bridging-Header.h`; the implementations are Swift functions
  exported with `@_cdecl` in `xrcore/XRCAPI.swift`.
- Metal shader source lives in `xrcore/Shaders.metal` and is compiled into the
  default Metal library at build time.
- Deployment target is iOS 17. Phase 3 (FEX/Wine, JIT) will raise this —
  Madeira targets iOS 26+.
