//
//  SessionsViewModel.swift
//  Argos
//
//  Estado de carga y ViewModel de la lista de sesiones tmux de UN servidor.
//  Recibe `any SSHServicing` (no el tipo concreto) para ser testeable con un mock.
//

import Foundation
import Observation

// MARK: - Estado de carga

enum SessionsLoadState {
    case idle
    case verifying      // comprobando si tmux está instalado
    case installing     // instalando tmux vía apt
    case configuring    // creando ~/.tmux.conf
    case loading        // listando sesiones
    case tmuxMissing    // tmux ausente y sin sudo sin contraseña -> instrucción manual
    case loaded([TmuxSession])
    case hostKeyChanged(String) // la host key cambió (posible MitM) -> acción dedicada
    case failed(String)

    /// La toolbar se deshabilita mientras hay una operación de red en curso.
    var isBusy: Bool {
        switch self {
        case .verifying, .installing, .configuring, .loading: return true
        default: return false
        }
    }
}

// MARK: - View Model

@MainActor
@Observable
final class SessionsViewModel {
    private(set) var state: SessionsLoadState = .idle

    /// Error de una operación que no tiene formulario propio (matar), para mostrarlo
    /// en una alerta sin perder la lista. Las operaciones con sheet (crear/renombrar)
    /// reportan sus errores dentro del propio formulario.
    var operationError: String?

    /// Servicio SSH del servidor activo (abstraído para poder inyectar un mock).
    let service: any SSHServicing

    init(service: any SSHServicing) {
        self.service = service
    }

    /// Al conectar: asegura tmux (detecta → instala si puede → configura) y LUEGO lista.
    func load() async {
        do {
            try await ensureTmuxEnvironment()

            state = .loading
            let sessions = try await service.listSessions()
            state = .loaded(sessions)
        } catch is CancelBootstrap {
            // Parada limpia: `state` ya quedó en `.tmuxMissing` con su instrucción manual.
        } catch let mismatch as HostKeyMismatchError {
            // La huella del servidor cambió: NO es un error de red genérico, es un caso
            // de seguridad con una acción concreta ("Olvidar host key y reintentar").
            state = .hostKeyChanged(mismatch.userMessage)
        } catch {
            state = .failed(error.userMessage)
        }
    }

    /// Garantiza que el servidor tenga tmux instalado y un `~/.tmux.conf` base.
    private func ensureTmuxEnvironment() async throws {
        state = .verifying

        if try await !service.isTmuxInstalled() {
            guard try await service.canUseSudoNonInteractive() else {
                state = .tmuxMissing
                throw CancelBootstrap()
            }
            state = .installing
            try await service.installTmuxWithApt()
        }

        if try await !service.tmuxConfigExists() {
            state = .configuring
            try await service.writeDefaultTmuxConfig()
        }

        // Habilita OSC 52 en el servidor en ejecución (best-effort) para que la copia
        // al portapapeles funcione incluso en servidores con config previa.
        await service.enableClipboardForwarding()
    }

    /// Señal interna para detener el bootstrap sin marcar `state = .failed`.
    private struct CancelBootstrap: Error {}

    /// Sesiones actualmente cargadas (vacío en cualquier otro estado).
    var sessions: [TmuxSession] {
        if case .loaded(let sessions) = state { return sessions }
        return []
    }

    /// Busca una sesión cargada por su identificador (nombre).
    func session(withID id: TmuxSession.ID) -> TmuxSession? {
        sessions.first { $0.id == id }
    }

    // MARK: - Gestión de sesiones

    func createSession(named rawName: String) async throws {
        let name = try SessionNameValidator.validate(rawName)
        try await service.createSession(named: name)
        await refresh()
    }

    func renameSession(_ session: TmuxSession, to rawName: String) async throws {
        let newName = try SessionNameValidator.validate(rawName)
        guard newName != session.name else { return }
        try await service.renameSession(from: session.name, to: newName)
        await refresh()
    }

    func kill(_ session: TmuxSession) async {
        do {
            try await service.killSession(named: session.name)
            await refresh()
        } catch {
            operationError = error.userMessage
        }
    }

    /// Re-lista las sesiones sin repetir el bootstrap.
    func refresh() async {
        state = .loading
        do {
            let sessions = try await service.listSessions()
            state = .loaded(sessions)
        } catch {
            state = .failed(error.userMessage)
        }
    }
}
