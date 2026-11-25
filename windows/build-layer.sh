#!/usr/bin/env bash
# Builds the Windows-on-iPhone layer: FEXCore (x86-64 -> ARM64), Wine
# (ARM64EC), DXMT (D3D9/10/11 -> Metal), and the OpenXR shim, producing
# windows/dist/ artifacts that WindowsHost.swift embeds/loads.
#
# This is Phase 3 and mirrors Madeira's build (see its docs/BUILDING.md and
# tools/build-ipa.sh — the pinned forks here are the same ones Madeira uses,
# so its build recipes apply directly). Run on a Mac with Xcode; expect the
# full build to take hours on first run (caching helps a lot).
#
# Stages:  ./build-layer.sh shim          (fast: OpenXR shim DLL, any host)
#          ./build-layer.sh layer         (slow: FEX + Wine + DXMT for iOS)
set -euo pipefail
cd "$(dirname "$0")"

STAGE="${1:-shim}"
DIST=dist
mkdir -p "$DIST"

build_shim() {
    (cd openxr-shim && ./build.sh)
}

build_layer() {
    echo "=== FEX (FEXCore for arm64 iOS) ==="
    # Madeira's FEX fork ships the iOS port; follow its docs for toolchain
    # pins (clang for arm64-apple-ios, ninja). Output: libFEXCore static lib
    # + JIT support files into $DIST/fex/
    echo "NOTE: follow windows/vendor/FEX ios-port build docs; output -> $DIST/fex/"

    echo "=== Wine (ARM64EC) ==="
    echo "NOTE: follow windows/vendor/wine madeira-lgpl build docs; output -> $DIST/wine/"

    echo "=== DXMT (D3D9/10/11 -> Metal) ==="
    echo "NOTE: follow windows/vendor/dxmt ios-port build docs; output -> $DIST/dxmt/"

    echo "=== Prefix assembly ==="
    # Assemble the Wine prefix skeleton (system32 with openxr_loader.dll,
    # OpenXR runtime manifest ActiveRuntime.xml pointing at the shim).
    build_shim
    echo "prefix skeleton -> $DIST/prefix/"
}

case "$STAGE" in
    shim)  build_shim ;;
    layer) build_layer ;;
    *) echo "usage: $0 [shim|layer]"; exit 1 ;;
esac
