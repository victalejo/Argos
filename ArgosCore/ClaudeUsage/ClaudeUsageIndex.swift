//
//  ClaudeUsageIndex.swift
//  ArgosCore
//
//  Índice de uso de tokens de Claude Code en el servidor (script y formato; lógica pura).
//  Claude Code guarda cada respuesta en `~/.claude/projects/<proyecto>/<sesión>.jsonl` con
//  su `usage`; en un servidor real son GB, así que el script lee de forma INCREMENTAL (por
//  archivo recuerda hasta qué byte llegó), deduplica por `requestId` (Claude Code repite cada
//  respuesta en varias líneas y, al reanudar sesiones, en varios archivos) y agrega por hora
//  UTC, proyecto y modelo en `~/.config/argos/usage/ledger.tsv`. La primera vez puede tardar
//  minutos: se lanza en segundo plano y la app consulta `status`.
//
//  Solo POSIX sh + awk (sin jq ni python), con `LC_ALL=C` para que awk cuente bytes. Lo
//  comparten Mac, iPhone/iPad y Android (goldens): cambiarlo solo de forma aditiva.
//
//  ledger.tsv: `hora<TAB>proyecto<TAB>modelo<TAB>entrada<TAB>salida<TAB>cache5m<TAB>cache1h<TAB>lecturaCache<TAB>peticiones`
//  (`hora` = `AAAA-MM-DDTHH` en UTC; `proyecto` = nombre de la carpeta de Claude Code).
//  status: `running <epoch>` o `done <epoch> <archivos leídos> <peticiones nuevas>`.
//

import Foundation

enum ClaudeUsageIndex {

    static let marker = "argos-claude-usage"
    static let scriptRelativePath = ".config/argos/usage-index.sh"
    static let directoryRelativePath = ".config/argos/usage"
    /// Días hacia atrás que se indexan y se conservan.
    static let retentionDays = 40

