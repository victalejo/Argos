//
//  ClaudeTaskModelScript.swift
//  ArgosCore
//
//  Modelo y esfuerzo de los encargos en la TERMINAL (texto de script; lógica pura). El
//  despachador (`ClaudeTaskScript`) incluye `functions` y:
//   - antes de pegar el encargo llama a `set_model <encargo> <panel>`, que escribe
//     `/model <alias>` y `/effort <nivel>` en el Claude Code de ese panel;
//   - al terminar o pausarse, `restore_model <encargo>` vuelve a poner lo que había.
//
//  Claude Code interactivo GUARDA lo que se elige con `/model` y `/effort` como
//  predeterminado en `~/.claude/settings.json` (claves `model` y `effortLevel`), que es uno
//  solo para todos los proyectos del servidor. Por eso hay un registro global
//  `tasks/model-restore` (cerrojo `tasks/.model-restore/lock`):
//      model=<original>        # «default» si no había clave; solo lo anota el primero
//      effort=<original>       # «auto» si no había clave
//      last_model=<lo último que escribió Argos>
//      last_effort=<…>
//      holder=<carpeta del encargo>   # uno por encargo que lo cambió y no ha restaurado
//  Cada encargo apunta en `<encargo>/restore` qué cambió. Al acabar, su panel vuelve al
//  original (la sesión de cada ventana es suya); el registro se borra con el último.
//  Nunca se escribe en un panel que no esté libre (Claude trabajando, un diálogo de
//  permiso o de elección, o alguien tecleando): se reintenta y `tick` barre lo pendiente;
//  pasados 30 min se abandona y el encargo lo dice (`model_note=kept`). Si el usuario
//  cambió el ajuste a mano entre medias (ya no es lo que puso Argos), no se toca nada.
//  Si el valor guardado no se puede volver a poner (no es texto sencillo, anidado raro…),
//  ese encargo no cambia el modelo (`model_note=unsafe`).
//

import Foundation

enum ClaudeTaskModelScript {

    /// Registro global de lo que hay que restaurar (relativo a `~`).
    static let registryRelativePath = ".config/argos/tasks/model-restore"
    /// Tras este tiempo sin poder restaurar, se abandona.
    static let abandonSeconds = 30 * 60

