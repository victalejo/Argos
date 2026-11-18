//
//  CheckpointScript.swift
//  ArgosCore
//
//  Script POSIX de los puntos de restauración por turno. El MISMO texto se instala en
//  el servidor (`~/.config/argos/claude-checkpoint-v1.sh`, que ejecuta el hook
//  `UserPromptSubmit` de Claude Code) y viaja entero en cada comando de la app
//  (`sh -c '<script>' argos-checkpoint <modo> …`): leer y restaurar no dependen de lo
//  instalado. Se ejecuta de verdad con /bin/sh y dash en `CheckpointScriptTests`.
//
//  Garantías: al capturar nunca toca el árbol de trabajo ni el índice real (usa un índice
//  privado, `.git/argos-checkpoint.index`), respeta `.gitignore`, se rinde en silencio ante
//  un repo enorme o una operación de git a medias y, en modo hook, no escribe nada en
//  stdout (Claude lo tomaría como contexto). Android debe portar este texto byte a byte.
//

import Foundation

enum CheckpointScript {

    /// Versión del script: va en el nombre del archivo instalado (y por tanto en el
    /// comando del hook), así que subirla hace que las instalaciones antiguas se
    /// actualicen solas (`ClaudeHookInstaller.isInstalled` deja de casar).
    static let version = 1

    /// Ruta del script en el servidor, relativa a `$HOME`.
    static let installedRelativePath = ".config/argos/claude-checkpoint-v\(version).sh"

    /// Archivo cuya existencia desactiva la captura en todo el servidor.
    static let serverOffRelativePath = ".config/argos/checkpoints-off"

    /// Puntos que se conservan por repositorio (y worktree).
    static let maxCheckpoints = 30

    /// Prefijo de las refs (`refs/argos/checkpoints/<worktree>/<epoch>`).
    static let refPrefix = "refs/argos/checkpoints/"

    /// `$0` del script cuando la app lo ejecuta con `sh -c`.
    static let processName = "argos-checkpoint"

