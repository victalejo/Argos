#!/usr/bin/env bash
# Regenera los goldens de paridad Swift → Kotlin
# (android/core/src/test/resources/swift-golden/) con el código Swift REAL, ejecutando
# ArgosTests/GoldenParityTests con ARGOS_REGENERATE_GOLDENS=1.
#
# Uso:
#   scripts/regenerate-swift-goldens.sh [--check] [--without-building] [args extra de xcodebuild]
#
#   --check             regenera y falla si algún golden cambió (lo usa la CI: el diff
#                       queda en el registro).
#   --without-building  usa `test-without-building` (la CI ya compiló los tests).
#
# Después de regenerar, ajusta Kotlin hasta que `./gradlew :core:test` pase (en el
# servidor de compilación, nunca en el Mac).
set -euo pipefail

cd "$(dirname "$0")/.."

CHECK=0
ACTION=test
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --without-building) ACTION=test-without-building; shift ;;
    *) break ;;
  esac
done

GOLDENS=android/core/src/test/resources/swift-golden

# xcodebuild pasa al proceso de tests las variables TEST_RUNNER_<X> como <X>.
TEST_RUNNER_ARGOS_REGENERATE_GOLDENS=1 xcodebuild "$ACTION" \
  -project Argos.xcodeproj -scheme Argos -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:ArgosTests/GoldenParityTests \
  CODE_SIGNING_ALLOWED=NO "$@" >&2

if [ "$CHECK" = 1 ]; then
  # Archivos nuevos (sin seguimiento) también cuentan como deriva.
  untracked=$(git ls-files --others --exclude-standard -- "$GOLDENS")
  if ! git diff --exit-code -- "$GOLDENS" || [ -n "$untracked" ]; then
    [ -n "$untracked" ] && printf 'Goldens nuevos sin commitear:\n%s\n' "$untracked"
    echo "::error::Los goldens de Android no coinciden con el Swift actual. Ejecuta scripts/regenerate-swift-goldens.sh, commitea y ajusta Kotlin."
    exit 1
  fi
  echo "Goldens al día."
else
  git status --short -- "$GOLDENS"
fi
