//
//  ClaudeOrphanScript.swift
//  ArgosCore
//
//  Comandos de los procesos de Claude huérfanos: listarlos (lo decide `ClaudeProcessSurvey`)
//  y matarlos. Matar envía TERM y, si a los 5 s sigue vivo, KILL; ANTES de cada señal
//  comprueba en el servidor que el PID es el mismo proceso (hora de arranque) y que sigue
//  siendo huérfano: no cuelga de tmux, de una sesión SSH/mosh viva ni de un agente
//  persistente. Solo construye texto (lógica pura; goldens). POSIX sh, sin locale.
//

import Foundation

enum ClaudeOrphanScript {

    /// Huérfanos por llamada (cada uno puede esperar sus 5 s; todos esperan a la vez).
    static let maxTargets = 20
    static let graceSeconds = 5

    /// Agentes persistentes registrados: `ids` (sus session id) y `agents` (sus PID vivos y
    /// comprobados por su línea de comandos, como `PersistentAgentScript.aliveCheck`).
    private static let registeredAgents = #"""
        ids=""; agents=""
        for a in "$HOME/\#(PersistentAgentScript.rootRelativePath)"/*/; do
          [ -d "$a" ] || continue
          id=$(basename "$a"); case "$id" in ''|*[!0-9A-Fa-f-]*) continue ;; esac
          ids="$ids $id"
          q=$(cat "$a/pid" 2>/dev/null); case "$q" in ''|*[!0-9]*) continue ;; esac
          ps -o args= -p "$q" 2>/dev/null | grep -qF -- "$id" && agents="$agents $q"
        done
        """#

    /// Lista para `ClaudeProcessSurvey.parse`: `@@me`, `pane`, `agent`, la tabla de procesos
    /// (`p …`, solo el nombre corto) y la huella (`start`) de cada `claude` del usuario.
    static let listCommand = #"""
        export LC_ALL=C
        me=$(id -u); echo "@@me $me"
        command -v tmux >/dev/null 2>&1 && tmux -u list-panes -a -F 'pane #{pane_pid}' 2>/dev/null | head -n 5000
        \#(registeredAgents)
        for q in $agents; do echo "agent $q"; done
        ps -eo pid=,ppid=,uid=,rss=,etime=,tty=,comm= 2>/dev/null | head -n 20000 | sed 's/^ */p /'
        for c in $(ps -eo pid=,uid=,comm= 2>/dev/null | awk -v me="$me" '$2 == me { n = $3; for (i = 4; i <= NF; i++) n = n " " $i; sub(/.*\//, "", n); if (n == "claude") print $1 }' | head -n 500); do
          a=$(ps -o args= -p "$c" 2>/dev/null)
          for id in $ids; do case "$a" in *"$id"*) echo "agent $c" ;; esac; done
          printf 'start %s %s\n' "$c" "$(ps -o lstart= -p "$c" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//')"
        done
        exit 0
        """#

    /// Funciones compartidas por el script de matar.
    private static let killHelpers = #"""
        export LC_ALL=C
        me=$(id -u)
        \#(registeredAgents)
        panes=$(command -v tmux >/dev/null 2>&1 && tmux -u list-panes -a -F '#{pane_pid}' 2>/dev/null | tr '\n' ' ')
        fp() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//' | tr ' ' '_'; }
        nm() { ps -o comm= -p "$1" 2>/dev/null | sed 's/.*\///'; }
        # ¿Sigue siendo huérfano? Del usuario, no es un agente y ni él ni un ancestro es un
        # panel, un agente, tmux, sshd o mosh. Si la cadena se corta, NO es seguro.
        safe() {
          [ "$(ps -o uid= -p "$1" 2>/dev/null | tr -d ' ')" = "$me" ] || return 1
          a=$(ps -o args= -p "$1" 2>/dev/null)
          for id in $ids; do case "$a" in *"$id"*) return 1 ;; esac; done
          x=$1; i=0
          while [ "$x" -gt 1 ]; do
            [ $i -lt 64 ] || return 1
            case " $panes $agents " in *" $x "*) return 1 ;; esac
            if [ "$x" != "$1" ]; then case "$(nm "$x")" in tmux*|sshd*|mosh-server*) return 1 ;; esac; fi
            x=$(ps -o ppid= -p "$x" 2>/dev/null | tr -d ' ')
            case "$x" in ''|*[!0-9]*) return 1 ;; esac
            i=$((i + 1))
          done
          return 0
        }
        # Descendientes de $1 (hijos MCP, node…).
        kids() {
          ps -eo pid=,ppid= 2>/dev/null | awk -v r="$1" '{ pp[$1] = $2; ids[++c] = $1 }
            END { for (k = 1; k <= c; k++) { x = pp[ids[k]]
              for (j = 0; j < 64 && x != ""; j++) { if (x == r) { print ids[k]; break }; x = pp[x] } } }'
        }
        # Señal $1 a cada miembro de la familia que siga siendo el mismo proceso y huérfano.
        signal() {
          for e in $fam; do
            k=${e#*,}; f=${k#*=}; k=${k%%=*}
            [ -n "$f" ] && [ "$(fp "$k")" = "$f" ] && safe "$k" && kill -s "$1" "$k" 2>/dev/null
          done
          return 0
        }
        alive() { kill -0 "$1" 2>/dev/null && [ "$(fp "$1")" = "$2" ] && ! ps -o stat= -p "$1" 2>/dev/null | grep -q '^ *Z'; }
        """#

    /// Mata los huérfanos `targets` (PID y huella de `ClaudeOrphan`). Imprime por cada uno
    /// `killed|skipped|stuck <pid>`. Los PID o huellas no válidos se descartan.
    static func killCommand(_ targets: [(pid: Int, fingerprint: String)]) -> String {
        let valid = targets.prefix(maxTargets).compactMap { target -> String? in
            guard target.pid > 1, let print = validFingerprint(target.fingerprint) else { return nil }
            return "\(target.pid) \(ShellQuoting.singleQuoted(print.replacingOccurrences(of: " ", with: "_")))"
        }
        let collect = valid.map { "take \($0)" }.joined(separator: "\n")
        return killHelpers + "\n" + #"""
            fam=""; roots=""
            take() {
              if [ "$(fp "$1")" = "$2" ] && [ "$(nm "$1")" = claude ] && safe "$1"; then
                roots="$roots $1=$2"
                for k in $1 $(kids "$1"); do fam="$fam $1,$k=$(fp "$k")"; done
              else
                echo "skipped $1"
              fi
            }

            """# + collect + "\n" + #"""
            [ -n "$roots" ] || exit 0
            signal TERM
            i=0
            while [ $i -lt \#(graceSeconds) ]; do
              w=0; for r in $roots; do alive "${r%%=*}" "${r#*=}" && w=1; done
              [ $w = 1 ] || break
              sleep 1; i=$((i + 1))
            done
            signal KILL
            sleep 1
            for r in $roots; do
              if alive "${r%%=*}" "${r#*=}"; then echo "stuck ${r%%=*}"; else echo "killed ${r%%=*}"; fi
            done
            exit 0
            """#
    }

    /// Huella aceptable (`ps -o lstart=` con `LC_ALL=C`): letras, cifras, espacios y `:`.
    static func validFingerprint(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 :_")
        guard !trimmed.isEmpty, trimmed.count <= 64, trimmed.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed.replacingOccurrences(of: "_", with: " ")
    }

    static func parseKill(_ output: String) -> [Int: ClaudeOrphanKillOutcome] {
        var result: [Int: ClaudeOrphanKillOutcome] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            guard fields.count == 2, let outcome = ClaudeOrphanKillOutcome(rawValue: String(fields[0])),
                  let pid = Int(fields[1])
            else { continue }
            result[pid] = outcome
        }
        return result
    }
}
