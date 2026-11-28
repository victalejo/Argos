//
//  ClaudeOrphanScript.swift
//  ArgosCore
//
//  Comandos de los procesos de Claude huérfanos: listarlos (lo decide `ClaudeProcessSurvey`)
//  y matarlos. Matar envía TERM y, si a los 5 s sigue vivo, KILL; ANTES de cada señal
//  comprueba en el servidor que el PID es el mismo proceso (hora de arranque), que sigue en
//  la familia de la raíz elegida y que sigue siendo huérfano: no cuelga de un multiplexor
//  (tmux, screen, zellij, dtach, abduco), de una sesión viva (sshd, dropbear, mosh, script),
//  de cron ni de un servicio de systemd, ni lo lanzó Argos (despachador, revisor, agentes) o
//  VS Code Remote. Solo construye texto (lógica pura; goldens). POSIX sh, sin locale.
//

import Foundation

enum ClaudeOrphanScript {

    /// Huérfanos por llamada (cada uno puede esperar sus 5 s; todos esperan a la vez).
    static let maxTargets = 20
    static let graceSeconds = 5

    /// Marcas en la línea de comandos de un proceso (o de un ancestro) que lo protegen: la
    /// carpeta de Argos (despachador, revisor de encargos, lanzadores) y los servidores de
    /// VS Code Remote y parecidos.
    static let managedMarkers = ["/.config/argos/", "/.vscode-server", "/.cursor-server", "/.windsurf-server"]

    /// Nombres de ancestro protegidos en el script de matar (debe coincidir con
    /// `ClaudeProcessSurvey.isProtectedAncestorName`).
    private static let protectedNamePattern = "tmux*|sshd*|screen|SCREEN|zellij|dtach|abduco|script|dropbear|mosh-server|cron|crond"

