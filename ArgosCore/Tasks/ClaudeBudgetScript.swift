//
//  ClaudeBudgetScript.swift
//  ArgosCore
//
//  Presupuesto por proyecto en el servidor (texto de scripts; lógica pura). El despachador
//  (`ClaudeTaskScript`) incluye `functions` y llama a `budget_ok <proyecto> <encargo>` justo
//  antes de lanzar un pendiente: si el proyecto pasó su tope, el encargo sigue `pending` con
//  motivo `budget` y queda anotado el bloqueo en `<proyecto>.blocked` (lo lee el sondeo para
//  avisar una vez). La cuenta es la de `ClaudeBudgetEvaluation`, en awk.
//
//  Archivos (aditivos, en `~/.config/argos/budgets/`; fuera de `tasks/` para que el
//  despachador no los tome por un proyecto):
//      <proyecto>          v=1, window_pct=<1…100>, daily_usd=<USD>   (lo escribe la app)
//      <proyecto>.blocked  v=1 kind=window|daily used= cap= until=<epoch> since=<epoch>
//

import Foundation

enum ClaudeBudgetScript {

    static let directoryRelativePath = ".config/argos/budgets"

    static func configRelativePath(projectKey: String) -> String {
        "\(directoryRelativePath)/\(projectKey)"
    }

    /// Precios de `ClaudePricing` para awk: `prefijo=entrada:salida:cache5m:cache1h:lectura;…`.
    static var priceTable: String {
        ClaudePricing.table.map { row in
            let p = row.price
            return "\(row.prefix)=\(p.input):\(p.output):\(p.cacheWrite5m):\(p.cacheWrite1h):\(p.cacheRead)"
        }.joined(separator: ";")
    }

