//
//  ClaudeTranscript.swift
//  ArgosCore
//
//  Última respuesta de Claude Code sacada de su transcript (lógica pura + el trozo del
//  comando remoto). Claude Code redibuja la pantalla en su sitio y tmux no guarda
//  historial de ese panel: la captura solo trae lo visible y una respuesta larga empieza
//  por encima. El transcript (`~/.claude/projects/<carpeta>/<sesión>.jsonl`) tiene el
//  texto entero.
//
//  La carpeta es la ruta del panel con lo que no es letra o número cambiado por `-`
//  (`/srv/mi.app` → `-srv-mi-app`). Se lee el `.jsonl` más reciente, acotado al final
//  (`tail -c`) y solo las líneas del asistente. El servidor no es de fiar: cada línea se
//  valida y el texto se recorta.
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

    static func marker(_ nonce: String) -> String { "ARGOS_CT_\(nonce)" }

    /// Trozo de script (usa `$t`, el panel): imprime `marca|file|nombre`, las líneas del
    /// asistente y `marca|end`. Sin transcript, solo `marca|end`.
    static func commandLines(nonce: String) -> [String] {
        let m = marker(nonce)
        return [
            "m=\(m)",
            "d=$(tmux -u display -p -t \"$t\" '#{pane_current_path}' 2>/dev/null)",
            "if [ -n \"$d\" ]; then",
            "  k1=$(printf '%s' \"$d\" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')",
            "  k2=$(printf '%s' \"$d\" | sed 's/[/.]/-/g')",
            "  for k in \"$k1\" \"$k2\"; do",
            "    p=\"$HOME/.claude/projects/$k\"",
            "    [ -d \"$p\" ] || continue",
            "    f=$(ls -t \"$p\" 2>/dev/null | grep '\\.jsonl$' | head -n 1)",
            "    [ -n \"$f\" ] && [ -f \"$p/$f\" ] || continue",
            "    printf '%s|file|%s\\n' \"$m\" \"$f\"",
            "    tail -c \(tailBytes) \"$p/$f\" | grep '\"type\":\"assistant\"' | tail -n \(maxLines)",
            "    break",
            "  done",
            "fi",
            "printf '%s|end\\n' \"$m\"",
        ]
    }

    /// Líneas del transcript entre las marcas; `nil` si no se encontró ninguno.
    static func transcriptLines(in output: [String], nonce: String) -> [String]? {
        let prefix = marker(nonce) + "|"
        guard let start = output.firstIndex(where: { $0.hasPrefix(prefix + "file|") }) else { return nil }
        let end = output[(start + 1)...].firstIndex(of: prefix + "end") ?? output.endIndex
        return Array(output[(start + 1)..<end])
    }

    /// Texto del último mensaje del asistente que tenga texto (los bloques `text` de todas
    /// las líneas con su mismo `message.id`, en orden). Ignora herramientas, `thinking`, las
    /// de subagentes y lo que no se pueda leer.
    static func lastAssistantText(_ lines: [String]) -> String? {
        var messages: [(id: String, texts: [String])] = []
        for line in lines {
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
              object["isSidechain"] as? Bool != true,
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? [Any] else { return nil }
        let id = (message["id"] as? String) ?? (object["uuid"] as? String) ?? UUID().uuidString
        let texts: [String] = content.compactMap { (block: Any) -> String? in
            guard let block = block as? [String: Any], block["type"] as? String == "text",
                  let text = block["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        return (id: id, texts: texts)
    }
}
