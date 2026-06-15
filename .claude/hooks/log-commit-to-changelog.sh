#!/usr/bin/env bash
#
# Hook PostToolUse(Bash) para el proyecto Argos.
#
# Tras cada comando Bash, comprueba si se creó un commit nuevo y, si es así,
# añade una entrada al CHANGELOG.md de la raíz del repositorio (lo más nuevo
# arriba). Lo ejecuta el harness de Claude Code, no Claude.
#
# El evento llega como JSON por stdin. Detección robusta de "commit nuevo":
#   1) el comando ejecutado menciona "git commit", y
#   2) el SHA de HEAD cambió respecto al último commit ya registrado.
# Esto ignora `git commit` fallidos, `git checkout`/`reset` (que mueven HEAD
# sin crear commits) y comandos que solo mencionan "git commit" de pasada.

set -uo pipefail

input="$(cat)"

# Salida rápida: si el evento ni siquiera menciona 'git commit', no hacemos
# nada. Evita arrancar jq/python tras cada comando Bash de la sesión.
case "$input" in
  *"git commit"*) ;;
  *) exit 0 ;;
esac

# Directorio de trabajo del evento, para situarnos en el repo correcto.
cwd=""
if command -v jq >/dev/null 2>&1; then
  cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
elif command -v python3 >/dev/null 2>&1; then
  cwd="$(printf '%s' "$input" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("cwd",""))' 2>/dev/null || true)"
fi
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || true

# A partir de aquí, todo depende de git: si algo falla, salimos sin ruido.
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

head_sha="$(git rev-parse HEAD 2>/dev/null)" || exit 0
[ -n "$head_sha" ] || exit 0

# Estado fuera del control de versiones: último commit ya registrado.
git_dir="$(git rev-parse --git-dir 2>/dev/null)" || exit 0
state_file="$git_dir/changelog-last-sha"
last_sha=""
[ -f "$state_file" ] && last_sha="$(cat "$state_file" 2>/dev/null || true)"

# Si HEAD no cambió, no hay commit nuevo que registrar.
[ "$head_sha" = "$last_sha" ] && exit 0

# Metadatos del commit nuevo.
short_sha="$(git log -1 --format=%h 2>/dev/null)"
subject="$(git log -1 --format=%s 2>/dev/null)"
author="$(git log -1 --format=%an 2>/dev/null)"
date="$(git log -1 --format=%cd --date=short 2>/dev/null)"
body="$(git log -1 --format=%b 2>/dev/null)"

root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
changelog="$root/CHANGELOG.md"
marker="<!-- nuevas entradas: se insertan automaticamente debajo de esta linea -->"

# Crear el CHANGELOG.md con su cabecera la primera vez.
if [ ! -f "$changelog" ]; then
  {
    printf '# Changelog\n\n'
    printf 'Registro automatico de cambios: una entrada por cada commit de git.\n'
    printf 'Generado por el hook `.claude/hooks/log-commit-to-changelog.sh`.\n\n'
    printf '%s\n' "$marker"
  } > "$changelog"
fi

# Construir la entrada en un archivo temporal (cuerpo opcional).
entry_file="$(mktemp)"
{
  printf '\n## %s - %s\n\n' "$date" "$subject"
  printf -- '- `%s` por %s\n' "$short_sha" "$author"
  if [ -n "$body" ]; then
    printf '\n%s\n' "$body"
  fi
} > "$entry_file"

# Insertar la entrada justo despues del marcador (lo mas nuevo queda arriba).
tmp="$(mktemp)"
awk -v marker="$marker" -v ef="$entry_file" '
  { print }
  index($0, marker) && !done {
    while ((getline line < ef) > 0) print line
    close(ef)
    done = 1
  }
' "$changelog" > "$tmp" && mv "$tmp" "$changelog"
rm -f "$entry_file"

# Recordar el commit registrado para no duplicarlo.
printf '%s' "$head_sha" > "$state_file"

exit 0
