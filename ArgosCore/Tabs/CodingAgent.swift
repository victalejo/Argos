//
//  CodingAgent.swift
//  Argos
//
//  Catálogo de agentes de terminal que se pueden lanzar en una ventana tmux desde el
//  menú «+» (Claude Code, Codex, Grok). Lógica pura y portable (Mac + iOS): nombre,
//  binario, atajo del menú, detección por el proceso en primer plano y el script que
//  averigua cuáles están instalados en el servidor.
//

import Foundation

enum CodingAgent: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case grok

    var id: String { rawValue }

    /// Nombre visible (pestaña, menú). También es el nombre que se le pone a la ventana
    /// tmux al lanzarlo, lo que permite reconocerla aunque el proceso cambie de nombre.
    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .grok: return "Grok"
        }
    }

    /// Ejecutable en el servidor.
    var binary: String { rawValue }

    /// Tecla del atajo en el menú «+» (⌘⌥1, ⌘⌥2…).
    var menuKey: Character {
        switch self {
        case .claude: return "1"
        case .codex: return "2"
        case .grok: return "3"
        }
    }

    /// Reconoce el agente de una ventana: por el proceso en primer plano
    /// (`pane_current_command`) o, si no coincide, por el nombre que Argos le puso
    /// a la ventana al lanzarlo (p. ej. si el agente corre como `node`). El nombre no
    /// cuenta si la ventana ya volvió a su shell: el agente salió.
    static func detect(command: String?, windowName: String) -> CodingAgent? {
        if let command {
            let normalized = command.trimmingCharacters(in: .whitespaces).lowercased()
            if let agent = allCases.first(where: { $0.binary == normalized }) { return agent }
            if WindowTabs.isIdleShell(normalized) { return nil }
        }
        return allCases.first { $0.displayName == windowName }
    }

    // MARK: - Detección de instalados

    /// Marca que precede a cada agente encontrado en la salida del script (para no
    /// confundir con el MOTD o el ruido del perfil del shell).
    static let installedMarker = "argos-agent:"

    /// Última línea del script: sin ella, el script se cortó y la lista no es fiable
    /// (mejor «no se sabe» que marcar todo como «no instalado»).
    static let installedDoneMarker = "argos-agents-done"

    /// Directorios habituales donde un agente puede estar fuera del PATH de un shell
    /// de login (instalador nativo, npm global, bun, Homebrew…).
    static let fallbackDirectories = [
        "$HOME/.local/bin", "$HOME/.claude/local", "$HOME/.npm-global/bin",
        "$HOME/.bun/bin", "$HOME/bin", "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin",
    ]

    /// Script de shell que imprime `argos-agent:<binario>` por cada agente instalado.
    /// Prueba el PATH del shell de login del usuario y, después, los directorios
    /// habituales y las versiones de Node de nvm. Solo usa constantes (sin entrada
    /// del usuario), así que no hay nada que entrecomillar. Es POSIX: se ejecuta con
    /// `ShellQuoting.posixShell` (con zsh, el comodín de nvm sin coincidencias abortaría).
    static var installedAgentsScript: String {
        let binaries = allCases.map(\.binary).joined(separator: " ")
        let directories = fallbackDirectories.map { "\"\($0)\"" }.joined(separator: " ")
        return """
        found=$("${SHELL:-sh}" -lc 'for b in \(binaries); do command -v "$b" >/dev/null 2>&1 && echo "$b"; done' 2>/dev/null)
        for b in \(binaries); do
          hit=""
          for f in $found; do [ "$f" = "$b" ] && hit=1; done
          if [ -z "$hit" ]; then
            for d in \(directories) "$HOME"/.nvm/versions/node/*/bin; do
              [ -x "$d/$b" ] && { hit=1; break; }
            done
          fi
          [ -n "$hit" ] && echo "\(installedMarker)$b"
        done
        echo "\(installedDoneMarker)"
        exit 0
        """
    }

    /// ¿El script llegó al final? Si no, su lista no es fiable.
    static func installedOutputIsComplete(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == installedDoneMarker }
    }

    /// Interpreta la salida de `installedAgentsScript`: solo cuentan las líneas con la
    /// marca y un binario conocido.
    static func parseInstalled(_ output: String) -> Set<CodingAgent> {
        var agents = Set<CodingAgent>()
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(installedMarker) else { continue }
            let binary = String(trimmed.dropFirst(installedMarker.count))
            if let agent = CodingAgent(rawValue: binary) { agents.insert(agent) }
        }
        return agents
    }
}

/// Agentes instalados por servidor: el menú «+» se pinta al instante con lo último
/// conocido mientras se vuelve a comprobar en segundo plano (Mac e iOS).
@MainActor
enum InstalledAgentsCache {
    static var agents: [Server.ID: Set<CodingAgent>] = [:]
}