    static let source = #"""
# argos-checkpoint 1
# Puntos de restauracion por turno de Argos. Lo instala y reescribe Argos: no lo edites.
# Desactivarlo en este servidor: crea ~/.config/argos/checkpoints-off
# Desactivarlo en un repositorio: git config argos.checkpoints false
LC_ALL=C; export LC_ALL
unset GIT_INDEX_FILE
umask 077
cp_max=30
cp_untracked_max=1000
cp_file_max=20971520
cp_limit=8
cp_off="$HOME/.config/argos/checkpoints-off"
cp_reason=

cp_git() { git --literal-pathspecs -c core.quotepath=off "$@"; }
cp_ix() { GIT_INDEX_FILE=$1; export GIT_INDEX_FILE; shift; "$@"; cp_rc=$?; unset GIT_INDEX_FILE; return $cp_rc; }
cp_timed() { if command -v timeout >/dev/null 2>&1; then timeout "$cp_limit" "$@"; else "$@"; fi; }

# Entra en la raiz del repositorio de $1. Fija cp_top, cp_gitdir y cp_ns (refs del worktree).
cp_enter() {
  cd "$1" 2>/dev/null || return 1
  [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || return 1
  cp_top=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$cp_top" ] && cd "$cp_top" || return 1
  cp_gitdir=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd -P) || return 1
  cp_common=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P) || return 1
  if [ "$cp_gitdir" = "$cp_common" ]; then cp_wt=main
  else cp_wt="w-$(printf '%s' "${cp_gitdir##*/}" | tr -c 'A-Za-z0-9_-' '_')"; fi
  cp_ns="refs/argos/checkpoints/$cp_wt"
}

# Operacion de git a medias (rebase, merge, cherry-pick, revert, bisect): imprime cual.
cp_busy() {
  for cp_f in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
    [ -e "$cp_gitdir/$cp_f" ] && { printf '%s' "$cp_f"; return 0; }
  done
  return 1
}

cp_disabled() {
  [ -e "$cp_off" ] && return 0
  [ "$(git config --bool argos.checkpoints 2>/dev/null)" = false ]
}

# Si no existe el indice privado $1, lo crea copiando otro (aprovecha su cache de stat).
cp_seed() {
  [ -f "$1" ] && return 0
  for cp_from in "$cp_gitdir/argos-checkpoint.index" "$cp_gitdir/index"; do
    [ -f "$cp_from" ] && { cp "$cp_from" "$1.seed$$" 2>/dev/null && mv -f "$1.seed$$" "$1"; return 0; }
  done
  return 0
}

# Demasiados archivos nuevos sin ignorar (respecto al indice $1) o alguno enorme: no se captura.
cp_guard() {
  cp_list=$(cp_ix "$1" cp_git ls-files -o --exclude-standard 2>/dev/null | head -n $((cp_untracked_max + 1)))
  [ -z "$cp_list" ] && return 0
  cp_n=$(printf '%s\n' "$cp_list" | wc -l | tr -d ' ')
  [ "$cp_n" -gt "$cp_untracked_max" ] && { cp_reason="mas de $cp_untracked_max archivos nuevos sin ignorar"; return 1; }
  cp_big=$(printf '%s\n' "$cp_list" | while IFS= read -r cp_p; do
    [ -f "$cp_p" ] && [ ! -L "$cp_p" ] || continue
    set -- $(wc -c < "$cp_p" 2>/dev/null)
    [ "${1:-0}" -gt "$cp_file_max" ] && { printf '%s' "$cp_p"; break; }
  done)
  [ -n "$cp_big" ] && { cp_reason="archivo nuevo de mas de 20 MB: $cp_big"; return 1; }
  return 0
}

# Arbol del arbol de trabajo (respeta .gitignore) en cp_tree, con el indice privado $1.
# $2 = guard: aplica los limites; $3 = timed: con plazo.
cp_write_tree() {
  [ -e "$1.lock" ] && [ -n "$(find "$1.lock" -mmin +1 2>/dev/null)" ] && rm -f "$1.lock"
  if [ "$2" = guard ] && ! cp_guard "$1"; then return 1; fi
  if [ "$3" = timed ]; then cp_ix "$1" cp_timed git add -A >/dev/null 2>&1
  else cp_ix "$1" git add -A >/dev/null 2>&1; fi || { cp_reason="git add no termino a tiempo o fallo"; return 1; }
  cp_tree=$(cp_ix "$1" git write-tree 2>/dev/null) && [ -n "$cp_tree" ] || { cp_reason="git write-tree fallo"; return 1; }
}

# Arbol actual sin tocar el indice de captura (copia privada por invocacion).
cp_current_tree() {
  cp_view="$cp_gitdir/argos-checkpoint-view.index"
  cp_tmpview="$cp_view.$$"
  rm -f "$cp_tmpview"
  if [ -f "$cp_view" ]; then cp "$cp_view" "$cp_tmpview"; else cp_seed "$cp_tmpview"; fi
  if cp_write_tree "$cp_tmpview" "$1" untimed; then mv -f "$cp_tmpview" "$cp_view"; return 0; fi
  rm -f "$cp_tmpview" "$cp_tmpview.lock"; return 1
}

# Crea el punto: $1 tipo, $2 extracto, $3 sesion, $4 guard|full, $5 timed|untimed.
# Deja cp_ref, cp_commit y cp_tree; imprime ARGOS_CP_NEW / ARGOS_CP_SAME / ARGOS_CP_SKIP.
cp_capture() {
  cp_index="$cp_gitdir/argos-checkpoint.index"
  cp_seed "$cp_index"
  if ! cp_write_tree "$cp_index" "$4" "$5"; then
    printf '%s %s\n' "$(date +%s)" "$cp_reason" > "$cp_gitdir/argos-checkpoint.skip" 2>/dev/null
    printf 'ARGOS_CP_SKIP %s\n' "$cp_reason"; return 1
  fi
  rm -f "$cp_gitdir/argos-checkpoint.skip"
  set -- "$@" $(git for-each-ref --sort=-refname --count=1 --format='%(refname) %(objectname)' "$cp_ns/" 2>/dev/null)
  if [ -n "$7" ] && [ "$(git rev-parse -q --verify "$7^{tree}" 2>/dev/null)" = "$cp_tree" ]; then
    cp_ref=$6; cp_commit=$7
    printf 'ARGOS_CP_SAME %s %s\n' "$cp_ref" "$cp_commit"; return 0
  fi
  cp_head=$(git rev-parse -q --verify HEAD 2>/dev/null)
  cp_msg=$(printf '%s\n\nArgos-Checkpoint: 1\nArgos-Kind: %s\nArgos-Session: %s' "${2:-(sin mensaje)}" "$1" "${3:--}")
  export GIT_AUTHOR_NAME=Argos GIT_AUTHOR_EMAIL=argos@localhost GIT_COMMITTER_NAME=Argos GIT_COMMITTER_EMAIL=argos@localhost
  if [ -n "$cp_head" ]; then
    cp_commit=$(printf '%s\n' "$cp_msg" | git -c commit.gpgsign=false commit-tree "$cp_tree" -p "$cp_head" 2>/dev/null)
  else
    cp_commit=$(printf '%s\n' "$cp_msg" | git -c commit.gpgsign=false commit-tree "$cp_tree" 2>/dev/null)
  fi
  [ -n "$cp_commit" ] || { cp_reason="git commit-tree fallo"; printf 'ARGOS_CP_SKIP %s\n' "$cp_reason"; return 1; }
  cp_base="$cp_ns/$(date +%s)"; cp_ref=$cp_base; cp_i=1
  while ! git update-ref -m argos-checkpoint "$cp_ref" "$cp_commit" "" 2>/dev/null; do
    [ "$cp_i" -gt 20 ] && { cp_reason="git update-ref fallo"; printf 'ARGOS_CP_SKIP %s\n' "$cp_reason"; return 1; }
    cp_ref="$cp_base-$(printf '%02d' "$cp_i")"; cp_i=$((cp_i + 1))
  done
  [ "$1" = restore ] || cp_prune
  printf 'ARGOS_CP_NEW %s %s\n' "$cp_ref" "$cp_commit"
}

# Conserva los cp_max puntos mas recientes de este worktree.
cp_prune() {
  git for-each-ref --sort=-refname --format='%(refname)' "$cp_ns/" | sed -n "$((cp_max + 1)),\$p" \
    | while IFS= read -r cp_r; do git update-ref -d "$cp_r" 2>/dev/null; done
}

# Entrada del hook (JSON) -> "sesion<TAB>extracto de una linea", sin jq ni python.
cp_awk='
function dec(t,   o, j, c, d) {
  o = ""
  for (j = 1; j <= length(t); j++) {
    c = substr(t, j, 1)
    if (c != "\\") { o = o c; continue }
    j++; d = substr(t, j, 1)
    if (d == "u") { j += 4; o = o " " }
    else if (d == "n" || d == "t" || d == "r" || d == "b" || d == "f") o = o " "
    else o = o d
  }
  return o
}
{ s = s $0 "\n" }
END {
  n = length(s); i = 1; depth = 0; expect = "key"
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\"") {
      rest = substr(s, i)
      if (!match(rest, /^"([^"\\]|\\.)*"/)) break
      raw = substr(rest, 2, RLENGTH - 2); i += RLENGTH
      if (depth == 1 && expect == "key") { key = raw; expect = "colon" }
      else if (depth == 1 && expect == "value") {
        if (key == "session_id") sid = raw; else if (key == "prompt") prompt = raw
        expect = "after"
      }
      continue
    }
    if (c == "{" || c == "[") depth++
    else if (c == "}" || c == "]") depth--
    else if (c == ":" && depth == 1) expect = "value"
    else if (c == "," && depth == 1) expect = "key"
    i++
  }
  gsub(/[^A-Za-z0-9_-]/, "", sid)
  p = dec(substr(prompt, 1, 600))
  gsub(/[[:cntrl:]]/, " ", p); gsub(/  +/, " ", p); sub(/^ /, "", p); sub(/ $/, "", p)
  if (length(p) > 160) p = substr(p, 1, 157) "..."
  printf "%s\t%s", substr(sid, 1, 80), p
}'

