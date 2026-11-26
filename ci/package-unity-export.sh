#!/usr/bin/env bash
# Zips the Unity iOS Xcode export (unity/CardboardXR/Builds/iOS) and uploads it
# as the `unity-export` release asset consumed by .github/workflows/unity-ipa.yml.
# Run on the machine that ran the Unity export (Windows Git Bash or macOS).
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="unity/CardboardXR/Builds/iOS"
[ -d "$SRC/Unity-iPhone.xcodeproj" ] || { echo "no Xcode export at $SRC — run the Unity export first"; exit 1; }

ZIP="unity-xcode-export.zip"
echo "zipping $SRC -> $ZIP (this takes a few minutes)…"
rm -f "$ZIP"
python - "$SRC" "$ZIP" <<'EOF'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for root, dirs, files in os.walk(src):
        for f in files:
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, os.path.dirname(src)))
print('zip done')
EOF

TAG="unity-export"
gh release delete "$TAG" --yes --cleanup-tag 2>/dev/null || true
gh release create "$TAG" "$ZIP" \
    --title "CardboardXR iOS Xcode export ($(date -u +'%Y-%m-%d %H:%M UTC'))" \
    --notes "Xcode project exported from brenpoly/CardboardXR via Unity 6000.6.8f1 (Windows batchmode).
Consumed by the unity-ipa workflow to produce the unsigned .ipa." \
    --prerelease
echo "uploaded to release $TAG"