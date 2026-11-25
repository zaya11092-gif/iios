#!/usr/bin/env bash
# Builds openxr_loader.dll (the iios OpenXR shim) with llvm-mingw.
# Output: windows/dist/shim/openxr_loader.dll — dropped into the Wine prefix's
# system32 and registered as the active OpenXR runtime by build-layer.sh.
set -euo pipefail
cd "$(dirname "$0")"

SHIM_OUT=../dist/shim
OPENXR_HEADERS=../vendor/OpenXR-SDK/include

CC="${CC:-x86_64-w64-mingw32-gcc}"
command -v "$CC" >/dev/null 2>&1 || CC="${CC:-/opt/llvm-mingw/bin/x86_64-w64-mingw32-gcc}"

mkdir -p "$SHIM_OUT"
"$CC" -O2 -shared -o "$SHIM_OUT/openxr_loader.dll" \
    -I"$OPENXR_HEADERS" \
    -DUNICODE -D_UNICODE \
    openxr_loader.c \
    -lkernel32 -luser32 \
    -Wl,--kill-at 2>/dev/null || \
"$CC" -O2 -shared -o "$SHIM_OUT/openxr_loader.dll" \
    -I"$OPENXR_HEADERS" \
    -DUNICODE -D_UNICODE \
    openxr_loader.c \
    -lkernel32 -luser32

echo "built $SHIM_OUT/openxr_loader.dll"
