#!/usr/bin/env bash
# Archiva la variante Mac App Store (target ArgosAppStore) y la sube a App Store
# Connect (TestFlight). La firma es automática con la clave de API de App Store
# Connect: Xcode crea/descarga los certificados y perfiles de distribución.
#
# Uso:  scripts/appstore/upload-mac.sh
# Requiere la clave en ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8 y, opcional,
# ASC_KEY_ID / ASC_ISSUER_ID en el entorno (por defecto, la clave de Impulse Vibes).
set -euo pipefail

cd "$(dirname "$0")/../.."

KEY_ID="${ASC_KEY_ID:-576N2X283X}"
ISSUER_ID="${ASC_ISSUER_ID:-0cfaa54f-c1ad-4ebd-84f8-c6b6c5530a1e}"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8}"
OUT="${ARGOS_APPSTORE_OUT:-build/appstore}"
ARCHIVE="$OUT/Argos-AppStore.xcarchive"

[ -f "$KEY_PATH" ] || { echo "Falta la clave de App Store Connect: $KEY_PATH" >&2; exit 1; }

AUTH=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$KEY_PATH"
  -authenticationKeyID "$KEY_ID"
  -authenticationKeyIssuerID "$ISSUER_ID"
)

rm -rf "$ARCHIVE"
xcodegen generate

echo "▶︎ Archivando ArgosAppStore…"
xcodebuild archive \
  -project Argos.xcodeproj -scheme ArgosAppStore -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  "${AUTH[@]}"

APP="$ARCHIVE/Products/Applications/Argos.app"
# Guardas: la variante App Store NO puede llevar Sparkle ni excepciones temporales.
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  echo "✘ El archive contiene Sparkle.framework" >&2; exit 1
fi
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "temporary-exception"; then
  echo "✘ El archive tiene entitlements de excepción temporal" >&2; exit 1
fi

echo "▶︎ Exportando y subiendo a App Store Connect…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/appstore/ExportOptions.plist \
  -exportPath "$OUT/export" \
  "${AUTH[@]}"

echo "✔ Subido. El build aparecerá en App Store Connect → TestFlight tras procesarse."
