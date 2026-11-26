//
//  ClaudeLimitsInstaller.swift
//  ArgosCore
//
//  Statusline de Argos para leer los límites de uso de Claude (lógica pura). Claude Code
//  solo entrega `rate_limits` (ventana de 5 h, semanal…) a su statusline, así que Argos
//  pone la suya: un script que guarda ese JSON en `~/.config/argos/claude-limits.json` y
//  luego ejecuta la statusline que el usuario tuviera, con la misma entrada (su barra se
//  sigue viendo igual). Es opcional y se puede quitar: al quitarla vuelve la anterior.
//
//  El comando anterior se guarda en `~/.config/argos/statusline-previous`: una cabecera
//  (`previousHeader`) y debajo el comando (vacío = no había). Sin cabecera, el archivo falta
//  o no es nuestro (p. ej. settings.json sincronizado desde otro servidor) y Argos se niega
//  a quitar la statusline para no perder la del usuario. El script y el formato los comparten Mac, iPhone/iPad y Android
//  (goldens): cambiarlos solo de forma aditiva.
//

import Foundation

enum ClaudeLimitsInstaller {

    /// Marca del comando de Argos en `statusLine.command`.
    static let marker = "argos-claude-limits"
    static let scriptRelativePath = ".config/argos/statusline.sh"
    static let previousRelativePath = ".config/argos/statusline-previous"
    static let limitsRelativePath = ".config/argos/claude-limits.json"

    /// Lo que se pone en `statusLine.command` (Claude Code lo ejecuta con un shell).
    static let command = "sh \"$HOME/\(scriptRelativePath)\" # \(marker)"

    /// Script de la statusline. POSIX sh (dash), sin jq ni python, y siempre sale con 0.
    /// Solo reescribe el archivo cuando la entrada trae porcentajes (al arrancar Claude
    /// Code aún no los tiene), y lo hace de forma atómica y privada (0600).
    static let script = """
        # \(marker): Argos guarda los límites de uso de Claude (rate_limits) que Claude Code
        # pasa a la statusline y después ejecuta la statusline anterior del usuario.
        d="$HOME/.config/argos"
        i=$(cat)
        case $i in
        *'"rate_limits"'*'"used_percentage"'*)
          umask 077
          t="$d/claude-limits.json.$$"
          mkdir -p "$d" 2>/dev/null && { date +%s; printf '%s\\n' "$i"; } > "$t" 2>/dev/null \\
            && mv -f "$t" "$d/claude-limits.json" 2>/dev/null || rm -f "$t" 2>/dev/null
          ;;
        esac
        p=$(sed 1d "$d/statusline-previous" 2>/dev/null)
        [ -n "$p" ] && printf '%s' "$i" | sh -c "$p"
        exit 0

        """

    // MARK: - Comando anterior

    /// Primera línea del archivo del comando anterior.
    static let previousHeader = "# \(marker) statusline-previous v1"

    /// Contenido del archivo: cabecera y el comando (`""` = no había statusline).
    static func previousFileContents(_ command: String) -> String {
        previousHeader + "\n" + command + "\n"
    }

    /// Comando anterior guardado. `nil` si el archivo falta o no lleva la cabecera.
    static func previousCommand(fromFile text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first.map(String.init) == previousHeader else { return nil }
        return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Estado

    /// ¿Está puesta la statusline de Argos (de cualquier versión)?
    static func isInstalled(in settings: [String: Any]) -> Bool {
        statusLineCommand(settings)?.contains(marker) ?? false
    }

    /// ¿Está puesta y con el comando actual?
    static func isCurrent(in settings: [String: Any]) -> Bool {
        statusLineCommand(settings) == command
    }

    private static func statusLineCommand(_ settings: [String: Any]) -> String? {
        (settings["statusLine"] as? [String: Any])?["command"] as? String
    }

    // MARK: - Fusión

    /// Resultado de instalar: settings nuevos y, si hay que escribirlo, el comando anterior
    /// que la statusline de Argos debe seguir ejecutando (`""` = no había).
    struct Installation {
        let settings: [String: Any]
        /// `nil` = no tocar el archivo (ya estaba instalada: conserva lo guardado).
        let previousCommand: String?
    }

    /// Pone la statusline de Argos y conserva el resto de `statusLine` (padding…).
    static func installing(into settings: [String: Any]) -> Installation {
        var result = settings
        var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
        let existing = statusLine["command"] as? String
        let wasOurs = existing?.contains(marker) ?? false
        statusLine["type"] = "command"
        statusLine["command"] = command
        result["statusLine"] = statusLine
        return Installation(settings: result, previousCommand: wasOurs ? nil : (existing ?? ""))
    }

    /// Quita la statusline de Argos y devuelve la anterior (`previous`, ya leída del archivo;
    /// `""` = no había, y entonces se quita `statusLine`). Si la actual no es la de Argos, no
    /// toca nada.
    static func removing(from settings: [String: Any], previousCommand previous: String) -> [String: Any] {
        guard isInstalled(in: settings) else { return settings }
        var result = settings
        let restored = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        if restored.isEmpty {
            result["statusLine"] = nil
        } else {
            var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
            statusLine["command"] = restored
            result["statusLine"] = statusLine
        }
        return result
    }

    // MARK: - Sondeo

    /// Cuerpo de la sección `limits` del sondeo: hora del servidor y el archivo, solo si la
    /// statusline de Argos sigue puesta (tras quitarla no se enseñan datos viejos).
    static let pollCommand = "printf 'now %s\\n' \"$(date +%s)\"; "
        + "grep -qs '\(marker)' \"$HOME/.claude/settings.json\" && cat \"$HOME/\(limitsRelativePath)\" 2>/dev/null"
}