cp_hook() {
  cp_input=$(awk "$cp_awk" 2>/dev/null)
  exec >/dev/null 2>&1
  cp_enter . || exit 0
  cp_disabled && exit 0
  cp_busy && exit 0
  cp_tab=$(printf '\t')
  cp_capture prompt "${cp_input#*"$cp_tab"}" "${cp_input%%"$cp_tab"*}" guard timed
  exit 0
}

cp_require() {
  command -v git >/dev/null 2>&1 || { echo ARGOS_CP_NOGIT; exit 0; }
  cp_enter "$1" || { echo ARGOS_CP_NOREPO; exit 0; }
}

cp_state() {
  if [ -e "$cp_off" ]; then echo off-server
  elif [ "$(git config --bool argos.checkpoints 2>/dev/null)" = false ]; then echo off-repo
  else echo on; fi
}

# Arbol de $1 ("-" = el arbol de trabajo actual, sin limites).
cp_resolve() {
  if [ "$1" = - ]; then cp_current_tree full && printf '%s' "$cp_tree"
  else git rev-parse -q --verify "$1^{tree}" 2>/dev/null; fi
}

cp_list() {
  echo "ARGOS_CP_LIST 1"
  echo "ARGOS_CP_STATE $(cp_state)"
  echo "ARGOS_CP_ROOT $cp_top"
  [ -f "$cp_gitdir/argos-checkpoint.skip" ] && printf 'ARGOS_CP_SKIPPED %s\n' "$(head -n 1 "$cp_gitdir/argos-checkpoint.skip")"
  echo "ARGOS_CP_HEAD $(git rev-parse -q --verify HEAD 2>/dev/null || echo -)"
  if cp_current_tree guard; then cp_newer=$cp_tree; else cp_newer=; echo "ARGOS_CP_CURRENT_SKIPPED $cp_reason"; fi
  git for-each-ref --sort=-refname --format='%(objectname)' "$cp_ns/" | while IFS= read -r cp_c; do
    if [ -n "$cp_newer" ]; then
      printf 'ARGOS_CP_COUNT %s %s\n' "$cp_c" "$(git diff-tree -r -z --no-renames --name-only "$cp_c" "$cp_newer" | tr -cd '\000' | wc -c | tr -d ' ')"
    fi
    cp_newer=$cp_c
  done
  echo "ARGOS_CP_META"
  git for-each-ref --sort=-refname \
    --format='%(refname)%1f%(objectname)%1f%(parent)%1f%(committerdate:unix)%1f%(contents)%1e' "$cp_ns/"
}