    /// Script del índice. Variables opcionales (para pruebas): `ARGOS_CLAUDE_PROJECTS` y
    /// `ARGOS_USAGE_DIR`.
    static let script = """
        # \(marker) v1: indexa el uso de tokens de Claude Code por hora, proyecto y modelo.
        src="${ARGOS_CLAUDE_PROJECTS:-$HOME/.claude/projects}"
        dir="${ARGOS_USAGE_DIR:-$HOME/\(directoryRelativePath)}"
        umask 077
        mkdir -p "$dir" || exit 1
        if ! mkdir "$dir/lock" 2>/dev/null; then
          # Un cerrojo de hace más de 30 min es de una ejecución que murió.
          [ -n "$(find "$dir/lock" -prune -mmin +30 2>/dev/null)" ] || exit 75
          rm -rf "$dir/lock" && mkdir "$dir/lock" || exit 75
        fi
        trap 'rm -f "$dir/new.$$" "$dir/offsets.$$" "$dir/seen.$$" "$dir/ledger.$$" "$dir/files.$$"; rm -rf "$dir/lock"' EXIT
        trap 'exit 1' INT TERM HUP
        printf 'running %s\\n' "$(date +%s)" > "$dir/status"
        touch "$dir/offsets.tsv" "$dir/seen.tsv" "$dir/ledger.tsv"
        : > "$dir/new.$$"; : > "$dir/offsets.$$"; : > "$dir/files.$$"
        cut=$(date -u -d "-\(retentionDays) days" +%Y-%m-%d 2>/dev/null || date -u -v-\(retentionDays)d +%Y-%m-%d 2>/dev/null)
        # Tamaños de todos los archivos en un solo `wc`, cruzados con los offsets en un solo
        # awk: solo se abren los que crecieron (los demás conservan su offset).
        find "$src" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -mtime -\(retentionDays) -exec wc -c {} + 2>/dev/null \\
          | LC_ALL=C awk -v offs="$dir/offsets.tsv" -v keep="$dir/offsets.$$" '
            BEGIN { while ((getline l < offs) > 0) { t = index(l, "\\t"); if (t) o[substr(l, 1, t - 1)] = substr(l, t + 1) + 0 } }
            {
              size = $1 + 0; f = $0; sub(/^ *[0-9]+ /, "", f)
              if (f == "total" || f == "") next
              off = (f in o) ? o[f] : 0; if (off > size) off = 0
              if (off < size) printf "%d\\t%d\\t%s\\n", off, size, f; else printf "%s\\t%d\\n", f, off >> keep
            }' > "$dir/files.$$"
        tab=$(printf '\\t')
        while IFS="$tab" read -r off size f; do
          [ -n "$f" ] || continue
          p=${f%/*}; p=${p##*/}
          tail -c +$((off + 1)) "$f" | LC_ALL=C awk -v p="$p" -v f="$f" -v base="$off" -v avail=$((size - off)) -v out="$dir/offsets.$$" '
              function str(s, k) { if (match(s, "\\"" k "\\":\\"[^\\"]*\\"")) return substr(s, RSTART + length(k) + 4, RLENGTH - length(k) - 5); return "" }
              function num(s, k) { if (match(s, "\\"" k "\\":[0-9]+")) return substr(s, RSTART + length(k) + 3, RLENGTH - length(k) - 3) + 0; return 0 }
              {
                pos += length($0) + 1
                if (pos > avail) { pos -= length($0) + 1; exit }
                u = index($0, "\\"usage\\":{")
                if (u == 0 || index($0, "\\"type\\":\\"assistant\\"") == 0) next
                id = str($0, "requestId"); if (id == "") { m = substr($0, index($0, "\\"message\\":{")); id = str(m, "id") }
                if (id == "") next
                ts = str($0, "timestamp"); if (length(ts) < 13) next
                m = substr($0, index($0, "\\"message\\":{")); model = str(m, "model"); if (model == "") model = "?"
                us = substr($0, u)
                cw = num(us, "cache_creation_input_tokens"); c5 = num(us, "ephemeral_5m_input_tokens"); c1 = num(us, "ephemeral_1h_input_tokens")
                if (c5 + c1 == 0) c5 = cw
                printf "%s\\t%s\\t%s\\t%s\\t%d\\t%d\\t%d\\t%d\\t%d\\n", id, substr(ts, 1, 13), p, model, num(us, "input_tokens"), num(us, "output_tokens"), c5, c1, num(us, "cache_read_input_tokens")
              }
              END { printf "%s\\t%d\\n", f, base + pos >> out }' >> "$dir/new.$$"
        done < "$dir/files.$$"
        LC_ALL=C awk -F'\\t' -v OFS='\\t' -v cut="$cut" -v seenout="$dir/seen.$$" -v ledgerout="$dir/ledger.$$" '
          FILENAME == ARGV[1] { if (cut == "" || $2 >= cut) { seen[$1] = 1; print > seenout }; next }
          FILENAME == ARGV[2] { if (cut == "" || substr($1, 1, 10) >= cut) { k = $1 OFS $2 OFS $3; for (i = 4; i <= 9; i++) a[k, i] += $i; keys[k] = 1 }; next }
          {
            if ($1 in seen) next
            if (cut != "" && substr($2, 1, 10) < cut) next
            if (!($1 in hour)) { hour[$1] = $2; proj[$1] = $3; mod[$1] = $4 }
            for (i = 5; i <= 9; i++) if ($i + 0 > v[$1, i]) v[$1, i] = $i + 0
          }
          END {
            for (id in hour) {
              k = hour[id] OFS proj[id] OFS mod[id]; keys[k] = 1
              for (i = 5; i <= 9; i++) a[k, i - 1] += v[id, i]
              a[k, 9]++; added++
              print id, substr(hour[id], 1, 10) > seenout
            }
            for (k in keys) print k, a[k, 4] + 0, a[k, 5] + 0, a[k, 6] + 0, a[k, 7] + 0, a[k, 8] + 0, a[k, 9] + 0 > ledgerout
            print added + 0 > (seenout ".count")
          }' "$dir/seen.tsv" "$dir/ledger.tsv" "$dir/new.$$" || exit 1
        added=$(cat "$dir/seen.$$.count" 2>/dev/null); rm -f "$dir/seen.$$.count"
        n=$(wc -l < "$dir/files.$$" 2>/dev/null | tr -d ' ')
        mv -f "$dir/seen.$$" "$dir/seen.tsv" && mv -f "$dir/ledger.$$" "$dir/ledger.tsv" && mv -f "$dir/offsets.$$" "$dir/offsets.tsv"
        printf 'done %s %s %s\\n' "$(date +%s)" "${n:-0}" "${added:-0}" > "$dir/status"
        exit 0

        """

    /// Pone el script al día y lo lanza en segundo plano (si ya corre, el cerrojo lo deja
    /// pasar sin hacer nada). Sale enseguida.
    static let startCommand = "(nohup sh \"$HOME/\(scriptRelativePath)\" >/dev/null 2>&1 &); exit 0"

    /// Estado y agregado: `status …`, `running` si hay cerrojo y luego las filas del ledger.
    static let readCommand = "d=\"$HOME/\(directoryRelativePath)\"; "
        + "printf 'status %s\\n' \"$(cat \"$d/status\" 2>/dev/null)\"; "
        + "[ -d \"$d/lock\" ] && printf 'running\\n'; "
        + "cat \"$d/ledger.tsv\" 2>/dev/null; exit 0"
}
