#!/usr/bin/env bash
# Para el sshd temporal de `sshd-test-start.sh` (listener y sesiones abiertas) y borra su
# directorio. Es idempotente: sin directorio o sin proceso, no falla. Mata también lo que
# las sesiones dejaron corriendo (servidor tmux aislado, agentes simulados, vigilantes),
# reconociéndolo por su entorno (`TMUX_TMPDIR` de este directorio): nada más se toca.
#
# Uso: scripts/sshd-test-stop.sh [--keep] [directorio]
#   --keep     solo mata los procesos y conserva el directorio (clave de host, puerto y
#              configuración), para reiniciar después con `sshd-test-start.sh --dir`.
#   directorio por defecto: $ARGOS_SSHD_DIR o $ARGOS_E2E_SSHD_DIR.
set -uo pipefail

KEEP=0
DIR="${ARGOS_SSHD_DIR:-${ARGOS_E2E_SSHD_DIR:-}}"
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    *) DIR="$arg" ;;
  esac
done

if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
  echo "Sin directorio de sshd temporal: nada que parar." >&2
  exit 0
fi
# Protección: solo se borra un directorio que sea de sshd-test.
if [ ! -f "$DIR/sshd_config" ] || [ ! -f "$DIR/host_key" ]; then
  echo "$DIR no parece un directorio de sshd-test: no se toca." >&2
  exit 1
fi

PIDFILE="$DIR/sshd.pid"
if [ -f "$PIDFILE" ]; then
  PID="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    # Primero las sesiones hijas (sshd-session): matar solo al listener no cierra las
    # conexiones ya abiertas, y una caída real del servidor las corta todas.
    pkill -KILL -P "$PID" 2>/dev/null || true
    kill -KILL "$PID" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
  fi
  rm -f "$PIDFILE"
fi

# Procesos lanzados desde las sesiones de este sshd: heredan `TMUX_TMPDIR=$DIR/tmux`, que
# es único de este directorio. Linux: /proc/<pid>/environ; macOS: `ps -E`.
session_pids() {
  local marker="TMUX_TMPDIR=$DIR/tmux"
  if [ -d /proc/self ]; then
    for env_file in /proc/[0-9]*/environ; do
      pid="${env_file#/proc/}"; pid="${pid%/environ}"
      [ "$pid" = "$$" ] && continue
      # Solo procesos propios (los ajenos no se pueden leer… ni se deben tocar).
      [ -O "$env_file" ] || continue
      { tr '\0' '\n' < "$env_file"; } 2>/dev/null | grep -qxF -- "$marker" && echo "$pid"
    done
  else
    ps -axE -o pid=,command= 2>/dev/null | grep -F -- " $marker" | grep -vF grep | awk '{print $1}' \
      | grep -vx "$$" || true
  fi
}
if [ "$KEEP" -eq 0 ] && [ -d "$DIR/tmux" ]; then
  LEFT="$(session_pids | tr '\n' ' ')"
  if [ -n "${LEFT// /}" ]; then
    # shellcheck disable=SC2086
    kill -TERM $LEFT 2>/dev/null || true
    sleep 1
    LEFT="$(session_pids | tr '\n' ' ')"
    # shellcheck disable=SC2086
    [ -z "${LEFT// /}" ] || kill -KILL $LEFT 2>/dev/null || true
  fi
fi

if [ "$KEEP" -eq 0 ]; then
  rm -rf "$DIR"
  echo "sshd temporal parado y $DIR borrado." >&2
else
  echo "sshd temporal parado (se conserva $DIR)." >&2
fi
