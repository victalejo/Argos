#!/usr/bin/env bash
# Mantenimiento de los catálogos de cadenas (español de origen + inglés) SIN abrir Xcode.
#
#   scripts/localization.sh extract [--skip-build]
#       Compila Argos, ArgosAppStore y ArgosiOS (las cadenas bajo `#if APPSTORE` solo
#       salen de la variante App Store) con el compilador extrayendo las cadenas
#       (SWIFT_EMIT_LOC_STRINGS=YES, ya activo en project.yml) y vuelca en los catálogos
#       las claves nuevas con `xcstringstool sync`. Las que ya no usa el código quedan
#       marcadas como «stale». --skip-build reutiliza la última compilación.
#
#   scripts/localization.sh check
#       Falla si alguna clave no tiene traducción inglesa revisada, si los marcadores de
#       formato no coinciden entre idiomas o si quedan claves obsoletas. Los tests
#       (LocalizationCatalogTests) comprueban lo mismo en la CI.
#
# Flujo al añadir textos: escribe el texto en español en el código (literal de SwiftUI o
# `String(localized:)`), ejecuta `extract`, traduce las claves nuevas en
# Localization/Localizable.xcstrings (estado "translated"; con Xcode o a mano: es JSON)
# y ejecuta `check`. Alternativa equivalente con Xcode: `xcodebuild -exportLocalizations
# -project Argos.xcodeproj -localizationPath <dir> -exportLanguage en` genera un .xcloc
# con el XLIFF para un traductor; se reimporta con `-importLocalizations`.
set -euo pipefail

cd "$(dirname "$0")/.."

CATALOGS=(Localization/Localizable.xcstrings ArgosiOS/AppShortcuts.xcstrings)
DERIVED=${L10N_DERIVED_DATA:-build/l10n-DerivedData}

build() {
  local scheme=$1 destination=$2
  echo "Compilando $scheme para extraer cadenas…" >&2
  xcodebuild build -project Argos.xcodeproj -scheme "$scheme" -configuration Debug \
    -destination "$destination" -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=YES >/dev/null
}

extract() {
  if [ "${1:-}" != "--skip-build" ]; then
    build Argos 'platform=macOS'
    build ArgosAppStore 'platform=macOS'
    build ArgosiOS 'generic/platform=iOS Simulator'
  fi
  # Solo las fuentes de las apps (no las de los paquetes SwiftPM).
  local files=()
  while IFS= read -r -d '' file; do files+=("$file"); done < <(
    find "$DERIVED/Build/Intermediates.noindex" \
      \( -path '*/Argos.build/*' -o -path '*/ArgosAppStore.build/*' -o -path '*/ArgosiOS.build/*' \) \
      -name '*.stringsdata' -print0)
  if [ ${#files[@]} -eq 0 ]; then
    echo "No hay .stringsdata: compila primero (sin --skip-build)." >&2
    exit 1
  fi
  local args=()
  for file in "${files[@]}"; do args+=(--stringsdata "$file"); done
  xcrun xcstringstool sync "${CATALOGS[@]}" "${args[@]}"
  echo "Catálogos sincronizados con ${#files[@]} archivos .stringsdata." >&2
  # El español de origen se escribe en cada clave (si falta, es.lproj no la trae y se
  # vería en inglés, la región de desarrollo): ver localization_check.py.
  python3 -I scripts/localization_check.py --fill-source "${CATALOGS[@]}" || true
}

check() {
  python3 -I scripts/localization_check.py "${CATALOGS[@]}" Localization/InfoPlist.xcstrings
}

case "${1:-}" in
  extract) shift; extract "$@" ;;
  check) check ;;
  *) sed -n '2,22p' "$0" >&2; exit 2 ;;
esac
