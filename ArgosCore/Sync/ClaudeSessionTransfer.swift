//
//  ClaudeSessionTransfer.swift
//  Argos
//
//  "Enviar al Mac" también trae la conversación de Claude Code (lógica pura): dónde la
//  guarda Claude en el servidor y cuál es la más reciente. Sin esto, el proyecto solo
//  continuaba en el Mac si `~/.claude` llegaba por otra vía (p. ej. Syncthing).
//
//  La app está en sandbox y no puede escribir en `~/.claude` del Mac: deja la
//  conversación en una carpeta de paso DENTRO de la copia local y el comando de
//  Terminal (`LocalTerminalLauncher`) la mueve a su sitio antes de reanudar.
//

import Foundation

enum ClaudeSessionTransfer {

    /// Carpeta de paso dentro de la copia local. Nunca viaja de vuelta al servidor
    /// (`SyncExclusions`) y Terminal la borra al colocar la conversación.
    static let stagingDirectory = ".argos-claude-sessions"

    /// Comando que imprime la carpeta donde Claude guarda las conversaciones del
    /// proyecto (`~/.claude/projects/<ruta con cada carácter no alfanumérico cambiado
    /// por '-'>`), o nada si no existe. Prueba la ruta física y la literal, por si la
    /// carpeta cuelga de un enlace simbólico.
    static func directoryCommand(root: String) -> String {
        let quoted = ShellQuoting.singleQuoted(root)
        return """
            p="$HOME/.claude/projects"; \
            for r in "$(cd \(quoted) 2>/dev/null && pwd -P)" \(quoted); do \
            [ -n "$r" ] || continue; \
            d="$p/$(printf '%s' "$r" | sed 's/[^A-Za-z0-9]/-/g')"; \
            if [ -d "$d" ]; then printf '%s' "$d"; break; fi; \
            done
            """
    }

    /// Carpeta de paso de VUELTA: al salir de Claude Code, Terminal deja aquí la
    /// conversación más reciente del Mac y «Enviar al servidor» la sube. Es distinta de la
    /// de ida para que una copia vieja nunca pise una conversación más nueva del Mac.
    static let exportDirectory = ".argos-claude-export"

    /// Como `directoryCommand`, pero crea la carpeta si el proyecto aún no tiene
    /// conversaciones en el servidor (para poder subir la del Mac).
    static func ensureDirectoryCommand(root: String) -> String {
        let quoted = ShellQuoting.singleQuoted(root)
        return """
            p="$HOME/.claude/projects"; f=""; \
            for r in "$(cd \(quoted) 2>/dev/null && pwd -P)" \(quoted); do \
            [ -n "$r" ] || continue; \
            d="$p/$(printf '%s' "$r" | sed 's/[^A-Za-z0-9]/-/g')"; \
            [ -n "$f" ] || f="$d"; \
            if [ -d "$d" ]; then f="$d"; break; fi; \
            done; \
            [ -n "$f" ] && mkdir -p "$f" && printf '%s' "$f"
            """
    }

    /// Carpeta de conversaciones a partir de la salida de `directoryCommand` (el servidor
    /// no es de confianza: solo una ruta absoluta de una línea).
    static func parseDirectory(_ output: String) -> String? {
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\0") else { return nil }
        return path
    }

    /// De todo lo que hay en la carpeta de conversaciones, lo que hay que traer: el
    /// `.jsonl` más reciente y su carpeta hermana `<id>/` (subagentes y resultados).
    static func latestSessionFiles(in files: [SyncFile]) -> [SyncFile] {
        let sessions = files.filter { file in
            !file.isSymlink && !file.path.contains("/") && sessionID(ofTranscript: file.path) != nil
        }
        guard let latest = sessions.max(by: { ($0.mtime, $0.path) < ($1.mtime, $1.path) }),
              let id = sessionID(ofTranscript: latest.path) else { return [] }
        let sidecar = files.filter { !$0.isSymlink && $0.path.hasPrefix(id + "/") }
        return [latest] + sidecar.sorted { $0.path < $1.path }
    }

    /// ID de la conversación si `name` es `<id>.jsonl` con un ID seguro (letras, números
    /// y guiones: acaba como argumento de `claude --resume`).
    static func sessionID(ofTranscript name: String) -> String? {
        guard name.hasSuffix(".jsonl") else { return nil }
        let id = String(name.dropLast(".jsonl".count))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !id.isEmpty, !id.hasPrefix("-"),
              id.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else { return nil }
        return id
    }
}
