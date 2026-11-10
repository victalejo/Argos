//
//  GitHubCommands.swift
//  ArgosCore
//
//  Comandos `gh` remotos (cadenas puras, testeables). Corren en el SERVIDOR con su
//  sesión de `gh` (Argos no custodia tokens). Todo va bajo `sh`, entrecomillado con
//  `ShellQuoting`, sin prompts (`GH_PROMPT_DISABLED`) y con un tiempo máximo para que una
//  red lenta no deje la petición colgada.
//

import Foundation

enum GitHubCommands {

    /// Prefijo de las líneas de resultado (el perfil del shell puede ensuciar la salida).
    static let marker = "ARGOS_GH:"
    /// Segundos máximos de cada llamada de `gh` de consulta.
    static let queryTimeout = 20

    /// Entorno de `gh`: sin prompts, sin colores ni avisos de versión nueva.
    static let env = "GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1 GIT_TERMINAL_PROMPT=0"

    static let prFields = "number,title,url,state,isDraft,reviewDecision,statusCheckRollup"
    static let runFields = "databaseId,status,conclusion,workflowName,displayTitle,url,headSha,event,createdAt"
    static let repoFields = "nameWithOwner,description,isPrivate,updatedAt"

    private static func q(_ value: String) -> String { ShellQuoting.singleQuoted(value) }

    /// `t` = `timeout N` si existe (no está en todos los sistemas).
    private static let timeoutPrefix =
        "t=''; command -v timeout >/dev/null 2>&1 && t='timeout \(queryTimeout)'"

    /// PR de la rama actual + ejecuciones de Actions de HEAD, en un solo round-trip. Cada
    /// respuesta de `gh` va en UNA línea tras su marcador (JSON o el mensaje de error).
    static func status(root: String) -> String {
        ShellQuoting.posixShell("""
        command -v gh >/dev/null 2>&1 || { echo \(marker)missing; exit 0; }
        cd \(q(root)) 2>/dev/null || exit 0
        \(timeoutPrefix)
        sha=$(git rev-parse HEAD 2>/dev/null)
        b=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)
        printf '%ssha %s\\n' \(marker) "$sha"
        printf '%sbranch %s\\n' \(marker) "$b"
        if [ -n "$b" ]; then
          printf '%spr ' \(marker); \(env) $t gh pr view "$b" --json \(prFields) 2>&1 | tr '\\n' ' '; echo
        fi
        if [ -n "$sha" ]; then
          printf '%sruns ' \(marker); \(env) $t gh run list --commit "$sha" --limit 30 --json \(runFields) 2>&1 | tr '\\n' ' '; echo
        fi
        """)
    }

    /// Abre un PR de la rama actual con título y cuerpo de sus commits (`--fill`). La rama
    /// debe estar subida (si no, `gh` pediría dónde publicarla). Devuelve la URL del PR.
    static func createPullRequest(root: String, draft: Bool) -> String {
        ShellQuoting.posixShell(
            "cd \(q(root)) && \(env) gh pr create --fill\(draft ? " --draft" : "") 2>&1"
        )
    }

    /// Vuelve a lanzar solo los jobs fallidos de una ejecución.
    static func rerunFailed(root: String, runID: Int) -> String {
        ShellQuoting.posixShell("cd \(q(root)) && \(env) gh run rerun \(runID) --failed 2>&1")
    }

    /// Repositorios del usuario con sesión en `gh`, los más recientes primero.
    static func repositories(limit: Int = 200) -> String {
        ShellQuoting.posixShell("""
        command -v gh >/dev/null 2>&1 || { echo \(marker)missing; exit 0; }
        \(timeoutPrefix)
        printf '%srepos ' \(marker); \(env) $t gh repo list --limit \(limit) --json \(repoFields) 2>&1 | tr '\\n' ' '; echo
        """)
    }

    /// Exit code de `clone` cuando la carpeta destino ya existe o falta la carpeta padre.
    static let cloneRefusedExitCode = 3

    /// Clona `repository` (validado con `GitHubCloneRequest`) en `parent/folder` y escribe
    /// la ruta real resultante. Nunca pisa una carpeta existente.
    static func clone(_ request: GitHubCloneRequest) -> String {
        let parent = ClaudeAgentCommand.cdTarget(for: request.parent)
        return ShellQuoting.posixShell("""
        p=\(parent)
        [ -d "$p" ] || { echo \(marker)noparent; exit \(cloneRefusedExitCode); }
        d="$p"/\(q(request.folder))
        [ -e "$d" ] && { echo \(marker)exists; exit \(cloneRefusedExitCode); }
        \(env) gh repo clone \(q(request.repository)) "$d" -- --quiet 2>&1 || exit $?
        cd "$d" && printf '%spath %s\\n' \(marker) "$(pwd -P)"
        """)
    }
}

/// Petición validada de clonado: el repositorio (`dueño/nombre` o URL) y la carpeta.
struct GitHubCloneRequest: Hashable, Sendable {
    let repository: String
    let parent: String
    let folder: String

    enum ValidationError: LocalizedError, Equatable {
        case invalidRepository, invalidFolder, missingParent

        var errorDescription: String? {
            switch self {
            case .invalidRepository: return "Escribe el repositorio como «dueño/nombre» o pega su URL de GitHub."
            case .invalidFolder: return "El nombre de la carpeta no puede estar vacío ni contener «/»."
            case .missingParent: return "Elige la carpeta del servidor donde clonarlo."
            }
        }
    }

    /// Valida y normaliza. El repositorio nunca empieza por `-` (sería una opción de `gh`).
    static func make(repository: String, parent: String, folder: String) throws -> GitHubCloneRequest {
        let repo = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = parent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidRepository(repo) else { throw ValidationError.invalidRepository }
        guard !dir.isEmpty, !dir.contains("/"), dir != ".", dir != "..", !dir.hasPrefix("-") else {
            throw ValidationError.invalidFolder
        }
        guard !base.isEmpty else { throw ValidationError.missingParent }
        return GitHubCloneRequest(repository: repo, parent: base, folder: dir)
    }

    static func isValidRepository(_ value: String) -> Bool {
        if value.hasPrefix("https://") || value.hasPrefix("git@") {
            return !value.contains(where: \.isWhitespace)
        }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && !part.hasPrefix("-") && part != "." && part != ".."
                && part.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
        }
    }

    /// Carpeta por defecto: el último componente sin `.git` (`dueño/app.git` → `app`).
    static func defaultFolder(for repository: String) -> String {
        var name = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix("/") { name.removeLast() }
        name = String(name.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? "")
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name
    }
}
