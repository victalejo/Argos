//
//  ClaudeTaskScript.swift
//  ArgosCore
//
//  Despachador de encargos en el servidor (ver `docs/encargos.md`). Es el que hace avanzar
//  la cola SIN la app: lo llaman los hooks de Claude al terminar un turno (`stop`) o al
//  fallar (`failure`), y la app al encolar (`tick`). Solo construye texto (lógica pura);
//  lo comparten Mac, iPhone/iPad y Android (goldens): cambiarlo solo de forma aditiva.
//
//  Datos: `~/.config/argos/tasks/<proyecto>/<seq>-<id>/{prompt,meta,state,reason,started,
//  finished,pane}`. Un cerrojo por proyecto (`lock/`). Todo POSIX sh, sin depender del
//  locale para tmux (`-u`) y saliendo siempre con 0 (un hook nunca debe molestar a Claude).
//

import Foundation

enum ClaudeTaskScript {

    static let marker = "argos-tasks"
    static let directoryRelativePath = ".config/argos/tasks"
    static let scriptRelativePath = ".config/argos/tasks/dispatch.sh"
    /// Carpeta donde la app deja un encargo nuevo antes de `enqueue`.
    static let incomingRelativePath = ".config/argos/tasks/incoming"

    /// Uso de Claude desde el que no se lanza un encargo (como el aviso de límites).
    static let limitPercent = ClaudeLimitsStatus.highFrom
    /// Fracción libre de memoria (RAM + swap, en milésimas) por debajo de la que se espera.
    static let memoryFreePermille = Int(ServerMemoryPressure.highBelow * 1000)

    static let script = #"""
        # \#(marker) v1: despachador de encargos de Argos (cola por proyecto).
        # Uso: dispatch.sh tick | stop <panel> | failure <panel> | enqueue <proyecto> <id>
        #      | cancel <proyecto> <encargo> | retry <proyecto> <encargo> | next <proyecto>
        #      | run <tarea programada> | push-anyway <proyecto> <encargo>
        base="${ARGOS_TASKS_DIR:-$HOME/.config/argos/tasks}"
        limits="${ARGOS_LIMITS_FILE:-$HOME/.config/argos/claude-limits.json}"
        self="$base/dispatch.sh"
        umask 077
        [ -d "$base" ] || exit 0

        lock() {
          mkdir "$1/lock" 2>/dev/null && return 0
          # Cerrojo de más de 5 min: de un despachador que murió.
          [ -n "$(find "$1/lock" -prune -mmin +5 2>/dev/null)" ] || return 1
          mv "$1/lock" "$1/lock.old.$$" 2>/dev/null || return 1
          rm -rf "$1/lock.old.$$"; mkdir "$1/lock" 2>/dev/null
        }
        unlock() { rm -rf "$1/lock"; }
        meta() { sed -n "s/^$2=//p" "$1/meta" 2>/dev/null | head -n 1; }
        state() { cat "$1/state" 2>/dev/null; }
        put() { printf '%s\n' "$3" > "$1/$2.$$" && mv -f "$1/$2.$$" "$1/$2"; }

        # Primer encargo del proyecto en el estado $2 (por orden de la cola).
        first_in() {
          for t in "$1"/[0-9]*-*; do
            [ -d "$t" ] || continue
            [ "$(state "$t")" = "$2" ] && { printf '%s\n' "$t"; return 0; }
          done
          return 1
        }

