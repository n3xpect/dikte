#!/usr/bin/env bash
# Signed dikte.app → dist/dikte-<version>.dmg (drag-and-drop installer: app + Applications link).
# dist/ contains only the DMG.
#
#   app/make-dmg.sh [path/to/dikte.app]   # default: app/dikte/build/package/dikte.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="${1:-$ROOT/app/dikte/build/package/dikte.app}"
IDENTITY="Dikte Local Signing"

[[ -d "$APP" ]] || { echo "Önce paketle: app/package.sh ($APP yok)"; exit 1; }
codesign --verify --deep --strict "$APP" 2>/dev/null \
  || { echo "İmza geçersiz: $APP değiştirilmiş (ör. çalıştırılıp içine dosya yazılmış). Yeniden paketle: app/package.sh"; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$DIST/dikte-$VERSION.dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dikte-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

log() { printf '\033[1m▸ %s\033[0m\n' "$*"; }

log "DMG içeriği hazırlanıyor"
ditto "$APP" "$STAGE/dikte.app"
ln -s /Applications "$STAGE/Uygulamalar"

log "DMG oluşturuluyor (sıkıştırma birkaç dakika sürebilir)"
mkdir -p "$DIST"
# Keep dist/ to the installer only: drop older DMGs and anything else.
find "$DIST" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
hdiutil create -volname "Dikte $VERSION" -srcfolder "$STAGE" -fs APFS \
  -format ULFO -ov "$DMG" -quiet

if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --timestamp=none -s "$IDENTITY" "$DMG"
fi
hdiutil verify "$DMG" -quiet && log "DMG doğrulandı"
du -h "$DMG"
log "Hazır: $DMG — aç, Dikte'yi Uygulamalar'a sürükle"
