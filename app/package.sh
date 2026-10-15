#!/usr/bin/env bash
# Build dist/dikte.app: Release build of the Swift app + the Python engine with its own
# relocatable Python (python-build-standalone via uv) embedded in Contents/Resources/engine.
# Signed with a persistent local identity so macOS keeps the microphone permission across builds.
#
#   app/package.sh            # build + sign → dist/dikte.app
#   app/package.sh --no-sign  # skip signing (debugging)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="$ROOT/app/dikte"
ENGINE_SRC="$ROOT/app/engine"
BUILD="$ROOT/app/dikte/build/package"
DIST="$ROOT/dist"
PY_VERSION="$(cat "$ENGINE_SRC/.python-version" 2>/dev/null || echo 3.12)"
IDENTITY="Dikte Local Signing"
SIGN=1
[[ "${1:-}" == "--no-sign" ]] && SIGN=0

log() { printf '\033[1m▸ %s\033[0m\n' "$*"; }

log "Swift uygulaması derleniyor (Release)"
(cd "$APP_SRC" && xcodegen generate --quiet)
xcodebuild -project "$APP_SRC/dikte.xcodeproj" -scheme dikte -configuration Release \
  -derivedDataPath "$BUILD/DerivedData" CODE_SIGN_IDENTITY=- build -quiet
APP_BUILT="$BUILD/DerivedData/Build/Products/Release/dikte.app"

log "Paket hazırlanıyor"
rm -rf "$BUILD/dikte.app"
cp -R "$APP_BUILT" "$BUILD/dikte.app"
RES="$BUILD/dikte.app/Contents/Resources/engine"
mkdir -p "$RES"

log "Gömülü Python $PY_VERSION kuruluyor"
PY_STORE="$BUILD/python-store"
uv python install "$PY_VERSION" --install-dir "$PY_STORE" --quiet
PY_HOME="$(find "$PY_STORE" -maxdepth 1 -type d -name "cpython-$PY_VERSION*" | head -1)"
[[ -d "$PY_HOME" ]] || { echo "Python bulunamadı: $PY_STORE"; exit 1; }
cp -R "$PY_HOME" "$RES/python"
PY="$RES/python/bin/python3"

log "Motor bağımlılıkları kuruluyor"
REQ="$BUILD/requirements.txt"
uv export --project "$ENGINE_SRC" --frozen --no-dev --no-emit-project --no-hashes -q > "$REQ"
uv pip install --python "$PY" --break-system-packages --no-cache -r "$REQ" -q
# PEP 668 marker would block later pip use; harmless to remove inside our private copy.
find "$RES/python/lib" -maxdepth 2 -name EXTERNALLY-MANAGED -delete
rm -rf "$RES/python/share" "$RES/python/include"
find "$RES/python" -name "__pycache__" -type d -prune -exec rm -rf {} +

log "Motor kodu kopyalanıyor"
rsync -a --exclude "__pycache__" "$ENGINE_SRC/dikte_engine" "$RES/"

if [[ $SIGN == 1 ]]; then
  # no -v: a self-signed identity is "not trusted" but still signs fine
  if ! security find-identity -p codesigning | grep -q "$IDENTITY"; then
    log "Yerel imza sertifikası oluşturuluyor: $IDENTITY"
    "$ROOT/app/scripts/make-signing-identity.sh" "$IDENTITY"
  fi
  log "İmzalanıyor (bu birkaç dakika sürebilir)"
  ENT_PY="$BUILD/python.entitlements"
  cat > "$ENT_PY" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
EOF
  # Inside-out: every Mach-O in the engine, then python, then the app.
  find "$RES" -type f \( -name "*.so" -o -name "*.dylib" \) -print0 |
    xargs -0 -P 8 -n 50 codesign --force --timestamp=none -s "$IDENTITY" 2>/dev/null
  find "$RES/python/bin" -type f -perm +111 -print0 |
    xargs -0 -n 1 sh -c 'file "$0" | grep -q Mach-O && codesign --force --timestamp=none -o runtime --entitlements "'"$ENT_PY"'" -s "'"$IDENTITY"'" "$0" || true'
  codesign --force --timestamp=none -o runtime \
    --entitlements "$APP_SRC/dikte.entitlements" -s "$IDENTITY" "$BUILD/dikte.app"
  codesign --verify --deep --strict "$BUILD/dikte.app" && log "İmza doğrulandı"
fi

log "dist/dikte.app yazılıyor"
mkdir -p "$DIST"
rm -rf "$DIST/dikte.app"
ditto "$BUILD/dikte.app" "$DIST/dikte.app"
du -sh "$DIST/dikte.app"
log "Hazır: $DIST/dikte.app (kurulum: kendin /Applications'a sürükle)"
