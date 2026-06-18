//
//  UpdateChecker.swift
//  Argos
//
//  Comprobador de actualizaciones: consulta el último GitHub Release del repo y, si
//  su versión es mayor que la instalada, ofrece descargar el DMG. La red saliente ya
//  está cubierta por el entitlement `network.client` (el mismo del SSH).
//
//  La lógica de decisión (`evaluate`) es pura y testeable; el `fetch` es una capa fina
//  sobre URLSession.
//

import Foundation
import Observation

/// Release de GitHub (subconjunto de campos que usamos de la API REST).
struct GitHubRelease: Decodable, Sendable {
    let tagName: String
    let htmlURL: String
    let body: String?
    let assets: [Asset]

    struct Asset: Decodable, Sendable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case assets
    }
}

enum UpdateCheckError: LocalizedError {
    case badResponse(Int)
    case unrecognizedVersion

    var errorDescription: String? {
        switch self {
        case .badResponse(let code):
            return "Respuesta inesperada de GitHub (código \(code))."
        case .unrecognizedVersion:
            return "No se pudo interpretar la versión publicada."
        }
    }
}

/// Comprobador de actualizaciones observable. Singleton para que el comando de menú y
/// la UI compartan estado.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct UpdateInfo: Equatable, Sendable {
        let version: String          // tag tal cual (p. ej. "v1.0.3")
        let notes: String
        let releaseURL: URL
        let downloadURL: URL?        // DMG si el release lo adjunta
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(UpdateInfo)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// `true` si la última comprobación la pidió el usuario (para mostrar feedback
    /// "estás al día" / error; los chequeos automáticos al arrancar son silenciosos).
    private(set) var wasManual = false

    let currentVersion: String

    private let owner = "victalejo"
    private let repo = "Argos"
    private let session: URLSession

    /// Chequeo en curso. Cancelar el anterior al lanzar uno nuevo garantiza que
    /// `state`/`wasManual` reflejen un único chequeo ganador (el más reciente).
    private var checkTask: Task<Void, Never>?
    /// El chequeo de arranque se ejecuta una sola vez (no en cada reaparición de la vista).
    private var didLaunchCheck = false

    init(currentVersion: String? = nil, session: URLSession = .shared) {
        self.currentVersion = currentVersion
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "0.0"
        self.session = session
    }

    /// Chequeo silencioso al arrancar: solo se muestra UI si hay actualización. Idempotente.
    func checkOnLaunch() {
        guard !didLaunchCheck else { return }
        didLaunchCheck = true
        check(manual: false)
    }

    /// Chequeo pedido por el usuario: muestra resultado aunque esté al día o falle.
    /// Cancela cualquier chequeo en vuelo para que no se intercalen resultados.
    func check(manual: Bool) {
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            await self?.runCheck(manual: manual)
        }
    }

    private func runCheck(manual: Bool) async {
        wasManual = manual
        state = .checking
        do {
            let release = try await fetchLatest()
            if Task.isCancelled { return }
            state = Self.evaluate(release: release, current: currentVersion)
        } catch {
            if Task.isCancelled { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(message)
        }
    }

    /// Cierra cualquier UI de resultado (vuelve a inactivo).
    func dismiss() {
        state = .idle
    }

    private func fetchLatest() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Argos-macOS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.badResponse(-1)
        }
        guard http.statusCode == 200 else {
            throw UpdateCheckError.badResponse(http.statusCode)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    /// Decide el estado a partir del release y la versión actual. Pura y testeable.
    nonisolated static func evaluate(release: GitHubRelease, current: String) -> State {
        guard let latest = AppVersion(release.tagName), let installed = AppVersion(current) else {
            return .failed(UpdateCheckError.unrecognizedVersion.localizedDescription)
        }
        guard latest > installed else { return .upToDate }

        // Defensa en profundidad: solo abrimos URLs https hacia dominios de GitHub.
        // Si el html_url del release no es de confianza, no surfaceamos la actualización.
        guard let releaseURL = URL(string: release.htmlURL), isTrustedGitHubURL(releaseURL) else {
            return .upToDate
        }

        let dmg = release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        let downloadURL = dmg
            .flatMap { URL(string: $0.browserDownloadURL) }
            .flatMap { isTrustedGitHubURL($0) ? $0 : nil }

        let info = UpdateInfo(
            version: release.tagName,
            notes: release.body ?? "",
            releaseURL: releaseURL,
            downloadURL: downloadURL
        )
        return .updateAvailable(info)
    }

    /// `true` si la URL es https y apunta a un dominio de GitHub (web o descargas).
    nonisolated static func isTrustedGitHubURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com"
            || host.hasSuffix(".github.com")
            || host.hasSuffix(".githubusercontent.com")
    }
}
