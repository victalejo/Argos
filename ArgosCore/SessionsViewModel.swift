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
    /// Es una acción explícita: levanta el bloqueo por credenciales y la espera de red.
    func load() async {
        await service.resetConnectionHealth()
        do {
            try await ensureTmuxEnvironment()

            state = .loading
            let sessions = try await service.listSessions()
            await reloadProjects()
            state = .loaded(sessions)
        } catch is CancelBootstrap {
            // Parada limpia: `state` ya quedó en `.tmuxMissing` con su instrucción manual.
        } catch let mismatch as HostKeyMismatchError {
            // La huella del servidor cambió: NO es un error de red genérico, es un caso
            // de seguridad con una acción concreta ("Olvidar host key y reintentar").
            state = .hostKeyChanged(mismatch.userMessage)
        } catch let unreadable as HostKeyStoreUnreadableError {
            // Misma salida: «Olvidar host key y reintentar» empieza un registro nuevo.
            state = .hostKeyChanged(unreadable.userMessage)
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

    // MARK: - Estado de Claude Code

    /// Estado de Claude Code por sesión/ventana (vía hooks -> `@argos_claude` en tmux).
    private(set) var claudeActivity = ClaudeActivitySnapshot.empty

    /// Relee el estado de Claude y devuelve las sesiones que acaban de pasar a
    /// "esperando" o "terminó" (para notificar). El primer sondeo no notifica nada:
    /// no sabemos si esos estados son nuevos. Fallos de red: se conserva lo último.
    func refreshClaudeActivity() async -> [ClaudeTransition] {
        guard case .loaded = state else { return [] }
        let fresh: ClaudeActivitySnapshot
        do {
            fresh = try await ConnectionPriority.background { try await service.claudeActivity() }
        } catch {
            noteBackgroundFailure(error, during: "leer el estado de Claude")
            return []
        }
        return await absorbClaudeActivity(fresh)
    }

    /// Toma un estado de Claude recién leído (sondeo suelto o agrupado) y devuelve las
    /// transiciones que merecen aviso. El primero no avisa y actualiza los hooks.
    func absorbClaudeActivity(_ fresh: ClaudeActivitySnapshot) async -> [ClaudeTransition] {
        guard case .loaded = state else { return [] }
        let isFirstPoll = !hasPolledClaude
        hasPolledClaude = true
        if isFirstPoll { await upgradeClaudeHooks() }
        guard fresh != claudeActivity else { return [] }
        let transitions = isFirstPoll ? [] : fresh.notableTransitions(since: claudeActivity)
        claudeActivity = fresh
        return transitions
    }

    private var hasPolledClaude = false

    /// Toma `snapshot` como lo último conocido SIN avisar: lo que ya se notificó por otra
    /// vía (la comprobación en segundo plano del iPhone) no debe avisarse otra vez al volver.
    func adoptClaudeActivityBaseline(_ snapshot: ClaudeActivitySnapshot) {
        // Sin sondeo previo no hace falta: el primero nunca avisa (y además actualiza los hooks).
        guard hasPolledClaude else { return }
        claudeActivity = snapshot
    }

    /// Una vez por arranque: si el indicador se activó con hooks de una versión
    /// anterior, se actualizan (los de ahora cubren más casos). Fallar no es grave.
    private func upgradeClaudeHooks() async {
        do {
            if try await ConnectionPriority.background({ try await service.upgradeClaudeHooksIfOutdated() }) {
                Log.ssh.notice("Hooks de Claude actualizados en el servidor")
            }
        } catch {
            Log.ssh.error("Actualizar hooks de Claude: \(error.userMessage, privacy: .public)")
        }
    }

    // MARK: - Proyectos (ver SessionsViewModel+Projects.swift)

    /// Proyectos del servidor (`~/.config/argos/projects.json`).
    var projects: [Project] = []
    /// Error al leer/guardar proyectos (no impide listar sesiones).
    var projectsError: String?

    // MARK: - Resumen git (ver Git/SessionsViewModel+Git.swift)

    /// Resumen git por carpeta de proyecto.
    var gitSummaries: [String: GitRepoSummary] = [:]
    /// Última lectura de `gitSummaries` (para espaciarlas).
    var lastGitSummaryRefresh: Date?
    /// Commits cuyo CI se espera para avisar al terminar (`SessionsViewModel+CI`).
    var ciWatcher = CIWatcher()

    /// Hay un refresco en curso que conserva la lista visible.
    private(set) var isRefreshing = false

    /// Operación de red en curso, se vea o no la lista (para deshabilitar controles).
    var isWorking: Bool { state.isBusy || isRefreshing }

    /// Re-lista las sesiones sin repetir el bootstrap.
    ///
    /// Con la lista ya cargada NO pasa por `.loading`: vaciarla un instante hacía
    /// parpadear la columna y desmontaba el terminal abierto (que perdía sus ventanas y
    /// contadores) cada vez que se creaba, renombraba o mataba cualquier sesión.
    func refresh() async {
        await service.resetConnectionHealth()
        if case .loaded = state { isRefreshing = true } else { state = .loading }
        defer { isRefreshing = false }
        do {
            let sessions = try await service.listSessions()
            await reloadProjects()
            state = .loaded(sessions)
        } catch {
            state = .failed(error.userMessage)
        }
    }

    /// Sondeo: recoge lo que cambió fuera de esta app (una sesión creada o cerrada desde
    /// otro dispositivo, `exit` en la última shell). Solo con la lista cargada; un fallo de
    /// red conserva lo último, que ya lo detecta la operación que lo necesite.
    func refreshSessionsQuietly() async {
        guard case .loaded(let current) = state, !isRefreshing else { return }
        let fresh: [TmuxSession]
        do {
            fresh = try await ConnectionPriority.background { try await service.listSessions() }
        } catch {
            noteBackgroundFailure(error, during: "releer las sesiones")
            return
        }
        adoptQuietSessions(fresh, readOver: current)
    }

    /// Pone `fresh` (leída en segundo plano sobre `current`) salvo que entretanto un
    /// refresco explícito haya cambiado la lista: manda ese.
    func adoptQuietSessions(_ fresh: [TmuxSession], readOver current: [TmuxSession]) {
        guard case .loaded(let now) = state, now == current, !isRefreshing, fresh != current else { return }
        state = .loaded(fresh)
    }

    /// `projects.json` está dañado (no es JSON): se puede ofrecer restaurar su copia.
    var isProjectsFileDamaged: Bool {
        projectsError != nil && projectsError == ProjectError.invalidFile.errorDescription
    }

    // MARK: - Fallos de los sondeos de fondo

    /// Un sondeo de fondo falló. Un fallo de red conserva lo último (lo detecta la
    /// operación que lo necesite y la conexión espera antes de reintentar). Contraseña o
    /// clave rechazada y host key cambiada NO se arreglan solos: se muestran en vez de
    /// seguir «cargado», y no se reintenta hasta que el usuario actúe (`load()`).
    /// Para los sondeos de las extensiones (git, CI…).
    func noteBackgroundFailure(_ error: Error, during task: String) {
        let message = error.userMessage
        guard let blocking = SSHFailureKind.blocking(error) else {
            if error is SSHConnectionError {
                Log.ssh.debug("Sondeo en pausa (\(task, privacy: .public)): \(message, privacy: .public)")
            } else if !(error is CancellationError) {
                Log.ssh.notice("Sondeo fallido (\(task, privacy: .public)): \(message, privacy: .public)")
            }
            return
        }
        Log.ssh.error("Sondeo fallido (\(task, privacy: .public)): \(message, privacy: .public)")
        // Solo con la lista a la vista: no se pisa un arranque en curso ni otro error.
        guard case .loaded = state, !isRefreshing else { return }
        switch blocking {
        case .hostKey: state = .hostKeyChanged(message)
        case .authentication, .network: state = .failed(message)
        }
    }
}
