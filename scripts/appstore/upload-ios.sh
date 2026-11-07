#!/usr/bin/env bash
# Archiva la app de iPhone/iPad (target ArgosiOS) y la sube a App Store Connect
# (TestFlight). Firma manual con «Apple Distribution» y el perfil «Argos iOS App
# Store» (ver README.md). La versión sale de project.yml: sube
# CURRENT_PROJECT_VERSION antes de cada subida.
#
# Uso:  scripts/appstore/upload-ios.sh
set -euo pipefail

cd "$(dirname "$0")/../.."

KEY_ID="${ASC_KEY_ID:-576N2X283X}"
ISSUER_ID="${ASC_ISSUER_ID:-0cfaa54f-c1ad-4ebd-84f8-c6b6c5530a1e}"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8}"
OUT="${ARGOS_APPSTORE_OUT:-build/appstore}"
ARCHIVE="$OUT/Argos-iOS.xcarchive"

[ -f "$KEY_PATH" ] || { echo "Falta la clave de App Store Connect: $KEY_PATH" >&2; exit 1; }

AUTH=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$KEY_PATH"
  -authenticationKeyID "$KEY_ID"
  -authenticationKeyIssuerID "$ISSUER_ID"
)

rm -rf "$ARCHIVE"
xcodegen generate

# El archive firma en automático (desarrollo); la firma de distribución se aplica
# al exportar (ExportOptions-iOS.plist). Forzar la firma manual aquí la aplicaría
# también a los bundles de los paquetes SPM, que no tienen team.
echo "▶︎ Archivando ArgosiOS…"
xcodebuild archive \
  -project Argos.xcodeproj -scheme ArgosiOS -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  "${AUTH[@]}"

echo "▶︎ Exportando y subiendo a App Store Connect…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/appstore/ExportOptions-iOS.plist \
  -exportPath "$OUT/export-ios" \
  "${AUTH[@]}"

echo "✔ Subido. El build aparecerá en App Store Connect → TestFlight tras procesarse."
