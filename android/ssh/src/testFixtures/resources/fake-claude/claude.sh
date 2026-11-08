#!/bin/sh
# «claude» SIMULADO para los tests de integración y el devServer de Argos. NO llama a ninguna
# API ni consume nada: reproduce un guion con el protocolo stream-json del CLI real (forma de
# los eventos: core/src/test/resources/agent-stream-real.ndjson).
#
# Guion: los turnos impares piden permiso para `Write` (al aprobar crea el archivo en la carpeta
# de trabajo, al denegar no); los pares responden solo con texto markdown. Un prompt con
# `#lento` responde solo con texto, en varios pasos separados por pausas.
#
#   claude auth status --json   logueado, salvo que exista ~/.fake-claude-logged-out
#   ~/.fake-claude-test/        (si existe) modo test: sin pausas, registra argumentos, token
#                               y stdin ahí. Fuera de ese modo NUNCA se escribe el token.
#
# POSIX sh estricto: debe funcionar con dash (CI) y con el /bin/sh de macOS.

LC_ALL=C
export LC_ALL

test_dir="$HOME/.fake-claude-test"

auth_status() {
  if [ -e "$HOME/.fake-claude-logged-out" ]; then
    printf '%s\n' '{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}'
    return 1
  fi
  printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"demo@argos.invalid","orgName":"Argos (simulado)","subscriptionType":"max"}'
}

case "${1:-}" in
  auth)
    case "${2:-}" in
      status) auth_status; exit $? ;;
      *) echo "claude simulado: login no disponible; borra ~/.fake-claude-logged-out" >&2; exit 1 ;;
    esac
    ;;
  --version | -v)
    echo "0.0.0 (claude simulado)"
    exit 0
    ;;
esac

print_mode=0
input_format=""
output_format=""
prompt_tool=""
replay=0
permission_mode=""
session=""
resumed=0
all_args="$*"

while [ $# -gt 0 ]; do
  case "$1" in
    -p | --print) print_mode=1 ;;
    --verbose) ;;
    --replay-user-messages) replay=1 ;;
    --input-format) input_format="$2"; shift ;;
    --output-format) output_format="$2"; shift ;;
    --permission-prompt-tool) prompt_tool="$2"; shift ;;
    --permission-mode) permission_mode="$2"; shift ;;
    --session-id) session="$2"; shift ;;
    --resume) session="$2"; resumed=1; shift ;;
    *) echo "error: unknown option '$1'" >&2; exit 2 ;;
  esac
  shift
done

if [ "$print_mode" != 1 ] || [ "$input_format" != stream-json ] || [ "$output_format" != stream-json ] ||
  [ "$prompt_tool" != stdio ] || [ "$replay" != 1 ] || [ -z "$permission_mode" ] || [ -z "$session" ]; then
  echo "error: claude simulado: faltan flags del modo persistente: $all_args" >&2
  exit 2
fi

if [ -d "$test_dir" ]; then
  in_test=1
  max_life=900
  printf '%s\n' "$all_args" >>"$test_dir/$session.args"
  printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN:-}" >"$test_dir/$session.token"
  printf '%s' "${ARGOS_OAUTH:-}" >"$test_dir/$session.leaked"
else
  in_test=0
  max_life=14400
fi

# Vigía: si los tests o el devServer mueren sin poder limpiar, el simulado no queda huérfano
# (termina al desaparecer el HOME o al agotar su vida máxima). Sale a los segundos de morir él.
main_pid=$$
(
  waited=0
  while kill -0 "$main_pid" 2>/dev/null && [ -d "$HOME" ] && [ "$waited" -lt "$max_life" ]; do
    sleep 2
    waited=$((waited + 2))
  done
  kill "$main_pid" 2>/dev/null
) </dev/null >/dev/null 2>&1 &

