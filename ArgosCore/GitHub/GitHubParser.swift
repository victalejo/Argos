//
//  GitHubParser.swift
//  ArgosCore
//
//  Parser puro de la salida de `GitHubCommands`: líneas `ARGOS_GH:<clave> <valor>`,
//  donde el valor de `pr`/`runs`/`repos` es el JSON de `gh` o su mensaje de error.
//

import Foundation

enum GitHubParser {

    /// Valor de cada clave (la última aparición gana; el ruido del perfil se ignora).
    static func fields(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: GitHubCommands.marker) else { continue }
            let rest = line[range.upperBound...]
            let key = rest.prefix { $0 != " " }
            let value = rest.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            result[String(key)] = value
        }
        return result
    }

    // MARK: - Estado

    static func parseStatus(_ output: String) -> GitHubStatusResult {
        let fields = fields(output)
        if fields["missing"] != nil { return .ghMissing }
        guard let sha = fields["sha"], !sha.isEmpty else { return .notGitHub }
        let branch = fields["branch"].flatMap { $0.isEmpty ? nil : $0 }

        var pullRequest: GitHubPullRequest?
        var warnings: [String] = []
        if let raw = fields["pr"] {
            switch classify(raw) {
            case .json(let data): pullRequest = decodePullRequest(data)
            case .noPullRequest: break
            case .notAuthenticated: return .notAuthenticated
            case .notGitHub: return .notGitHub
            case .error(let message): warnings.append(message)
            }
        }
        var runs: [GitHubRun] = []
        if let raw = fields["runs"] {
            switch classify(raw) {
            case .json(let data): runs = latestPerWorkflow(decodeRuns(data))
            case .noPullRequest: break
            case .notAuthenticated: return .notAuthenticated
            case .notGitHub: return .notGitHub
            case .error(let message): warnings.append(message)
            }
        }
        // Si TODAS las consultas fallaron no hay nada que enseñar: es un error.
        let asked = [fields["pr"], fields["runs"]].compactMap { $0 }.count
        if asked > 0, warnings.count == asked, let first = warnings.first {
            return .failed(first)
        }
        return .loaded(GitHubSnapshot(
            headSha: sha, branch: branch, pullRequest: pullRequest, runs: runs,
            warning: warnings.first
        ))
    }

    enum Classified: Equatable {
        case json(Data)
        case noPullRequest
        case notAuthenticated
        case notGitHub
        case error(String)
    }

    /// Distingue el JSON de los errores conocidos de `gh` (que van por stderr → misma línea).
    static func classify(_ raw: String) -> Classified {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") || text.hasPrefix("[") { return .json(Data(text.utf8)) }
        let lower = text.lowercased()
        if lower.contains("no pull requests found") { return .noPullRequest }
        if lower.contains("gh auth login") || lower.contains("not logged in") || lower.contains("authentication") {
            return .notAuthenticated
        }
        if lower.contains("none of the git remotes") || lower.contains("not a git repository")
            || lower.contains("could not determine base repo") || lower.contains("no git remotes") {
            return .notGitHub
        }
        if text.isEmpty { return .error("gh no devolvió nada.") }
        return .error(String(text.prefix(400)))
    }

    // MARK: - JSON

    private struct RawRollupItem: Decodable {
        let __typename: String?
        // CheckRun
        let name: String?
        let workflowName: String?
        let status: String?
        let conclusion: String?
        let detailsUrl: String?
        // StatusContext
        let context: String?
        let state: String?
        let targetUrl: String?
    }

    private struct RawPullRequest: Decodable {
        let number: Int
        let title: String
        let url: String?
        let state: String
        let isDraft: Bool?
        let reviewDecision: String?
        let statusCheckRollup: [RawRollupItem]?
    }

    private struct RawRun: Decodable {
        let databaseId: Int
        let status: String?
        let conclusion: String?
        let workflowName: String?
        let displayTitle: String?
        let url: String?
        let event: String?
        let createdAt: String?
    }

    private struct RawRepository: Decodable {
        let nameWithOwner: String
        let description: String?
        let isPrivate: Bool?
        let updatedAt: String?
    }

    static func decodePullRequest(_ data: Data) -> GitHubPullRequest? {
        guard let raw = try? JSONDecoder().decode(RawPullRequest.self, from: data) else { return nil }
        let checks = (raw.statusCheckRollup ?? []).map { item -> GitHubCheck in
            if item.__typename == "StatusContext" {
                return GitHubCheck(name: item.context ?? "estado", workflow: "",
                                   state: .from(contextState: item.state), url: url(item.targetUrl))
            }
            return GitHubCheck(name: item.name ?? "check", workflow: item.workflowName ?? "",
                               state: .from(status: item.status, conclusion: item.conclusion),
                               url: url(item.detailsUrl))
        }
        return GitHubPullRequest(
            number: raw.number, title: raw.title, url: url(raw.url),
            state: GitHubPullRequest.State(rawValue: raw.state.uppercased()) ?? .open,
            isDraft: raw.isDraft ?? false,
            review: raw.reviewDecision.flatMap { GitHubPullRequest.Review(rawValue: $0) },
            checks: checks
        )
    }

    static func decodeRuns(_ data: Data) -> [GitHubRun] {
        guard let raw = try? JSONDecoder().decode([RawRun].self, from: data) else { return [] }
        return raw.map {
            GitHubRun(
                id: $0.databaseId, workflow: $0.workflowName ?? "Workflow", title: $0.displayTitle ?? "",
                state: .from(status: $0.status, conclusion: $0.conclusion), url: url($0.url),
                event: $0.event ?? "", createdAt: date($0.createdAt)
            )
        }
    }

    /// Una ejecución por workflow (la más reciente: un re-push del mismo commit crea otra).
    static func latestPerWorkflow(_ runs: [GitHubRun]) -> [GitHubRun] {
        var latest: [String: GitHubRun] = [:]
        for run in runs {
            if let current = latest[run.workflow],
               (current.createdAt ?? .distantPast, current.id) >= (run.createdAt ?? .distantPast, run.id) {
                continue
            }
            latest[run.workflow] = run
        }
        return latest.values.sorted { $0.workflow.localizedStandardCompare($1.workflow) == .orderedAscending }
    }

    // MARK: - Repositorios y operaciones

    enum RepositoriesResult: Equatable {
        case ghMissing
        case notAuthenticated
        case loaded([GitHubRepository])
        case failed(String)
    }

    static func parseRepositories(_ output: String) -> RepositoriesResult {
        let fields = fields(output)
        if fields["missing"] != nil { return .ghMissing }
        guard let raw = fields["repos"] else { return .failed("gh no devolvió la lista de repositorios.") }
        switch classify(raw) {
        case .json(let data):
            guard let repos = try? JSONDecoder().decode([RawRepository].self, from: data) else {
                return .failed("Respuesta de gh no válida.")
            }
            return .loaded(repos.map {
                GitHubRepository(nameWithOwner: $0.nameWithOwner, description: $0.description ?? "",
                                 isPrivate: $0.isPrivate ?? false, updatedAt: date($0.updatedAt))
            })
        case .notAuthenticated: return .notAuthenticated
        case .noPullRequest, .notGitHub: return .loaded([])
        case .error(let message): return .failed(message)
        }
    }

    /// Ruta real de la carpeta clonada (`nil` si la salida no la trae).
    static func clonedPath(_ output: String) -> String? {
        fields(output)["path"].flatMap { $0.hasPrefix("/") ? $0 : nil }
    }

    /// Por qué se negó el clonado (carpeta existente o padre inexistente).
    static func cloneRefusal(_ output: String) -> String? {
        let fields = fields(output)
        if fields["exists"] != nil { return "Ya existe una carpeta con ese nombre. Elige otro." }
        if fields["noparent"] != nil { return "La carpeta donde clonar no existe en el servidor." }
        return nil
    }

    /// URL que `gh pr create` imprime en su última línea.
    static func createdPullRequestURL(_ output: String) -> URL? {
        output.split(whereSeparator: \.isNewline).reversed()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("https://") }
            .flatMap(URL.init(string:))
    }

    private static func url(_ string: String?) -> URL? {
        guard let string, string.hasPrefix("https://") else { return nil }
        return URL(string: string)
    }

    private static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }
}
