//
//  ShellIntegrationBlock.swift
//  ArgosCore
//
//  Marcas de prompt OSC 133 (opcionales, desactivadas por defecto): un bloque marcado que
//  Argos añade al final de ~/.zshrc o ~/.bashrc del servidor para que el shell avise a
//  tmux de dónde empieza cada prompt (A), dónde acaba (B), dónde empieza la salida (C) y
//  cuándo terminó el comando (D). tmux ≥ 3.4 las guarda en sus líneas; con ellas «Copiar
//  la salida del último comando» es exacto (y `previous-prompt`/`next-prompt` funcionan).
//
//  Reglas: el bloque va entre dos líneas de marca; instalar sustituye el bloque anterior
//  (idempotente, nunca lo duplica), quitarlo deja el archivo como estaba sin él y nada
//  de fuera del bloque se toca. Solo corre en shells interactivos y una vez por shell.
//

import Foundation

enum ShellIntegrationBlock {

    enum Shell: String, CaseIterable, Sendable {
        case zsh
        case bash

        /// Archivo de arranque, relativo a `$HOME`.
        var rcFile: String {
            switch self {
            case .zsh: return ".zshrc"
            case .bash: return ".bashrc"
            }
        }

        /// Shell de `$SHELL` (`/usr/bin/zsh` → zsh).
        init?(loginShell: String) {
            let name = (loginShell.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
            self.init(rawValue: name)
        }
    }

    // Lo que se escribe en el servidor no se traduce: marcas y comentarios neutros.
    static let beginMarker = "# >>> argos osc133 >>>"
    static let endMarker = "# <<< argos osc133 <<<"
    /// Versión del bloque: al cambiar, «instalar» sustituye el viejo.
    static let version = 1

    static func block(for shell: Shell) -> String {
        let header = [
            beginMarker,
            "# v\(version) - Argos: OSC 133 prompt marks (A/B/C/D) for tmux.",
            "# Remove it from Argos, or delete this whole block.",
        ]
        return (header + body(for: shell) + [endMarker]).joined(separator: "\n")
    }

    private static func body(for shell: Shell) -> [String] {
        switch shell {
        case .zsh:
            return [
                "if [[ -o interactive ]] && [[ -z \"${ARGOS_OSC133-}\" ]]; then",
                "  ARGOS_OSC133=1",
                "  autoload -Uz add-zsh-hook",
                "  _argos_osc133_precmd() {",
                "    local s=$?",
                "    printf '\\033]133;D;%s\\033\\\\' \"$s\"",
                "    [[ \"$PS1\" == *'133;A'* ]] || PS1=$'%{\\e]133;A\\e\\\\%}'\"$PS1\"$'%{\\e]133;B\\e\\\\%}'",
                "  }",
                "  _argos_osc133_preexec() { printf '\\033]133;C\\033\\\\'; }",
                "  add-zsh-hook precmd _argos_osc133_precmd",
                "  add-zsh-hook preexec _argos_osc133_preexec",
                "fi",
            ]
        case .bash:
            return [
                "if [[ $- == *i* ]] && [[ -z \"${ARGOS_OSC133-}\" ]]; then",
                "  ARGOS_OSC133=1",
                "  _argos_osc133_prompt() {",
                "    local s=$?",
                "    printf '\\033]133;D;%s\\033\\\\' \"$s\"",
                "    [[ \"$PS1\" == *'133;A'* ]] || PS1='\\[\\e]133;A\\e\\\\\\]'\"$PS1\"'\\[\\e]133;B\\e\\\\\\]'",
                "    return $s",
                "  }",
                "  PROMPT_COMMAND=\"_argos_osc133_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}\"",
                "  PS0='\\e]133;C\\e\\\\'\"${PS0-}\"",
                "fi",
            ]
        }
    }

    // MARK: - Editar el archivo

    /// ¿Tiene el archivo el bloque (en cualquier versión)?
    static func isInstalled(in content: String) -> Bool {
        range(in: content) != nil
    }

    /// ¿Tiene el bloque en su versión actual?
    static func isCurrent(in content: String, shell: Shell) -> Bool {
        guard let range = range(in: content) else { return false }
        return content[range] == block(for: shell)
    }

    /// El archivo con el bloque actual al final (sustituye uno anterior en su sitio).
    static func installing(into content: String, shell: Shell) -> String {
        let block = block(for: shell)
        if let range = range(in: content) {
            var updated = content
            updated.replaceSubrange(range, with: block)
            return updated
        }
        var updated = content
        if !updated.isEmpty && !updated.hasSuffix("\n") { updated += "\n" }
        if !updated.isEmpty { updated += "\n" }
        return updated + block + "\n"
    }

    /// El archivo sin el bloque (y sin la línea en blanco que se añadió antes de él).
    static func removing(from content: String) -> String {
        guard let range = range(in: content) else { return content }
        var before = String(content[..<range.lowerBound])
        var after = String(content[range.upperBound...])
        if after.hasPrefix("\n") { after.removeFirst() }
        if before.hasSuffix("\n\n") { before.removeLast() }
        return before + after
    }

    /// Del principio de la línea de inicio al final de la de cierre.
    static func range(in content: String) -> Range<String.Index>? {
        guard let begin = content.range(of: beginMarker),
              let end = content.range(of: endMarker, range: begin.upperBound..<content.endIndex) else { return nil }
        // La marca de inicio debe empezar una línea.
        guard begin.lowerBound == content.startIndex || content[content.index(before: begin.lowerBound)] == "\n" else {
            return nil
        }
        return begin.lowerBound..<end.upperBound
    }
}

/// ¿Están las marcas de prompt instaladas en el servidor?
enum ShellIntegrationStatus: Equatable, Sendable {
    case notInstalled
    case installed
    /// Hay un bloque de una versión anterior (se actualiza al instalar).
    case outdated
}
