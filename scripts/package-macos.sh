#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MANGA_VERSION="${MANGA_VERSION:-0.3.4}"
MANGA_OUTPUT="${MANGA_OUTPUT:-$PWD/release}"
MANGA_ARCH="${MANGA_ARCH:-$(uname -m)}"
if [[ "$MANGA_ARCH" == universal ]]; then
    MANGA_ARCH=arm64 MANGA_OUTPUT="$MANGA_OUTPUT/.parts/arm64" "$0"
    MANGA_ARCH=x86_64 MANGA_OUTPUT="$MANGA_OUTPUT/.parts/x86_64" "$0"
    mkdir -p "$MANGA_OUTPUT"
    ditto "$MANGA_OUTPUT/.parts/arm64/ChasingManga.app" "$MANGA_OUTPUT/ChasingManga.app"
    lipo -create "$MANGA_OUTPUT/.parts/arm64/ChasingManga.app/Contents/MacOS/ChasingMangaApp" "$MANGA_OUTPUT/.parts/x86_64/ChasingManga.app/Contents/MacOS/ChasingMangaApp" -output "$MANGA_OUTPUT/ChasingManga.app/Contents/MacOS/ChasingMangaApp"
    codesign --force --sign - --entitlements Apps/macOS/MangaMac.entitlements "$MANGA_OUTPUT/ChasingManga.app"
    codesign --verify --deep --strict "$MANGA_OUTPUT/ChasingManga.app"
    ditto -c -k --sequesterRsrc --keepParent "$MANGA_OUTPUT/ChasingManga.app" "$MANGA_OUTPUT/ChasingManga-$MANGA_VERSION-macOS-universal.zip"
    (cd "$MANGA_OUTPUT" && shasum -a 256 "ChasingManga-$MANGA_VERSION-macOS-universal.zip" > "ChasingManga-$MANGA_VERSION-macOS-universal.zip.sha256")
    echo "Packaged: $MANGA_OUTPUT/ChasingManga.app (arm64 + x86_64)"
    exit 0
fi
case "$MANGA_ARCH" in arm64|x86_64) ;; *) echo 'Supported architectures: arm64, x86_64, universal' >&2; exit 1;; esac
swift build --skip-update -c release --product ChasingMangaApp --triple "${MANGA_ARCH}-apple-macosx14.0" --scratch-path ".build/package-$MANGA_ARCH"
MANGA_BIN_DIR="$(swift build -c release --show-bin-path --triple "${MANGA_ARCH}-apple-macosx14.0" --scratch-path ".build/package-$MANGA_ARCH")"
MANGA_APP="$MANGA_OUTPUT/ChasingManga.app"
mkdir -p "$MANGA_OUTPUT" "$MANGA_APP/Contents/MacOS" "$MANGA_APP/Contents/Resources"
cp "$MANGA_BIN_DIR/ChasingMangaApp" "$MANGA_APP/Contents/MacOS/ChasingMangaApp"
cp LICENSE "$MANGA_APP/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$MANGA_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
python3 - "$MANGA_APP" "$MANGA_VERSION" <<'PY'
import plistlib, sys
from pathlib import Path
app, version = Path(sys.argv[1]), sys.argv[2]
info = plistlib.loads(Path('Apps/macOS/Info.plist').read_bytes())
info.update(CFBundleExecutable='ChasingMangaApp', CFBundleIdentifier='com.chasingmanga.local.mac', CFBundleName='ChasingManga', CFBundleDisplayName='追漫', CFBundleShortVersionString=version, CFBundleVersion='10', LSMinimumSystemVersion='14.0', CFBundleIconFile='AppIcon', NSHighResolutionCapable=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
swift scripts/make-app-icon.swift "$MANGA_APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --entitlements Apps/macOS/MangaMac.entitlements "$MANGA_APP"
codesign --verify --deep --strict "$MANGA_APP"
plutil -lint "$MANGA_APP/Contents/Info.plist"
ditto -c -k --sequesterRsrc --keepParent "$MANGA_APP" "$MANGA_OUTPUT/ChasingManga-$MANGA_VERSION-macOS-$MANGA_ARCH.zip"
(cd "$MANGA_OUTPUT" && shasum -a 256 "ChasingManga-$MANGA_VERSION-macOS-$MANGA_ARCH.zip" > "ChasingManga-$MANGA_VERSION-macOS-$MANGA_ARCH.zip.sha256")
echo "Packaged: $MANGA_APP ($MANGA_ARCH)"
