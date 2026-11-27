//
//  ClaudeTranscript.swift
//  ArgosCore
//
//  Última respuesta de Claude Code sacada de su transcript (lógica pura + los comandos
//  remotos). Claude Code redibuja la pantalla en su sitio y tmux no guarda historial de ese
//  panel: la captura solo trae lo visible y una respuesta larga empieza por encima. El
//  transcript (`~/.claude/projects/<carpeta>/<sesión>.jsonl`) tiene el texto entero.
//
//  Dos pasos: el comando de la pantalla imprime también la carpeta del panel; Argos calcula
//  aquí el nombre de la carpeta de Claude (cada unidad UTF-16 que no es letra o número
//  ASCII pasa a `-`, como hace Claude Code: «/srv/año» → `-srv-a-o`) y un segundo comando
//  lee el `.jsonl` más reciente, acotado al final y solo las líneas del asistente. El
//  servidor no es de fiar: cada línea se valida, el texto se recorta y, ante la duda (otra
//  sesión en la misma carpeta, un final que no coincide con la pantalla), se avisa o se
//  usa la pantalla.
//

import Foundation

enum ClaudeTranscript {

    /// Bytes del final del transcript que se leen.
    static let tailBytes = 2_000_000
    /// Líneas del asistente que se miran (las últimas).
    static let maxLines = 80
    /// Tope de una línea JSON y del texto copiado.
    static let maxLineLength = 1_000_000
    static let maxTextLength = 500_000
    /// Minutos en los que un `.jsonl` cuenta como sesión activa.
    static let recentMinutes = 10

    static func marker(_ nonce: String) -> String { "ARGOS_CT_\(nonce)" }

    // MARK: - Carpeta del panel

    /// Línea del comando de la pantalla (usa `$t`) que imprime la carpeta del panel.
    static func pathCommandLine(nonce: String) -> String {
        "printf '%s|path|%s\\n' \(marker(nonce)) \"$(tmux -u display -p -t \"$t\" '#{pane_current_path}' 2>/dev/null)\""
    }

    /// Carpeta del panel leída de la salida (absoluta y razonable), o `nil`.
    static func panePath(in output: [String], nonce: String) -> String? {
        let prefix = marker(nonce) + "|path|"
        guard let line = output.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let path = String(line.dropFirst(prefix.count))
        guard path.hasPrefix("/"), path.utf8.count <= 4096 else { return nil }
        return path
    }

    /// Nombres posibles de la carpeta de Claude para `path`: el de Claude Code y, por si
    /// acaso, el de versiones que solo cambiaban `/` y `.`.
    static func folderKeys(for path: String) -> [String] {
        let exact = String(decoding: path.utf16.map { (unit: UInt16) -> UInt8 in
            let isASCIIAlphanumeric = (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit)
            return isASCIIAlphanumeric ? UInt8(unit) : UInt8(ascii: "-")
        }, as: UTF8.self)
        let loose = path.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let looseIsSafe = loose.unicodeScalars.allSatisfy { $0 != "'" && $0 != "\n" }
        return looseIsSafe && loose != exact ? [exact, loose] : [exact]
    }

    // MARK: - Lectura del transcript

    /// Lee el `.jsonl` más reciente de la primera carpeta que exista: `marca|file|nombre|n`
    /// (`n`: cuántos se modificaron en los últimos minutos), las líneas del asistente y
    /// `marca|end`. Sin transcript, `marca|none`. `LC_ALL=C` y `-a`: una línea cortada a
    /// mitad de un carácter no convierte a grep en «Binary file matches».
    static func readCommand(keys: [String], nonce: String) -> String {
        let m = marker(nonce)
        let quoted = keys.map(ShellQuoting.singleQuoted).joined(separator: " ")
        return [
            "m=\(m)",
            "for k in \(quoted); do",
            "  p=\"$HOME/.claude/projects/$k\"",
            "  [ -d \"$p\" ] || continue",
            "  f=$(ls -t \"$p\" 2>/dev/null | LC_ALL=C grep -a '\\.jsonl$' | head -n 1)",
            "  [ -n \"$f\" ] && [ -f \"$p/$f\" ] || continue",
            "  r=$(find \"$p\" -maxdepth 1 -name '*.jsonl' -mmin -\(recentMinutes) 2>/dev/null | wc -l | tr -d ' ')",
            "  printf '%s|file|%s|%s\\n' \"$m\" \"$f\" \"$r\"",
            "  s=$(wc -c < \"$p/$f\" | tr -d ' ')",
            // Si se corta por el principio, la primera línea queda a medias: fuera.
            "  if [ \"${s:-0}\" -gt \(tailBytes) ]; then tail -c \(tailBytes) \"$p/$f\" | tail -n +2; else cat \"$p/$f\"; fi"
                + " | LC_ALL=C grep -a '\"type\":\"assistant\"' | tail -n \(maxLines)",
            "  printf '%s|end\\n' \"$m\"",
            "  exit 0",
            "done",
            "printf '%s|none\\n' \"$m\"",
        ].joined(separator: "\n")
    }