        # ¿Puede recibir un encargo el panel? Claude libre: sin estado «trabajando/esperando»
        # (salvo con $2=1: Claude acaba de terminar), sin rastro de trabajo en pantalla (como
        # el sondeo de la app), sin un diálogo de permiso o de elección abierto (un Enter lo
        # respondería) y sin nadie tecleando en esa sesión en los últimos 10 s.
        idle() {
          if [ "$2" != 1 ]; then
            o=$(tmux -u show-options -pqv -t "$1" @argos_claude 2>/dev/null)
            case "$o" in working|waiting) return 1 ;; esac
          fi
          s=$(tmux -u capture-pane -p -t "$1" 2>/dev/null) || return 1
          printf '%s\n' "$s" | tail -n 4 | grep -q 'esc to interrupt' && return 1
          printf '%s\n' "$s" | grep -q '^[^ ]* Waiting for [0-9]* background' && return 1
          printf '%s\n' "$s" | tail -n 14 | grep -qE 'Do you want to|Enter to (select|confirm)|Esc to cancel|❯ [0-9]+\.' && return 1
          sn=$(tmux -u display-message -p -t "$1" '#{session_name}' 2>/dev/null)
          ca=$(tmux -u list-clients -t "=$sn" -F '#{client_activity}' 2>/dev/null | sort -n | tail -n 1)
          case "$ca" in ''|*[!0-9]*) ;; *) [ $(( $(date +%s) - ca )) -lt 10 ] && return 1 ;; esac
          return 0
        }

        # Claude no está abierto en el panel: hay un shell en primer plano.
        shell_only() {
          c=$(tmux -u display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null)
          case "$c" in sh|bash|zsh|fish|dash|ksh|tcsh|csh|-sh|-bash|-zsh) return 0 ;; esac
          return 1
        }

        # Frenos de uso y de memoria. Imprime el motivo si no se debe lanzar.
        blocked() {
          if [ -f "$limits" ] && grep -qs 'argos-claude-limits' "$HOME/.claude/settings.json"; then
            u=$(LC_ALL=C awk -v now="$(date +%s)" -v top=\#(limitPercent) '
              { while (match($0, /"used_percentage":[0-9.]+,"resets_at":[0-9]+/)) {
                  r = substr($0, RSTART, RLENGTH); $0 = substr($0, RSTART + RLENGTH)
                  split(r, a, /[:,]/); if (a[4] + 0 > now && a[2] + 0 >= top) hit = 1 } }
              END { if (hit) print "limit" }' "$limits" 2>/dev/null)
            [ -n "$u" ] && { echo "limit"; return 0; }
          fi
          if [ -r /proc/meminfo ]; then
            m=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2}
              END { if (t + st > 0 && (a + sf) * 1000 < \#(memoryFreePermille) * (t + st)) print "memory" }' /proc/meminfo 2>/dev/null)
            [ -n "$m" ] && { echo "memory"; return 0; }
          fi
          return 1
        }

        \#(ClaudeBudgetScript.functions)

        \#(ClaudeTaskModelScript.functions)

        # Lanza el encargo $2 del proyecto $1 en su panel. $3=1: Claude acaba de terminar
        # (hook Stop), no hace falta mirar si está libre.
        launch() {
          t=$2
          if [ "$(meta "$t" target)" = agent ]; then launch_agent "$t"; return $?; fi
          session=$(meta "$t" session); window=$(meta "$t" window)
          pane=$(tmux -u list-panes -t "=$session:$window" -F '#{pane_id}' 2>/dev/null | head -n 1)
          if [ -z "$pane" ]; then put "$t" reason "no-pane"; return 1; fi
          if shell_only "$pane"; then put "$t" reason "no-claude"; return 1; fi
          if [ "$3" != 1 ] && ! idle "$pane"; then put "$t" reason "busy"; return 1; fi
          why=$(blocked) && { put "$t" reason "$why"; return 1; }
          buf="argos-task-$$"
          if [ "$(meta "$t" context)" = clear ]; then
            tmux -u send-keys -t "$pane" /clear Enter 2>/dev/null; sleep 2
          fi
          put "$t" pane "$pane"
          # Un encargo anterior de este panel que aún no volvió a su modelo: primero eso.
          for o in "$1"/[0-9]*-*; do
            [ "$o" != "$t" ] && [ -f "$o/restore" ] && [ "$(state "$o")" != running ] && [ "$(cat "$o/pane" 2>/dev/null)" = "$pane" ] && restore_model "$o"
          done
          set_model "$t" "$pane" || { put "$t" reason "busy"; return 1; }
          if [ "$(meta "$t" resume)" = 1 ]; then
            printf '%s' "Continúa con el encargo anterior donde lo dejaste." > "$t/prompt.resume"
            src="$t/prompt.resume"
          else
            src="$t/prompt"
          fi
          tmux -u load-buffer -b "$buf" "$src" 2>/dev/null || { put "$t" reason "tmux"; restore_model "$t"; return 1; }
          tmux -u paste-buffer -p -d -b "$buf" -t "$pane" 2>/dev/null || { put "$t" reason "tmux"; restore_model "$t"; return 1; }
          sleep 1
          tmux -u send-keys -t "$pane" Enter 2>/dev/null
          tmux -u set-option -p -t "$pane" @argos_claude working 2>/dev/null
          put "$t" started "$(date +%s)"; rm -f "$t/reason"
          put "$t" state running
          return 0
        }

        # Encargo en un agente persistente (en su worktree): la app dejó preparados
        # `launch.sh` (crea el worktree y arranca claude headless; el token, vacío, va por
        # stdin) y `send.sh` (entrega el encargo por la FIFO del agente).
        launch_agent() {
          t=$1
          why=$(blocked) && { put "$t" reason "$why"; return 1; }
          [ -f "$t/launch.sh" ] && [ -f "$t/send.sh" ] || { put "$t" reason "agent"; return 1; }
          if ! printf '\n' | sh "$t/launch.sh" > "$t/launch.out" 2>&1; then put "$t" reason "agent"; return 1; fi
          sleep 2
          if ! sh "$t/send.sh" >> "$t/launch.out" 2>&1; then put "$t" reason "agent"; return 1; fi
          put "$t" started "$(date +%s)"; rm -f "$t/reason"
          put "$t" state running
          return 0
        }

        # Avanza un proyecto: si nada corre, lanza el primer pendiente.
        advance() {
          p=$1
          lock "$p" || return 0
          if ! first_in "$p" running >/dev/null; then
            # Pausado por el límite de uso: se reanuda solo cuando ya no hay freno.
            if t=$(first_in "$p" paused) && [ "$(cat "$t/reason" 2>/dev/null)" = limit ] && ! blocked >/dev/null; then
              put "$t" state pending
            fi
            if t=$(first_in "$p" pending); then
              if review_barrier "$p" "$t"; then put "$t" reason review-wait; elif budget_ok "$p" "$t"; then launch "$p" "$t" "$2"; fi
            else
              budget_clear "$p"
            fi
          fi
          unlock "$p"
        }

        # El encargo que corre en el panel $1 o, sin panel (agente headless), en la sesión de
        # Claude $2 (o nada).
        running_on() {
          for t in "$base"/*/[0-9]*-*; do
            [ -d "$t" ] || continue
            [ "$(state "$t")" = running ] || continue
            if [ -n "$1" ]; then
              [ "$(cat "$t/pane" 2>/dev/null)" = "$1" ] && { printf '%s\n' "$t"; return 0; }
            elif [ -n "$2" ]; then
              [ "$(meta "$t" agent)" = "$2" ] && { printf '%s\n' "$t"; return 0; }
            fi
          done
          return 1
        }

        # Commit (y push) al terminar un encargo, si lo pide. En segundo plano: un hook
        # tiene pocos segundos.
        commit_task() {
          dir=$(meta "$1" dir); [ -d "$dir" ] || return 0
          git -C "$dir" add -A 2>/dev/null
          pre=$(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null)
          if git -C "$dir" diff --cached --quiet 2>/dev/null; then
            # Sin cambios: nada que hacer, salvo un arreglo de lo que bloqueó el revisor (su
            # rama ya tiene el commit pendiente de subir).
            [ -n "$(meta "$1" fixes)" ] || return 0
          else
            git -C "$dir" commit -q -m "$(meta "$1" title)" -m "Encargo de Argos." >/dev/null 2>&1 || { put "$1" reason "commit"; return 0; }
          fi
          wants_push "$1" || return 0
          # Push a main solo si pasa la comprobación (si la hay) y el revisor lo aprueba, y
          # solo del commit revisado. Desde un worktree se sube su rama como main del remoto
          # (fast-forward): nunca toca el checkout del usuario.
          check=$(meta "$1" check)
          if [ -n "$check" ] && ! (cd "$dir" && sh -c "$check") >"$1/check.log" 2>&1; then put "$1" reason "check"; return 0; fi
          review_task "$1" "$dir" "$pre" || return 0
          push_task "$1"
          return 0
        }

        \#(ClaudeTaskReviewScript.functions)

        # Un encargo en agente que pasa de su tiempo máximo se detiene y se marca fallido.
        expire() {
          for t in "$base"/*/[0-9]*-*; do
            [ -d "$t" ] && [ "$(state "$t")" = running ] && [ "$(meta "$t" target)" = agent ] || continue
            mx=$(meta "$t" max_minutes); st=$(cat "$t/started" 2>/dev/null)
            case "$mx$st" in ''|*[!0-9]*) continue ;; esac
            [ $(( $(date +%s) - st )) -gt $(( mx * 60 )) ] || continue
            [ -f "$t/stop.sh" ] && sh "$t/stop.sh" >/dev/null 2>&1
            put "$t" reason timeout; put "$t" finished "$(date +%s)"; put "$t" state failed
          done
        }

        rand_hex() { od -An -N6 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'; }
        new_uuid() {
          u=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null)
          printf '%s' "$u" | tr 'A-Z' 'a-z'
        }
        conf() { sed -n "s/^$2=//p" "$1/config" 2>/dev/null | head -n 1; }

        # ¿Toca la tarea programada $1? Hoy es uno de sus días, ya pasó su hora (hace menos
        # de 12 h: si el servidor estuvo apagado, se recupera) y no corrió desde entonces.
        due() {
          [ "$(conf "$1" enabled)" = 1 ] || return 1
          case ",$(conf "$1" days)," in *",$(date +%u),"*) ;; *) return 1 ;; esac
          hm=$(conf "$1" time); h=${hm%%:*}; m=${hm##*:}
          case "$h$m" in ''|*[!0-9]*) return 1 ;; esac
          now_m=$(( $(date +%H | sed 's/^0//') * 60 + $(date +%M | sed 's/^0//') ))
          at_m=$(( $(printf '%s' "$h" | sed 's/^0//') * 60 + $(printf '%s' "$m" | sed 's/^0//') ))
          late=$(( now_m - at_m ))
          [ "$late" -ge 0 ] && [ "$late" -le 720 ] || return 1
          last=$(cat "$1/last" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
          [ "$last" -lt $(( $(date +%s) - late * 60 - 60 )) ]
        }

        # Claude trabajando o esperando en alguna ventana de la sesión del proyecto.
        in_use() {
          tmux -u list-panes -s -t "=$1" -F '#{@argos_claude}' 2>/dev/null | grep -qE '^(working|waiting)$'
        }

        # Crea el encargo de una ejecución de la tarea programada $1 a partir de sus plantillas.
        spawn() {
          s=$1; proj=$(conf "$s" project)
          case "$proj" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
          in_use "$(conf "$s" session)" && return 1
          run=$(rand_hex); aid=$(new_uuid); now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          case "$run" in ''|*[!0-9a-f]*) return 1 ;; esac
          case "$aid" in ''|*[!0-9a-f-]*) return 1 ;; esac
          i="$base/incoming"; mkdir -p "$i" || return 1
          sub="s/@@RUN@@/$run/g; s/@@NOW@@/$now/g; s/\#(ClaudeScheduleScripts.sentinelAgentID)/$aid/g"
          b64=$(sed "$sub" "$s/meta.tpl" | base64 | tr -d '\n')
          { printf "ARGOS_META_B64='%s'\n" "$b64"; sed "$sub" "$s/launch.tpl"; } > "$i/$run.launch.sh" || return 1
          sed "$sub" "$s/send.tpl" > "$i/$run.send.sh" && sed "$sub" "$s/stop.tpl" > "$i/$run.stop.sh" \
            && sed "$sub" "$s/task.tpl" > "$i/$run.meta" && cp "$s/prompt" "$i/$run.prompt" || return 1
          date +%s > "$s/last"
          sh "$self" enqueue "$proj" "$run"
        }

        case "$1" in
          tick)
            \#(ServerMetricsScript.dispatcherStartLine)
            expire
            review_expire
            model_sweep
            for s in "$base"/schedules/*/; do
              s=${s%/}; [ -f "$s/config" ] || continue
              due "$s" && spawn "$s"
            done
            for p in "$base"/*/; do
              p=${p%/}; case "${p##*/}" in incoming|schedules) continue ;; esac
              [ -d "$p" ] && advance "$p" 0
            done
            \#(ServerMetricsScript.dispatcherWaitLine)
            ;;
          next)
            [ -d "$base/$2" ] && advance "$base/$2" 1
            ;;
          stop|failure)
            # El hook pasa su JSON por stdin: de ahí la sesión de Claude (agentes sin panel).
            i=$(head -c 8192)
            sid=$(printf '%s' "$i" | sed -n 's/.*"session_id":"\([A-Za-z0-9-]*\)".*/\1/p' | head -n 1)
            [ -n "$2" ] || [ -n "$sid" ] || exit 0
            t=$(running_on "$2" "$sid") || exit 0
            p=${t%/*}
            # `Stop` llega al acabar el turno principal aunque queden subagentes en segundo
            # plano: el encargo no ha terminado (habrá otro `Stop` cuando acaben).
            if [ "$1" = stop ] && [ -n "$2" ] && tmux -u capture-pane -p -t "$2" 2>/dev/null | grep -q '^[^ ]* Waiting for [0-9]* background'; then
              exit 0
            fi
            if [ "$1" = stop ]; then
              put "$t" finished "$(date +%s)"; put "$t" state done
              if [ "$(meta "$t" commit)" = 1 ]; then
                # Fuera del hook (puede tardar lo que la revisión): si muere, `tick` la da
                # por vencida.
                detach sh "$self" finish "${p##*/}" "${t##*/}"
              else
                (sleep 2; restore_soon "$t"; sh "$self" next "${p##*/}") >/dev/null 2>&1 &
              fi
            else
              case "$i" in
                *rate_limit*|*usage*limit*|*'429'*) put "$t" reason limit ;;
                *) put "$t" reason api ;;
              esac
              printf 'resume=1\n' >> "$t/meta"
              put "$t" state paused
              [ -f "$t/restore" ] && { (sleep 2; restore_soon "$t") >/dev/null 2>&1 & }
            fi
            ;;
          enqueue)
            # La app dejó incoming/<id>.prompt y .meta: se les da el siguiente número.
            proj=$2; id=$3
            case "$id$proj" in *[!A-Za-z0-9_-]*|'') exit 0 ;; esac
            p="$base/$proj"; mkdir -p "$p" || exit 0
            lock "$p" || exit 0
            # Sin ceros a la izquierda: `$((000012 + 1))` sería octal.
            n=$(ls -d "$p"/[0-9]*-* 2>/dev/null | sed 's|.*/||; s|-.*||; s/^0*//' | sort -n | tail -n 1)
            n=$(printf '%06d' $(( ${n:-0} + 1 )) 2>/dev/null) || { unlock "$p"; exit 0; }
            t="$p/$n-$id"
            mkdir "$t" && mv -f "$base/incoming/$id.prompt" "$t/prompt" && mv -f "$base/incoming/$id.meta" "$t/meta" \
              && for f in launch.sh send.sh stop.sh; do
                   [ -f "$base/incoming/$id.$f" ] && mv -f "$base/incoming/$id.$f" "$t/$f"
                 done
            [ -f "$t/meta" ] && put "$t" state pending
            # Arreglo de lo que bloqueó el revisor: el revisor verá también el encargo
            # original, y el bloqueado sale de la bandeja (su commit sigue en la rama).
            f=$(meta "$t" fixes)
            case "$f" in ''|*[!A-Za-z0-9_-]*) f= ;; esac
            if [ -n "$f" ] && [ -d "$p/$f" ]; then
              if [ -f "$p/$f/prompt.original" ]; then cp "$p/$f/prompt.original" "$t/prompt.original"
              else cp "$p/$f/prompt" "$t/prompt.original" 2>/dev/null; fi
              review_blocked "$p/$f" && { put "$p/$f" reason review-fixing; put "$p/$f" state done; }
            fi
            unlock "$p"
            advance "$p" 0
            ;;
          run)
            # «Ejecutar ahora» una tarea programada (sin esperar a su hora).
            case "$2" in ''|*[!0-9a-f]*) exit 0 ;; esac
            [ -f "$base/schedules/$2/config" ] && spawn "$base/schedules/$2"
            ;;
          push-anyway)
            # «Subir igualmente» lo que bloqueó el revisor: el push que faltaba, en segundo plano.
            case "$2$3" in *[!A-Za-z0-9_-]*|'') exit 0 ;; esac
            t="$base/$2/$3"; [ -d "$t" ] || exit 0
            lock "$base/$2" || exit 0
            ok=0
            # Solo el commit revisado, y nunca si contiene otro que el revisor bloqueó.
            if review_blocked "$t" && sha=$(review_sha "$t") && ! review_held "$t" "$(meta "$t" dir)" "$sha"; then
              ok=1; date +%s > "$t/pushed_anyway"; put "$t" reason pushing; put "$t" state done
            fi
            unlock "$base/$2"
            [ "$ok" = 1 ] && detach sh "$self" push-reviewed "$2" "$3"
            ;;
          push-reviewed)
            # Interno (push-anyway): el push en segundo plano.
            case "$2$3" in *[!A-Za-z0-9_-]*|'') exit 0 ;; esac
            t="$base/$2/$3"
            [ -d "$t" ] && [ "$(cat "$t/reason" 2>/dev/null)" = pushing ] && push_task "$t"
            ;;
          finish)
            # Interno (hook Stop): commit, comprobación, revisión y push; luego el siguiente.
            case "$2$3" in *[!A-Za-z0-9_-]*|'') exit 0 ;; esac
            t="$base/$2/$3"; [ -d "$t" ] || exit 0
            [ -f "$t/restore" ] && { sleep 2; restore_soon "$t"; }
            commit_task "$t"
            advance "$base/$2" 1
            ;;
          cancel|retry)
            case "$2$3" in *[!A-Za-z0-9_-]*|'') exit 0 ;; esac
            t="$base/$2/$3"; [ -d "$t" ] || exit 0
            lock "$base/$2" || exit 0
            s=$(state "$t")
            if [ "$1" = cancel ]; then
              case "$s" in pending|paused) put "$t" state cancelled ;; esac
            elif ! review_blocked "$t"; then
              # Lo bloqueado por el revisor no se repite: se sube igualmente o se arregla.
              case "$s" in paused|failed) put "$t" state pending ;; esac
            fi
            unlock "$base/$2"
            [ "$1" = retry ] && advance "$base/$2" 0
            ;;
        esac
        exit 0

        """#

    /// Lista los encargos (para la app): por encargo, un marcador y sus archivos pequeños.
    /// El prompt va recortado a 400 bytes y en una línea.
    static let listCommand = #"""
        b="$HOME/\#(directoryRelativePath)"; [ -d "$b" ] || exit 0
        for t in "$b"/*/[0-9]*-*; do
          [ -d "$t" ] || continue
          r=${t#"$b"/}
          printf '@@task %s\n' "$r"
          printf 'state %s\n' "$(head -c 32 "$t/state" 2>/dev/null)"
          printf 'reason %s\n' "$(head -c 64 "$t/reason" 2>/dev/null)"
          if [ -f "$t/review.json" ]; then
            case "$(head -c 64 "$t/reason" 2>/dev/null)" in
              review|review-inconclusive) printf 'review %s\n' "$(head -c \#(ClaudeTaskReviewScript.maxListedReportBytes) "$t/review.json" | tr '\n\r\t' '   ')" ;;
              *) printf 'reviewed %s\n' "$(sed -n 's/.*"verdict"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' "$t/review.json" | head -n 1 | head -c 16)" ;;
            esac
          fi
          printf 'started %s\n' "$(head -c 16 "$t/started" 2>/dev/null)"
          printf 'finished %s\n' "$(head -c 16 "$t/finished" 2>/dev/null)"
          head -c 2048 "$t/meta" 2>/dev/null | sed 's/^/meta /'
          printf 'prompt %s\n' "$(head -c 400 "$t/prompt" 2>/dev/null | tr '\n\r\t' '   ')"
        done
        exit 0
        """#

    static func dispatchCommand(_ arguments: [String]) -> String {
        (["sh", "\"$HOME/\(scriptRelativePath)\""] + arguments.map(ShellQuoting.singleQuoted)).joined(separator: " ")
            + " >/dev/null 2>&1; exit 0"
    }
}