    /// Lee una clave de PRIMER nivel de `settings.json`: imprime el texto, nada si no está
    /// (o es null) y «?» si no es un texto, está repetida o el JSON no se entiende.
    static let python = #"""
        model_py='
        import json, sys
        try:
            with open(sys.argv[1], encoding="utf-8") as f:
                top = json.load(f, object_pairs_hook=lambda pairs: pairs)
        except FileNotFoundError:
            sys.exit(0)
        except Exception:
            print("?")
            sys.exit(0)
        if not isinstance(top, list):
            print("?")
            sys.exit(0)
        found = [v for k, v in top if k == sys.argv[2]]
        if len(found) > 1:
            print("?")
        elif found and found[0] is not None:
            print(found[0] if isinstance(found[0], str) else "?")
        '
        """#

    /// Lo mismo sin python3: recorre el JSON contando la profundidad de llaves y corchetes.
    static let awk = #"""
        model_awk='
        BEGIN { RS = "\001" }
        {
          s = $0; n = length(s); d = 0; i = 1; hits = 0; out = ""
          # Tiene que ser un objeto, bien cerrado; si no, «?».
          if (s !~ /^[ \t\r\n]*\{/) { print "?"; exit }
          while (i <= n) {
            c = substr(s, i, 1)
            if (c == "\"") {
              j = i + 1; str = ""; esc = 0
              while (j <= n) {
                ch = substr(s, j, 1)
                if (ch == "\\") { esc = 1; str = str ch substr(s, j + 1, 1); j += 2; continue }
                if (ch == "\"") break
                str = str ch; j++
              }
              i = j + 1
              if (d == 1) {
                k = i; while (k <= n && substr(s, k, 1) ~ /[ \t\r\n]/) k++
                if (substr(s, k, 1) == ":" && str == key && !esc) {
                  hits++; k++; while (k <= n && substr(s, k, 1) ~ /[ \t\r\n]/) k++
                  v = substr(s, k, 1)
                  if (v == "\"") {
                    e = k + 1; val = ""
                    while (e <= n && substr(s, e, 1) != "\"") { if (substr(s, e, 1) == "\\") { val = "?"; break } val = val substr(s, e, 1); e++ }
                    out = val
                  } else if (substr(s, k, 4) == "null") {
                    out = ""
                  } else {
                    out = "?"
                  }
                }
              }
              continue
            }
            if (c == "{" || c == "[") d++
            else if (c == "}" || c == "]") d--
            i++
          }
          if (hits > 1 || d != 0) out = "?"
          if (out != "") print out
        }'
        """#

    static let functions = python + "\n" + awk + "\n" + #"""
        mreg="$base/model-restore"; mdir="$base/.model-restore"
        say() { tmux -u send-keys -t "$1" -l "$2" 2>/dev/null; tmux -u send-keys -t "$1" Enter 2>/dev/null; }

        # Clave $1 de primer nivel de los ajustes de Claude Code (ver `model_py`).
        setting() {
          sf="$HOME/.claude/settings.json"; [ -f "$sf" ] || return 0
          if [ "${ARGOS_MODEL_PARSER:-}" != awk ] && command -v python3 >/dev/null 2>&1; then
            sv=$(cd / && python3 -I -S -c "$model_py" "$sf" "$1" 2>/dev/null) || sv='?'
          else
            sv=$(LC_ALL=C awk -v key="$1" "$model_awk" "$sf" 2>/dev/null) || sv='?'
          fi
          case "$sv" in '') return 0 ;; *[!]A-Za-z0-9._:[-]*) sv='?' ;; esac
          [ ${#sv} -le 80 ] || sv='?'
          printf '%s\n' "$sv"
        }
        # Valor «restaurable» de la clave $1: el texto, default/auto si no hay, o «?».
        original() {
          ov=$(setting "$1")
          case "$1:$ov" in
            model:) echo default ;;
            effortLevel:) echo auto ;;
            *:'?') echo '?' ;;
            effortLevel:low|effortLevel:medium|effortLevel:high|effortLevel:xhigh|effortLevel:max) echo "$ov" ;;
            effortLevel:*) echo '?' ;;
            *) echo "$ov" ;;
          esac
        }
        # ¿La clave $1 tiene lo que puso Argos ($2)? Un alias puede guardarse como el nombre
        # completo del modelo (`claude-haiku-…`).
        same_setting() {
          cv=$(original "$1")
          [ "$cv" = "$2" ] && return 0
          case "$1:$2" in model:haiku|model:sonnet|model:opus) case "$cv" in *"$2"*) return 0 ;; esac ;; esac
          return 1
        }
        # Espera (máx. 10 s) a que Claude Code guarde el ajuste $1 = $2.
        wait_setting() {
          ws=0
          while [ $ws -lt 10 ]; do same_setting "$1" "$2" && return 0; sleep 1; ws=$((ws + 1)); done
          return 1
        }
        # Espera (máx. $2 s) a que el panel $1 quede libre otra vez.
        wait_idle() {
          wi=0
          while [ $wi -lt "$2" ]; do sleep 1; idle "$1" 1 && return 0; wi=$((wi + 1)); done
          return 1
        }
        mlock() {
          mkdir -p "$mdir" 2>/dev/null; ml=0
          until lock "$mdir"; do ml=$((ml + 1)); [ $ml -ge 10 ] && return 1; sleep 1; done
        }
        mput() {
          { grep -v "^$1=" "$mreg" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } > "$mreg.$$" && mv -f "$mreg.$$" "$mreg"
        }
        mget() { sed -n "s/^$1=//p" "$mreg" 2>/dev/null | head -n 1; }
        # El encargo $1 ya no tiene nada que restaurar ($2: nota para la app, si la hay).
        model_done() {
          rm -f "$1/restore"
          [ -n "$2" ] && printf 'model_note=%s\n' "$2" >> "$1/meta"
          [ -f "$mreg" ] || return 0
          grep -vxF "holder=$1" "$mreg" > "$mreg.$$"; mv -f "$mreg.$$" "$mreg"
          grep -q '^holder=' "$mreg" || rm -f "$mreg"
        }
        # Antes del encargo $1 en el panel $2: apunta el original (si nadie lo hizo) y escribe
        # /model y /effort. 1: no se pudo (el panel no está libre o el cerrojo está cogido).
        set_model() {
          md=$(meta "$1" model); ef=$(meta "$1" effort)
          case "$md" in haiku|sonnet|opus) ;; *) md= ;; esac
          case "$ef" in low|medium|high|xhigh|max) ;; *) ef= ;; esac
          [ -n "$md$ef" ] || return 0
          mlock || return 1
          idle "$2" 1 || { unlock "$mdir"; return 1; }
          note=
          for kv in "model:$md" "effortLevel:$ef"; do
            k=${kv%%:*}; v=${kv#*:}; [ -n "$v" ] || continue
            r=${k%Level}
            if [ -n "$(mget "$r")" ] && [ -n "$(mget "last_$r")" ] && ! same_setting "$k" "$(mget "last_$r")"; then
              # El usuario lo cambió a mano mientras tanto: ese es ahora el original.
              mput "$r" "$(original "$k")"
            fi
            [ -n "$(mget "$r")" ] || mput "$r" "$(original "$k")"
            if [ "$(mget "$r")" = '?' ]; then
              note=unsafe
              if [ "$r" = model ]; then md=; else ef=; fi
            fi
          done
          grep -q '^model=?$' "$mreg" 2>/dev/null && { grep -v '^model=' "$mreg" > "$mreg.$$"; mv -f "$mreg.$$" "$mreg"; }
          grep -q '^effort=?$' "$mreg" 2>/dev/null && { grep -v '^effort=' "$mreg" > "$mreg.$$"; mv -f "$mreg.$$" "$mreg"; }
          [ -n "$note" ] && printf 'model_note=%s\n' "$note" >> "$1/meta"
          if [ -z "$md$ef" ]; then
            grep -q '^holder=' "$mreg" 2>/dev/null || rm -f "$mreg"
            unlock "$mdir"; return 0
          fi
          printf 'model=%s\neffort=%s\n' "${md:+1}" "${ef:+1}" > "$1/restore"
          grep -qxF "holder=$1" "$mreg" 2>/dev/null || printf 'holder=%s\n' "$1" >> "$mreg"
          if [ -n "$md" ]; then
            mput last_model "$md"; say "$2" "/model $md"; wait_setting model "$md"; wait_idle "$2" 10
          fi
          if [ -n "$ef" ]; then
            mput last_effort "$ef"; say "$2" "/effort $ef"; wait_setting effortLevel "$ef"; wait_idle "$2" 10
          fi
          unlock "$mdir"
          return 0
        }
        # Vuelve a poner el modelo y el esfuerzo de antes del encargo $1 en su panel.
        # 0: hecho o abandonado; 1: todavía no (el panel no está libre): se reintenta.
        restore_model() {
          [ -f "$1/restore" ] || return 0
          mlock || return 1
          if ! grep -qxF "holder=$1" "$mreg" 2>/dev/null; then rm -f "$1/restore"; unlock "$mdir"; return 0; fi
          grep -q '^ended=' "$1/restore" || printf 'ended=%s\n' "$(date +%s)" >> "$1/restore"
          rp=$(cat "$1/pane" 2>/dev/null); rs=$(meta "$1" session); rw=$(meta "$1" window)
          # El panel debe seguir siendo el de session:window (tras reiniciar tmux, los %N se
          # reutilizan) y tener Claude abierto.
          if [ -z "$rp" ] || ! tmux -u list-panes -t "=$rs:$rw" -F '#{pane_id}' 2>/dev/null | grep -qxF "$rp" || shell_only "$rp"; then
            model_done "$1" kept; unlock "$mdir"; return 0
          fi
          # Otro encargo con modelo corre ya en ese panel: lo restaurará él al acabar.
          other=$(sed -n 's/^holder=//p' "$mreg" | while IFS= read -r h; do
            [ "$h" != "$1" ] && [ "$(state "$h")" = running ] && [ "$(cat "$h/pane" 2>/dev/null)" = "$rp" ] && echo 1
          done)
          if [ -n "$other" ]; then model_done "$1" ""; unlock "$mdir"; return 0; fi
          if ! idle "$rp"; then
            ed=$(sed -n 's/^ended=//p' "$1/restore" | head -n 1)
            case "$ed" in ''|*[!0-9]*) ed=$(date +%s) ;; esac
            if [ $(( $(date +%s) - ed )) -gt \#(abandonSeconds) ]; then model_done "$1" kept; fi
            unlock "$mdir"; return 1
          fi
          if [ "$(sed -n 's/^model=//p' "$1/restore")" = 1 ]; then
            om=$(mget model); lm=$(mget last_model)
            if [ -n "$om" ] && [ -n "$lm" ] && same_setting model "$lm"; then
              mput last_model "$om"; say "$rp" "/model $om"; wait_setting model "$om"; wait_idle "$rp" 10
            fi
          fi
          if [ "$(sed -n 's/^effort=//p' "$1/restore")" = 1 ]; then
            oe=$(mget effort); le=$(mget last_effort)
            case "$oe" in auto|low|medium|high|xhigh|max) ;; *) oe= ;; esac
            if [ -n "$oe" ] && [ -n "$le" ] && same_setting effortLevel "$le"; then
              mput last_effort "$oe"; say "$rp" "/effort $oe"; wait_setting effortLevel "$oe"; wait_idle "$rp" 10
            fi
          fi
          model_done "$1" ""
          unlock "$mdir"
          return 0
        }
        # Reintenta durante ~30 s (tras el hook `Stop`); lo que quede lo barre `tick`.
        restore_soon() {
          rn=0
          until restore_model "$1"; do rn=$((rn + 1)); [ $rn -ge 15 ] && return 0; sleep 2; done
        }
        # `tick`: restaura lo pendiente de encargos que ya no corren y olvida los de encargos
        # que ya no existen.
        model_sweep() {
          [ -f "$mreg" ] || return 0
          for t in "$base"/*/[0-9]*-*; do
            [ -f "$t/restore" ] || continue
            [ "$(state "$t")" = running ] && continue
            restore_model "$t"
          done
          [ -f "$mreg" ] || return 0
          mlock || return 0
          sed -n 's/^holder=//p' "$mreg" | while IFS= read -r h; do
            [ -d "$h" ] || { grep -vxF "holder=$h" "$mreg" > "$mreg.$$"; mv -f "$mreg.$$" "$mreg"; }
          done
          [ -f "$mreg" ] && ! grep -q '^holder=' "$mreg" && rm -f "$mreg"
          unlock "$mdir"
        }
        """#
}