    /// Lo leído: las líneas del asistente y cuántas sesiones se tocaron hace poco.
    struct Excerpt: Equatable, Sendable {
        let lines: [String]
        /// `nil` si el servidor no lo dijo.
        let recentSessions: Int?
    }

    /// `nil` si no hay transcript o la lectura llegó incompleta (sin `|end`).
    static func excerpt(in output: String, nonce: String) -> Excerpt? {
        let prefix = marker(nonce) + "|"
        let all = output.components(separatedBy: "\n")
        guard let start = all.firstIndex(where: { $0.hasPrefix(prefix + "file|") }),
              let end = all[(start + 1)...].firstIndex(of: prefix + "end") else { return nil }
        let fields = all[start].dropFirst(prefix.count).split(separator: "|", omittingEmptySubsequences: false)
        let recent = fields.count >= 3 ? Int(fields[fields.count - 1]) : nil
        return Excerpt(lines: Array(all[(start + 1)..<end]), recentSessions: recent)
    }

    /// Texto del último mensaje del asistente que tenga texto (los bloques `text` de todas
    /// las líneas con su mismo `message.id`, en orden). Ignora herramientas, `thinking` y
    /// subagentes. Si la línea MÁS RECIENTE no se puede leer (rota, demasiado larga), no se
    /// fía de las anteriores: `nil` (se usa la pantalla).
    static func lastAssistantText(_ lines: [String]) -> String? {
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let newest = nonEmpty.last, assistantMessage(newest) != nil else { return nil }
        var messages: [(id: String, texts: [String])] = []
        for line in nonEmpty {
            guard let message = assistantMessage(line), !message.texts.isEmpty else { continue }
            messages.append(message)
        }
        guard let last = messages.last else { return nil }
        let texts = messages.filter { $0.id == last.id }.flatMap(\.texts)
        let joined = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        return String(joined.prefix(maxTextLength))
    }

    private static func assistantMessage(_ line: String) -> (id: String, texts: [String])? {
        guard line.utf8.count <= maxLineLength, line.hasPrefix("{"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? [Any] else { return nil }
        if object["isSidechain"] as? Bool == true { return (id: "", texts: []) }
        let id = (message["id"] as? String) ?? (object["uuid"] as? String) ?? UUID().uuidString
        let texts: [String] = content.compactMap { (block: Any) -> String? in
            guard let block = block as? [String: Any], block["type"] as? String == "text",
                  let text = block["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        return (id: id, texts: texts)
    }

    // MARK: - Comprobación con la pantalla

    /// ¿Aparece el final del texto del transcript en lo visible? Se comparan sin marcas de
    /// Markdown ni saltos (la pantalla parte las líneas y quita `**`, `` ` ``…).
    static func appearsOnScreen(_ text: String, screen lines: [String]) -> Bool {
        guard let lastLine = text.components(separatedBy: "\n").map(normalized).last(where: { !$0.isEmpty }) else {
            return false
        }
        let tail = String(lastLine.suffix(30))
        return normalized(lines.joined(separator: "\n")).contains(tail)
    }

    static func normalized(_ text: String) -> String {
        let withoutMarks = text.filter { !"*`#_▎│".contains($0) }
        return withoutMarks.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