turn_file="$HOME/.config/argos/agents/$session/fake-turns"
turn=$(cat "$turn_file" 2>/dev/null)
turn=${turn:-0}
pending_id=""
pending_file=""
first_turn=1
model="claude-simulado"
cwd_json=$(pwd | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')

emit() { printf '%s\n' "$1"; }
pause() { if [ "$in_test" = 0 ]; then sleep 1; fi; }

assistant() {
  emit "{\"type\":\"assistant\",\"message\":{\"id\":\"msg_simulado_$turn\",\"role\":\"assistant\",\"content\":[$1],\"model\":\"$model\"},\"session_id\":\"$session\",\"parent_tool_use_id\":null}"
}

assistant_text() { assistant "{\"type\":\"text\",\"text\":$1}"; }

tool_result() {
  emit "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_simulado_$turn\",\"content\":$1,\"is_error\":$2}]},\"session_id\":\"$session\",\"parent_tool_use_id\":null}"
}

result() {
  emit "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":$1,\"total_cost_usd\":0,\"duration_ms\":1,\"num_turns\":1,\"session_id\":\"$session\"}"
}

start_turn() {
  if [ "$first_turn" = 1 ]; then
    emit '{"type":"system","subtype":"hook_started","hook_event":"SessionStart","hook_name":"SessionStart:startup"}'
    first_turn=0
  fi
  emit "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$session\",\"model\":\"$model\",\"cwd\":\"$cwd_json\",\"permissionMode\":\"$permission_mode\"}"
  emit '{"type":"rate_limit_event"}'
}

ask_write_permission() {
  pending_file="notas-argos-$turn.md"
  pending_id="00000000-0000-4000-8000-$(printf '%012d' "$turn")"
  input="{\"file_path\":\"$cwd_json/$pending_file\",\"content\":\"# Notas de Argos\\n\"}"
  assistant_text '"Voy a dejar unas **notas** en la carpeta del proyecto:\n\n- qué se ha hecho\n- `próximos pasos`\n\nNecesito tu permiso para crear el archivo."'
  assistant "{\"type\":\"thinking\",\"thinking\":\"(pensamiento simulado del turno $turn)\"}"
  pause
  assistant "{\"type\":\"tool_use\",\"id\":\"toolu_simulado_$turn\",\"name\":\"Write\",\"input\":$input}"
  emit "{\"type\":\"control_request\",\"request_id\":\"$pending_id\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"Write\",\"input\":$input,\"tool_use_id\":\"toolu_simulado_$turn\",\"display_name\":\"Write\"}}"
}

answer_with_text() {
  if [ -f "notas-argos-$((turn - 1)).md" ]; then
    state='Las notas del turno anterior **ya están** en la carpeta.'
  else
    state='En el turno anterior **no** se creó ningún archivo.'
  fi
  text="\"## Resumen\\n\\n$state\\n\\n| Turno | Estado |\\n|---|---|\\n| $turn | hecho |\\n\\n\`\`\`sh\\nls -la\\n\`\`\`\""
  pause
  assistant_text "$text"
  result "\"Turno $turn terminado.\""
}

answer_slowly() {
  assistant_text '"Empiezo, **sin prisa**."'
  sleep 1
  assistant_text '"Sigo trabajando…"'
  sleep 1
  assistant_text '"Terminado."'
  result '"Terminado."'
}

handle_user() {
  text=$(printf '%s\n' "$line" | sed -n -E 's/^.*"content":("([^"\\]|\\.)*"),"role":"user".*$/\1/p')
  emit "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":${text:-\"\"}},\"session_id\":\"$session\",\"parent_tool_use_id\":null}"
  if [ -n "$pending_id" ]; then
    assistant_text '"Sigo esperando tu decisión sobre `Write`."'
    return
  fi
  turn=$((turn + 1))
  printf '%s' "$turn" 2>/dev/null >"$turn_file"
  start_turn
  case "$text" in
    *'#lento'*) answer_slowly; return ;;
  esac
  if [ $((turn % 2)) = 1 ]; then ask_write_permission; else answer_with_text; fi
}

handle_permission_response() {
  case "$line" in
    *"\"request_id\":\"$pending_id\""*) ;;
    *) return ;;
  esac
  [ -n "$pending_id" ] || return
  pending_id=""
  case "$line" in
    *'"response":{"behavior":"allow"'*)
      printf '# Notas de Argos\n' >"$pending_file"
      pause
      tool_result "\"File created successfully at: $cwd_json/$pending_file\"" false
      assistant_text "\"He creado \`$pending_file\`.\""
      result "\"He creado \`$pending_file\`.\""
      ;;
    *)
      message=$(printf '%s\n' "$line" | sed -n -E 's/^.*"message":("([^"\\]|\\.)*").*$/\1/p')
      pause
      tool_result "${message:-\"Denegado.\"}" true
      assistant_text '"De acuerdo: **no** he creado el archivo."'
      result '"Permiso denegado: no he creado el archivo."'
      ;;
  esac
}

while IFS= read -r line; do
  if [ "$in_test" = 1 ]; then printf '%s\n' "$line" >>"$test_dir/$session.stdin"; fi
  case "$line" in
    *'"type":"control_response"'*) handle_permission_response ;;
    *'"type":"user"'*) handle_user ;;
  esac
done
