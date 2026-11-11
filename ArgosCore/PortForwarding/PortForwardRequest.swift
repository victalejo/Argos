//
//  PortForwardRequest.swift
//  ArgosCore
//
//  Solicitudes de Claude para abrir un puerto (`argos-ports open PUERTO [NOTA]` en el
//  servidor). Argos las muestra y SOLO abre el túnel si el usuario acepta.
//

import Foundation
import Observation

/// Una solicitud pendiente.
struct PortForwardRequest: Identifiable, Hashable, Sendable {
    let port: Int
    /// Nota de Claude («La web de inventario»); vacía si no puso ninguna.
    let note: String
    /// Antigüedad según el reloj del servidor.
    let ageSeconds: Int

    var id: Int { port }
}

enum PortForwardRequestParser {

    /// Máximo de caracteres de la nota que se muestran.
    static let noteLimit = 200

    /// Primera línea numérica = hora del servidor; después `puerto<TAB>creada<TAB>nota`.
    /// Ignora puertos inválidos y solicitudes caducadas; las más antiguas primero.
    static func parse(_ output: String) -> [PortForwardRequest] {
        var now: Int?
        var requests: [(created: Int, request: PortForwardRequest)] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if now == nil {
                if let value = Int(line.trimmingCharacters(in: .whitespaces)) { now = value }
                continue
            }
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, let now,
                  let port = Int(fields[0]), (1...65535).contains(port),
                  let created = Int(fields[1].trimmingCharacters(in: .whitespaces))
            else { continue }
            let age = max(0, now - created)
            guard age <= PortForwardServerFiles.requestMaxAge else { continue }
            let note = fields.count > 2
                ? String(fields[2].trimmingCharacters(in: .whitespacesAndNewlines).prefix(noteLimit))
                : ""
            requests.append((created, PortForwardRequest(port: port, note: note, ageSeconds: age)))
        }
        return requests.sorted { $0.created < $1.created }.map(\.request)
    }
}

/// Texto del aviso (Mac, iPhone/iPad y, con el mismo formato, Android).
enum PortForwardRequestPrompt {
    static func message(for request: PortForwardRequest, serverName: String) -> String {
        let note = request.note.isEmpty ? "" : "«\(request.note)»\n\n"
        return note + "Se abrirá un túnel desde \(serverName) y lo verás en tu navegador en localhost. "
            + "Nada se abre si no aceptas."
    }
}

/// Vigila las solicitudes de un servidor mientras haya un proyecto suyo abierto y muestra una a
/// una (Mac e iPhone/iPad). Aceptar abre el túnel y devuelve la URL a abrir en el navegador.
@MainActor
@Observable
final class PortForwardRequestsModel {
    private let service: any SSHServicing

    /// Solicitud que se está mostrando (la más antigua pendiente).
    private(set) var current: PortForwardRequest?
    private(set) var isOpening = false
    /// Fallo al abrir el túnel; la UI lo muestra y lo borra.
    var errorMessage: String?
    /// Ya respondidas en esta sesión: no se vuelven a mostrar aunque el borrado tarde.
    private var handled: Set<Int> = []

    static let pollInterval: Duration = .seconds(5)

    init(service: any SSHServicing) {
        self.service = service
    }

    func refresh() async {
        guard !isOpening else { return }
        let pending = (try? await service.pendingPortForwardRequests()) ?? []
        // Lo respondido que ya no está en el servidor deja de importar.
        handled.formIntersection(pending.map(\.port))
        current = pending.first { !handled.contains($0.port) }
    }

    func pollWhileVisible() async {
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    /// Abre el túnel (o reutiliza el abierto), retira la solicitud y devuelve la URL local.
    func accept() async -> URL? {
        guard let request = current else { return nil }
        isOpening = true
        defer { isOpening = false }
        handled.insert(request.port)
        current = nil
        await service.dismissPortForwardRequest(port: request.port)
        if let existing = await service.activePortForwards().first(where: { $0.remotePort == request.port }) {
            return existing.localURL
        }
        do {
            let forward = try await service.startPortForward(
                remotePort: request.port, targetHost: "localhost", preferredLocalPort: request.port
            )
            return forward.localURL
        } catch {
            errorMessage = error.userMessage
            return nil
        }
    }

    /// «Ahora no»: retira la solicitud sin abrir nada.
    func decline() async {
        guard let request = current else { return }
        handled.insert(request.port)
        current = nil
        await service.dismissPortForwardRequest(port: request.port)
    }

    /// Título del aviso.
    nonisolated static func title(for request: PortForwardRequest) -> String {
        "Claude quiere mostrarte el puerto \(request.port)"
    }
}