    /// Agentes persistentes registrados (`ids`, sus session id; `agents`, sus PID vivos y
    /// comprobados por su línea de comandos) y procesos con marca de Argos o de un IDE
    /// remoto (`managed`).
    private static let registeredAgents = #"""
        ids=""; agents=""
        for a in "$HOME/\#(PersistentAgentScript.rootRelativePath)"/*/; do
          [ -d "$a" ] || continue
          id=$(basename "$a"); case "$id" in ''|*[!0-9A-Fa-f-]*) continue ;; esac
          ids="$ids $id"
          q=$(cat "$a/pid" 2>/dev/null); case "$q" in ''|*[!0-9]*) continue ;; esac
          ps -o args= -p "$q" 2>/dev/null | grep -qF -- "$id" && agents="$agents $q"
        done
        managed=$(ps -eo pid=,args= 2>/dev/null | awk '\#(managedAwkCondition) { print $1 }' | head -n 5000 | tr '\n' ' ')
        """#

    private static var managedAwkCondition: String {
        managedMarkers.map { "index($0, \"\($0)\")" }.joined(separator: " || ")
    }

    /// Lista para `ClaudeProcessSurvey.parse`: `@@me`, `pane`, `agent`, `managed`, la tabla de
    /// procesos (`p …`, solo el nombre corto) y, por cada `claude` del usuario, su huella
    /// (`start`), si corre en un servicio de systemd (`svc`), su carpeta (`cwd`) y su orden
    /// con solo las opciones (`args`: sin valores, que pueden llevar secretos).
    static let listCommand = #"""
        export LC_ALL=C
        me=$(id -u); echo "@@me $me"
        command -v tmux >/dev/null 2>&1 && tmux -u list-panes -a -F 'pane #{pane_pid}' 2>/dev/null | head -n 5000
        \#(registeredAgents)
        for q in $agents; do echo "agent $q"; done
        for q in $managed; do echo "managed $q"; done
        ps -eo pid=,ppid=,uid=,rss=,etime=,tty=,comm= 2>/dev/null | head -n 20000 | sed 's/^ */p /'
        for c in $(ps -eo pid=,uid=,comm= 2>/dev/null | awk -v me="$me" '$2 == me { n = $3; for (i = 4; i <= NF; i++) n = n " " $i; sub(/.*\//, "", n); if (n == "claude") print $1 }' | head -n 500); do
          a=$(ps -o args= -p "$c" 2>/dev/null)
          for id in $ids; do case "$a" in *"$id"*) echo "agent $c" ;; esac; done
          grep -qs '\.service$' "/proc/$c/cgroup" && echo "svc $c"
          printf 'start %s %s\n' "$c" "$(ps -o lstart= -p "$c" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//')"
          w=$(readlink "/proc/$c/cwd" 2>/dev/null | tr -cd 'A-Za-z0-9._/ +@:,=~-' | cut -c1-200)
          [ -n "$w" ] && printf 'cwd %s %s\n' "$c" "$w"
          printf '%s\n' "$a" | awk -v c="$c" '{ o = $1; sub(/.*\//, "", o); d = 0
            for (i = 2; i <= NF && i <= 60; i++) { t = $i
              if (t ~ /^-/) { sub(/=.*/, "", t); gsub(/[^A-Za-z0-9_-]/, "", t); o = o " " t; d = 0 }
              else if (!d) { o = o " ..."; d = 1 } }
            gsub(/[^A-Za-z0-9_. -]/, "", o); print "args", c, substr(o, 1, 200); exit }'
        done
        exit 0
        """#

    /// Funciones compartidas por el script de matar.
    /// (Visible para los tests de `related`/`family`/`safe`.)
    static let killHelpers = #"""
        export LC_ALL=C
        me=$(id -u)
        \#(registeredAgents)
        panes=$(command -v tmux >/dev/null 2>&1 && tmux -u list-panes -a -F '#{pane_pid}' 2>/dev/null | tr '\n' ' ')
        fp() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//' | tr ' ' '_'; }
        nm() { ps -o comm= -p "$1" 2>/dev/null | sed 's/.*\///'; }
        # ¿Sigue siendo huérfano? Del usuario, no es un agente ni corre en un servicio de
        # systemd, y ni él ni un ancestro es un panel, un agente, un proceso con marca de
        # Argos o de un IDE remoto, ni un multiplexor, sesión o cron. Cadena rota: NO es seguro.
        safe() {
          [ "$(ps -o uid= -p "$1" 2>/dev/null | tr -d ' ')" = "$me" ] || return 1
          grep -qs '\.service$' "/proc/$1/cgroup" && return 1
          a=$(ps -o args= -p "$1" 2>/dev/null)
          for id in $ids; do case "$a" in *"$id"*) return 1 ;; esac; done
          x=$1; i=0
          while [ "$x" -gt 1 ]; do
            [ $i -lt 64 ] || return 1
            case " $panes $agents $managed " in *" $x "*) return 1 ;; esac
            if [ "$x" != "$1" ]; then case "$(nm "$x")" in \#(protectedNamePattern)) return 1 ;; esac; fi
            x=$(ps -o ppid= -p "$x" 2>/dev/null | tr -d ' ')
            case "$x" in ''|*[!0-9]*) return 1 ;; esac
            i=$((i + 1))
          done
          return 0
        }
        # ¿Sigue $1 en la familia de la raíz $2? Con la raíz viva (misma huella $3), tiene que
        # colgar de ella; muerta la raíz, sus hijos pasan a init y basta su propia huella.
        related() {
          [ "$1" = "$2" ] && return 0
          [ "$(fp "$2")" = "$3" ] || return 0
          x=$1; i=0
          while [ "$x" -gt 1 ] && [ $i -lt 64 ]; do
            x=$(ps -o ppid= -p "$x" 2>/dev/null | tr -d ' ')
            case "$x" in ''|*[!0-9]*) return 1 ;; esac
            [ "$x" = "$2" ] && return 0
            i=$((i + 1))
          done
          return 1
        }
        # Señal $1 a cada miembro (`raíz,pid=huella`) que siga siendo el mismo proceso, de la
        # misma familia y huérfano.
        signal() {
          for e in $fam; do
            r=${e%%,*}; k=${e#*,}; f=${k#*=}; k=${k%%=*}
            rf=""; for x in $roots; do [ "${x%%=*}" = "$r" ] && rf=${x#*=}; done
            [ -n "$f" ] && [ "$(fp "$k")" = "$f" ] && related "$k" "$r" "$rf" && safe "$k" && kill -s "$1" "$k" 2>/dev/null
          done
          return 0
        }
        alive() { kill -0 "$1" 2>/dev/null && [ "$(fp "$1")" = "$2" ] && ! ps -o stat= -p "$1" 2>/dev/null | grep -q '^ *Z'; }
        # Foto única de pid, padre y hora de arranque: la familia sale de aquí, sin carreras
        # entre leer el padre y la huella de cada uno.
        snap=$(ps -eo pid=,ppid=,lstart= 2>/dev/null | head -n 20000)
        family() {
          printf '%s\n' "$snap" | awk -v r="$1" '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
              f = $3; for (i = 4; i <= NF; i++) f = f "_" $i; fp[$1] = f; pp[$1] = $2; ids[++c] = $1 }
            END { if (!(r in fp)) exit
              print r "=" fp[r]
              for (k = 1; k <= c; k++) { x = pp[ids[k]]
                for (j = 0; j < 64 && x != ""; j++) { if (x == r) { print ids[k] "=" fp[ids[k]]; break }; x = pp[x] } } }'
        }
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
              m=$(family "$1")
              if [ "$(printf '%s\n' "$m" | head -n 1)" = "$1=$2" ] && [ "$(fp "$1")" = "$2" ] && [ "$(nm "$1")" = claude ] && safe "$1"; then
                roots="$roots $1=$2"
                for k in $m; do fam="$fam $1,$k"; done
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