    /// Funciones del despachador. Usa `$base`, `put` y `$limits` del despachador.
    static var functions: String {
        #"""
        # Presupuesto por proyecto (ver ClaudeBudgetScript): ¿puede arrancar ya un encargo?
        budgets="${ARGOS_BUDGETS_DIR:-$HOME/\#(directoryRelativePath)}"
        usage="${ARGOS_USAGE_DIR:-$HOME/\#(ClaudeUsageIndex.directoryRelativePath)}"
        budget_fresh=""
        # Pone al día el índice de uso, una vez por ejecución y SIEMPRE en segundo plano (tiene
        # su propio cerrojo y solo guarda al terminar): se evalúa con lo que ya haya, así que
        # un encargo puede tardar un `tick` en notar el último gasto.
        budget_refresh() {
          [ -n "$budget_fresh" ] && return 0; budget_fresh=1
          idx="$HOME/\#(ClaudeUsageIndex.scriptRelativePath)"
          [ -f "$idx" ] || return 0
          [ -n "$(find "$usage/ledger.tsv" -mmin -1 2>/dev/null)" ] && return 0
          (nohup sh "$idx" >/dev/null 2>&1 &)
          return 0
        }
        # Sin pendientes, un bloqueo anotado ya no frena nada (p. ej. se canceló el encargo).
        budget_clear() { rm -f "$budgets/${1##*/}.blocked"; }
        # Imprime `ok` o `window|daily <usado> <tope> <se libera>` para el proyecto $1.
        budget_eval() {
          f="$budgets/$1"
          wp=$(sed -n 's/^window_pct=//p' "$f" 2>/dev/null | head -n 1)
          du=$(sed -n 's/^daily_usd=//p' "$f" 2>/dev/null | head -n 1)
          # Mismos rangos que la app (ClaudeProjectBudget): fuera de ellos, sin tope.
          case "$wp" in ''|*[!0-9]*) wp="" ;; *) [ ${#wp} -le 3 ] && [ "$wp" -ge 1 ] && [ "$wp" -le 100 ] || wp="" ;; esac
          printf '%s\n' "$du" | grep -Eq '^[0-9]+([.][0-9]+)?$' || du=""
          [ -z "$du" ] || [ ${#du} -le 12 ] && awk -v d="$du" 'BEGIN { exit !(d + 0 >= 0.01 && d + 0 <= 100000) }' || du=""
          [ -n "$wp$du" ] || { echo ok; return 0; }
          fh=""
          if [ -n "$wp" ] && [ -f "$limits" ] && grep -qs 'argos-claude-limits' "$HOME/.claude/settings.json"; then
            fh=$(LC_ALL=C awk '{ s = s $0 } END {
              if (!match(s, /"five_hour":[ ]*[{][^}]*[}]/)) exit
              o = substr(s, RSTART, RLENGTH); u = ""; r = ""
              if (match(o, /"used_percentage":[ ]*[0-9.]+/)) { u = substr(o, RSTART, RLENGTH); sub(/.*:[ ]*/, "", u) }
              if (match(o, /"resets_at":[ ]*[0-9]+/)) { r = substr(o, RSTART, RLENGTH); sub(/.*:[ ]*/, "", r) }
              if (r + 0 > 100000000000) r = int(r / 1000)
              if (u != "" && r != "") print u, r }' "$limits" 2>/dev/null)
          fi
          ds=$(date '+%s %H %M %S' | awk '{ print $1 - ($2 * 3600 + $3 * 60 + $4) }')
          LC_ALL=C awk -F'\t' -v now="$(date +%s)" -v ds="$ds" -v key="$1" -v wp="$wp" -v du="$du" \
            -v wu="${fh% *}" -v wr="${fh#* }" -v prices='\#(priceTable)' '
            function epoch(s,   y, m, d, era, yoe, doy, doe) {
              if (length(s) != 13) return -1
              y = substr(s, 1, 4) + 0; m = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
              y -= (m <= 2); era = int(y / 400); yoe = y - era * 400
              doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
              doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
              return (era * 146097 + doe - 719468) * 86400 + (substr(s, 12, 2) + 0) * 3600
            }
            function cost(model,   i, best, bl) {
              best = 0; bl = 0
              for (i = 1; i <= np; i++) if (index(model, pre[i]) == 1 && length(pre[i]) > bl) { best = i; bl = length(pre[i]) }
              if (!best) return 0
              return ($4 * pin[best] + $5 * pout[best] + $6 * p5[best] + $7 * p1[best] + $8 * pr[best]) / 1000000
            }
            BEGIN {
              np = split(prices, rows, ";")
              for (i = 1; i <= np; i++) { split(rows[i], kv, "="); split(kv[2], v, ":"); pre[i] = kv[1]; pin[i] = v[1]; pout[i] = v[2]; p5[i] = v[3]; p1[i] = v[4]; pr[i] = v[5] }
              ws = -1; if (wp != "" && wu != "" && wr + 0 > now + 0) ws = int((wr - 18000) / 3600) * 3600
              dh = int(ds / 3600) * 3600
            }
            NF >= 9 {
              t = epoch($1); if (t < 0 || t > now + 0) next
              c = cost($3)
              if (ws >= 0 && t >= ws) { all += c; if ($2 == key) mine += c }
              if (du != "" && t >= dh && $2 == key) day += c
            }
            END {
              if (ws >= 0 && all > 0 && wu * mine / all >= wp + 0) { printf "window %.2f %d %d\n", wu * mine / all, wp, wr; exit }
              if (du != "" && day >= du + 0) { printf "daily %.4f %s %d\n", day, du, ds + 86400; exit }
              print "ok"
            }' "$usage/ledger.tsv" 2>/dev/null || echo ok
        }
        # ¿Arranca el encargo $2 del proyecto $1? Si no, motivo `budget` y bloqueo anotado
        # (se conserva `since` mientras dure el mismo bloqueo: así se avisa una sola vez).
        budget_ok() {
          k=${1##*/}; [ -f "$budgets/$k" ] || { budget_clear "$k"; return 0; }
          # Fuera de `$(…)`: si no, la marca de «ya puesto al día» se perdería en la subshell.
          budget_refresh
          r=$(budget_eval "$k")
          set -- "$2" $r
          if [ "$2" != window ] && [ "$2" != daily ]; then rm -f "$budgets/$k.blocked"; return 0; fi
          put "$1" reason budget
          b="$budgets/$k.blocked"
          since=$(sed -n 's/^.* until=\([0-9]*\) since=\([0-9]*\).*$/\1 \2/p' "$b" 2>/dev/null)
          case "$since" in "$5 "*) since=${since#* } ;; *) since=$(date +%s) ;; esac
          printf 'v=1 kind=%s used=%s cap=%s until=%s since=%s\n' "$2" "$3" "$4" "$5" "$since" > "$b.$$" && mv -f "$b.$$" "$b"
          return 1
        }
        """#
    }

    /// Bloqueos vigentes, para el sondeo (`blocked <proyecto> <campos>` por línea).
    static let pollCommand = #"for f in "$HOME/\#(directoryRelativePath)"/*.blocked; do [ -f "$f" ] || continue; "#
        + #"n=${f##*/}; printf 'blocked %s %s\n' "${n%.blocked}" "$(head -c 256 "$f" | tr '\n\r' '  ')"; done; true"#

    /// Lo que necesita la pantalla del presupuesto de un proyecto: su configuración, su
    /// bloqueo, el reloj del servidor, los límites de la statusline y las filas del índice
    /// de las últimas 48 h.
    static func readCommand(projectKey: String) -> String {
        let file = ShellQuoting.singleQuoted(projectKey)
        return #"""
            d="$HOME/\#(directoryRelativePath)"; k=\#(file)
            printf '@@dispatcher\n'; s="$HOME/\#(ClaudeTaskScript.scriptRelativePath)"
            if [ ! -f "$s" ]; then echo missing; elif grep -q 'budget_ok' "$s"; then echo budget; else echo old; fi
            printf '@@config\n'; head -c 1024 "$d/$k" 2>/dev/null
            printf '\n@@blocked\n'; [ -f "$d/$k.blocked" ] && printf 'blocked %s %s\n' "$k" "$(head -c 256 "$d/$k.blocked" | tr '\n\r' '  ')"
            printf '@@clock\n'; date '+%s %H %M %S' | awk '{ print "now", $1; print "daystart", $1 - ($2 * 3600 + $3 * 60 + $4) }'
            printf '@@limits\n'; \#(ClaudeLimitsInstaller.pollCommand)
            printf '\n@@ledger\n'
            awk -F'\t' -v cut="$(( $(date +%s) - 172800 ))" '
              function epoch(s,   y, m, d, era, yoe, doy, doe) {
                if (length(s) != 13) return -1
                y = substr(s, 1, 4) + 0; m = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
                y -= (m <= 2); era = int(y / 400); yoe = y - era * 400
                doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
                doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
                return (era * 146097 + doe - 719468) * 86400 + (substr(s, 12, 2) + 0) * 3600
              }
              NF >= 9 && epoch($1) >= cut - 3600' "$HOME/\#(ClaudeUsageIndex.directoryRelativePath)/ledger.tsv" 2>/dev/null
            printf '@@end\n'; exit 0
            """#
    }

    /// Guarda la configuración (la app la sube antes por SFTP) y quita el bloqueo anotado:
    /// el siguiente `tick` vuelve a evaluar.
    static func clearBlockCommand(projectKey: String) -> String {
        "rm -f \"$HOME/\(directoryRelativePath)/\"\(ShellQuoting.singleQuoted(projectKey + ".blocked")); exit 0"
    }

    static func removeCommand(projectKey: String) -> String {
        let dir = "\"$HOME/\(directoryRelativePath)/\""
        return "rm -f \(dir)\(ShellQuoting.singleQuoted(projectKey)) \(dir)\(ShellQuoting.singleQuoted(projectKey + ".blocked")); exit 0"
    }
}

/// Lectura de `ClaudeBudgetScript.readCommand`.
struct ClaudeBudgetReading: Equatable, Sendable {
    /// El despachador instalado en el servidor.
    enum Dispatcher: Equatable, Sendable {
        /// Sabe de presupuestos.
        case budget
        /// Lo instaló una versión anterior de Argos (otro dispositivo): no frena.
        case outdated
        /// Aún no hay despachador (se instala al guardar o al encolar).
        case missing
        case unknown
    }

    let dispatcher: Dispatcher
    let budget: ClaudeProjectBudget
    let block: ClaudeBudgetBlock?
    /// Reloj del servidor.
    let serverNow: Date?
    /// Medianoche de hoy en la hora local del servidor.
    let dayStart: Date?
    let limits: ClaudeLimitsReading?
    let records: [ClaudeUsageRecord]

    init(output: String, localNow: Date = Date()) {
        var sections: [String: [String]] = [:]
        var current: String?
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                current = String(line.dropFirst(2))
                sections[current ?? "", default: []] = []
            } else if let current {
                sections[current, default: []].append(line)
            }
        }
        let clock = Dictionary(
            (sections["clock"] ?? []).compactMap { line -> (String, Double)? in
                let parts = line.split(separator: " ")
                guard parts.count == 2, let value = Double(parts[1]) else { return nil }
                return (String(parts[0]), value)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // La medianoche del servidor se pasa al reloj de este dispositivo.
        let offset = clock["now"].map { localNow.timeIntervalSince1970 - $0 } ?? 0
        switch sections["dispatcher"]?.first?.trimmingCharacters(in: .whitespaces) {
        case "budget": dispatcher = .budget
        case "old": dispatcher = .outdated
        case "missing": dispatcher = .missing
        default: dispatcher = .unknown
        }
        budget = ClaudeProjectBudget(configText: (sections["config"] ?? []).joined(separator: "\n"))
        block = (sections["blocked"] ?? []).lazy.compactMap(ClaudeBudgetBlock.init(pollLine:)).first
        serverNow = clock["now"].map { Date(timeIntervalSince1970: $0) }
        dayStart = clock["daystart"].map { Date(timeIntervalSince1970: $0 + offset) }
        limits = ClaudeLimitsReading(lines: sections["limits"] ?? [], localNow: localNow)
        records = (sections["ledger"] ?? []).compactMap(ClaudeUsageRecord.init(ledgerLine:))
    }

    /// Cuenta del despachador con lo leído.
    func evaluation(projectKey: String, now: Date = Date()) -> ClaudeBudgetEvaluation {
        let fiveHour = limits?.windows.first { $0.kind == ClaudeLimitWindow.fiveHour }
        let midnight = dayStart ?? Calendar.current.startOfDay(for: now)
        return ClaudeBudgetEvaluation.evaluate(
            budget, projectKey: projectKey, records: records, fiveHour: fiveHour, now: now, dayStart: midnight
        )
    }
}
