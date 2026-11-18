#!/usr/bin/env bash
# Arranca un sshd TEMPORAL como el usuario actual (sin root) en 127.0.0.1, para los tests
# de integración de Argos (ArgosTests/Integration*). Nada de esto toca ~/.ssh ni el sshd
# del sistema: clave de host, clave de usuario Ed25519 sin passphrase, authorized_keys y
# configuración viven en un directorio temporal, y las sesiones remotas ven un HOME propio
# (`$DIR/home`).
#
# Uso:
#   scripts/sshd-test-start.sh [--max-sessions N] [--port P] [--dir D]
#
# Variables (alternativa a las opciones): ARGOS_SSHD_MAX_SESSIONS (def. 4), ARGOS_SSHD_PORT
# (def. uno libre), ARGOS_SSHD_DIR (def. mktemp). Si el directorio ya contiene una
# configuración (reinicio tras `sshd-test-stop.sh --keep`), se REUSA tal cual —misma clave
# de host, mismo puerto— para que la verificación TOFU de Argos no vea un cambio.
#
# Salida (stdout): líneas `CLAVE=valor` (sin comillas; las rutas no llevan espacios):
#   ARGOS_E2E_SSH_HOST, ARGOS_E2E_SSH_PORT, ARGOS_E2E_SSH_USER, ARGOS_E2E_SSH_KEY,
#   ARGOS_E2E_SSH_MAX_SESSIONS, ARGOS_E2E_SSHD_DIR
# Los mensajes de diagnóstico van a stderr. Con GITHUB_ENV definido, las mismas variables
# se añaden ahí con el prefijo TEST_RUNNER_ (así llegan al proceso de test de xcodebuild).
set -euo pipefail

SSHD_BIN="${ARGOS_SSHD_BIN:-/usr/sbin/sshd}"
MAX_SESSIONS="${ARGOS_SSHD_MAX_SESSIONS:-}"
PORT="${ARGOS_SSHD_PORT:-}"
DIR="${ARGOS_SSHD_DIR:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --max-sessions) MAX_SESSIONS="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    *) echo "Opción desconocida: $1" >&2; exit 2 ;;
  esac
done

[ -x "$SSHD_BIN" ] || { echo "No existe $SSHD_BIN" >&2; exit 1; }
if [ -n "$MAX_SESSIONS" ]; then
  if ! [[ "$MAX_SESSIONS" =~ ^[0-9]+$ ]] || [ "$MAX_SESSIONS" -lt 1 ]; then
    echo "--max-sessions debe ser un entero >= 1" >&2
    exit 2
  fi
fi

# Directorio corto (las rutas de /var/folders son largas para ciertos sockets).
if [ -z "$DIR" ]; then
  DIR="$(mktemp -d /tmp/argos-sshd.XXXXXX)"
fi
mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd -P)"
chmod 700 "$DIR"

CONFIG="$DIR/sshd_config"
PIDFILE="$DIR/sshd.pid"
USER_NAME="$(id -un)"

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "Ya hay un sshd en marcha para $DIR (pid $(cat "$PIDFILE"))." >&2
  exit 1
fi

if [ ! -f "$CONFIG" ]; then
  MAX_SESSIONS="${MAX_SESSIONS:-4}"
  if [ -z "$PORT" ]; then
    PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
  fi
  ssh-keygen -q -t ed25519 -N '' -C argos-test-host -f "$DIR/host_key"
  ssh-keygen -q -t ed25519 -N '' -C argos-test-user -f "$DIR/user_key"
  cp "$DIR/user_key.pub" "$DIR/authorized_keys"
  chmod 600 "$DIR/authorized_keys" "$DIR/host_key" "$DIR/user_key"

  SFTP_SERVER=""
  for candidate in /usr/libexec/sftp-server /usr/lib/openssh/sftp-server /usr/lib/ssh/sftp-server /usr/libexec/openssh/sftp-server; do
    if [ -x "$candidate" ]; then SFTP_SERVER="$candidate"; break; fi
  done
  [ -n "$SFTP_SERVER" ] || { echo "No se encontró sftp-server" >&2; exit 1; }

  # HOME aislado: lo que Argos escriba en ~ del servidor (skill de puertos, hooks,
  # ~/.config/argos…) cae aquí y no en el HOME real de quien ejecuta los tests.
  mkdir -p "$DIR/home"

  cat > "$CONFIG" <<CFG
Port $PORT
ListenAddress 127.0.0.1
HostKey $DIR/host_key
PidFile $PIDFILE
AuthorizedKeysFile $DIR/authorized_keys
AllowUsers $USER_NAME
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PermitRootLogin no
MaxSessions $MAX_SESSIONS
MaxStartups 100:30:200
SetEnv HOME=$DIR/home
LogLevel INFO
Subsystem sftp $SFTP_SERVER
CFG
else
  PORT="$(awk '$1 == "Port" { print $2 }' "$CONFIG")"
  # Reinicio: MaxSessions solo cambia si se pide explícitamente; el resto se conserva.
  if [ -n "$MAX_SESSIONS" ]; then
    sed -i.bak -E "s/^MaxSessions .*/MaxSessions $MAX_SESSIONS/" "$CONFIG"
    rm -f "$CONFIG.bak"
  else
    MAX_SESSIONS="$(awk '$1 == "MaxSessions" { print $2 }' "$CONFIG")"
  fi
fi

"$SSHD_BIN" -t -f "$CONFIG" || { echo "Configuración de sshd inválida ($CONFIG)" >&2; exit 1; }
# Sin -D: se desacopla solo y escribe PidFile. -E: registro a archivo, para diagnosticar.
"$SSHD_BIN" -f "$CONFIG" -E "$DIR/sshd.log"

# Espera a que acepte conexiones.
for _ in $(seq 1 50); do
  if [ -f "$PIDFILE" ] && nc -z 127.0.0.1 "$PORT" 2>/dev/null; then break; fi
  sleep 0.1
done
if ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  echo "sshd no escucha en 127.0.0.1:$PORT. Registro:" >&2
  tail -n 20 "$DIR/sshd.log" >&2 || true
  exit 1
fi

# Comprobación real de autenticación (sin tocar ~/.ssh ni el known_hosts del usuario).
if ! ssh -p "$PORT" -i "$DIR/user_key" -o IdentitiesOnly=yes -o BatchMode=yes \
     -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
     "$USER_NAME@127.0.0.1" true 2>"$DIR/probe.err"; then
  echo "sshd arrancó pero no autentica con la clave temporal:" >&2
  cat "$DIR/probe.err" >&2
  tail -n 20 "$DIR/sshd.log" >&2 || true
  exit 1
fi

echo "sshd temporal en 127.0.0.1:$PORT (pid $(cat "$PIDFILE"), MaxSessions $MAX_SESSIONS, dir $DIR)" >&2

VARS=(
  "ARGOS_E2E_SSH_HOST=127.0.0.1"
  "ARGOS_E2E_SSH_PORT=$PORT"
  "ARGOS_E2E_SSH_USER=$USER_NAME"
  "ARGOS_E2E_SSH_KEY=$DIR/user_key"
  "ARGOS_E2E_SSH_MAX_SESSIONS=$MAX_SESSIONS"
  "ARGOS_E2E_SSHD_DIR=$DIR"
)
printf '%s\n' "${VARS[@]}"
if [ -n "${GITHUB_ENV:-}" ]; then
  for line in "${VARS[@]}"; do
    printf 'TEST_RUNNER_%s\n' "$line" >> "$GITHUB_ENV"
  done
fi