cp_pair() {
  cp_a=$(cp_resolve "$1") && [ -n "$cp_a" ] || { echo ARGOS_CP_BADREF; exit 4; }
  cp_b=$(cp_resolve "$2") && [ -n "$cp_b" ] || { echo ARGOS_CP_BADREF; exit 4; }
}

cp_files() {
  cp_pair "$1" "$2"
  echo ARGOS_CP_FILES
  git diff-tree -r -z --no-renames --name-status "$cp_a" "$cp_b"
}

cp_diff() {
  cp_pair "$1" "$2"
  cp_git diff --no-color --no-ext-diff --no-renames "$cp_a" "$cp_b" -- "$3" | head -c "$4"
}

# Que cambiaria al restaurar $1 respecto al arbol actual: A recrear, D borrar, M/T modificar.
cp_preview() {
  cp_op=$(cp_busy) && { echo "ARGOS_CP_BUSY $cp_op"; exit 0; }
  cp_s=$(git rev-parse -q --verify "$1^{commit}" 2>/dev/null) || { echo ARGOS_CP_BADREF; exit 4; }
  cp_current_tree full || { echo "ARGOS_CP_FAILED $cp_reason"; exit 5; }
  echo "ARGOS_CP_CURRENT $cp_tree"
  cp_parent=$(git rev-parse -q --verify "$cp_s^" 2>/dev/null)
  cp_head=$(git rev-parse -q --verify HEAD 2>/dev/null)
  if [ -n "$cp_parent" ] && [ -n "$cp_head" ] && [ "$cp_parent" != "$cp_head" ]; then
    echo "ARGOS_CP_HEADMOVED $(git rev-list --count "$cp_parent..$cp_head" 2>/dev/null || echo 0)"
  fi
  echo ARGOS_CP_FILES
  git diff-tree -r -z --no-renames --name-status "$cp_tree" "$cp_s"
}

# Restaura el punto $1 (todo, o solo la ruta $3). $2 = arbol visto en la vista previa
# ("-" = sin comprobar). Antes crea otro punto con el estado actual (deshacer lo deshecho).
cp_restore() {
  cp_op=$(cp_busy) && { echo "ARGOS_CP_BUSY $cp_op"; exit 0; }
  cp_s=$(git rev-parse -q --verify "$1^{commit}" 2>/dev/null) || { echo ARGOS_CP_BADREF; exit 4; }
  cp_label="Antes de restaurar: $(git log -1 --format=%s "$cp_s" 2>/dev/null | cut -c1-120)"
  cp_capture restore "$cp_label" - full untimed || { echo "ARGOS_CP_FAILED no se pudo crear la copia previa: $cp_reason"; exit 5; }
  cp_backup=$cp_commit
  if [ "$2" != - ] && [ "$cp_tree" != "$2" ]; then echo ARGOS_CP_CHANGED; exit 0; fi
  cp_tmp="$cp_gitdir/argos-restore.$$.index"
  trap 'rm -f "$cp_tmp" "$cp_tmp.lock"' EXIT
  if [ -n "$3" ]; then
    if git cat-file -e "$cp_s:$3" 2>/dev/null; then
      cp_ix "$cp_tmp" git read-tree "$cp_s" && cp_ix "$cp_tmp" git checkout-index -f -- "$3" \
        || { echo ARGOS_CP_FAILED checkout-index; exit 5; }
    elif git cat-file -e "$cp_backup:$3" 2>/dev/null; then
      cp_ix "$cp_tmp" git read-tree "$cp_backup" && cp_ix "$cp_tmp" cp_git rm -q -f -- "$3" >/dev/null \
        || { echo ARGOS_CP_FAILED rm; exit 5; }
    fi
    echo ARGOS_CP_DONE; exit 0
  fi
  cp_ix "$cp_tmp" git read-tree "$cp_s" || { echo ARGOS_CP_FAILED read-tree; exit 5; }
  # Primero se borra lo que no existia (no ignorado, con el .gitignore de AHORA) y luego se
  # traen los archivos del punto: asi un .env que hoy se ignora nunca se toca.
  cp_ix "$cp_tmp" git clean -f -d -q >/dev/null 2>&1 || { echo ARGOS_CP_FAILED clean; exit 5; }
  git diff-tree -r -z --no-renames --name-only --diff-filter=AMT "$cp_backup" "$cp_s" \
    | cp_ix "$cp_tmp" git checkout-index -f -z --stdin || { echo ARGOS_CP_FAILED checkout-index; exit 5; }
  cp_want=$(git rev-parse "$cp_s^{tree}")
  if cp_current_tree full && [ "$cp_tree" = "$cp_want" ]; then echo ARGOS_CP_DONE
  else echo ARGOS_CP_PARTIAL; fi
}

cp_main() {
  cp_mode=${1:-hook}; [ $# -gt 0 ] && shift
  case $cp_mode in
    hook) cp_hook ;;
    list) cp_require "$1"; cp_list ;;
    snapshot) cp_require "$1"; cp_op=$(cp_busy) && { echo "ARGOS_CP_BUSY $cp_op"; exit 0; }
      cp_capture manual "$2" - full untimed ;;
    files) cp_require "$1"; cp_files "$2" "$3" ;;
    diff) cp_require "$1"; cp_diff "$2" "$3" "$4" "$5" ;;
    preview) cp_require "$1"; cp_preview "$2" ;;
    restore) cp_require "$1"; cp_restore "$2" "$3" "$4" ;;
    server-off) mkdir -p "${cp_off%/*}" && : > "$cp_off" && echo ARGOS_CP_OK ;;
    server-on) rm -f "$cp_off" && echo ARGOS_CP_OK ;;
    *) echo ARGOS_CP_USAGE; exit 2 ;;
  esac
}
cp_main "$@"
"""#
}
