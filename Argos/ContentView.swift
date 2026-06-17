//
//  ContentView.swift
//  Argos
//
//  Fase 2: NavigationSplitView con la lista de sesiones tmux en el sidebar y un
//  terminal en vivo (PTY sobre SSH + `tmux attach`) en el detalle.
//

import SwiftUI
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

    /// Conexión SSH compartida: la lista de sesiones y los terminales en vivo
    /// reutilizan el mismo `SSHService` (y por tanto el mismo `SSHClient`).
    let service: SSHService

    init(service: SSHService) {
        self.service = service
    }

    /// Al conectar: asegura tmux (detecta → instala si puede → configura) y LUEGO lista.
    ///
    /// Idempotente: si tmux ya está y `~/.tmux.conf` ya existe, va directo a listar.
    /// Cada fase se refleja en `state` para que la UI muestre el progreso.
    func load() async {
        do {
            try await ensureTmuxEnvironment()

            state = .loading
            let sessions = try await service.listSessions()
            state = .loaded(sessions)
        } catch is CancelBootstrap {
            // Parada limpia: `state` ya quedó en `.tmuxMissing` con su instrucción manual.
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(message)
        }
    }

    /// Garantiza que el servidor tenga tmux instalado y un `~/.tmux.conf` base.
    ///
    /// - Detecta tmux. Si falta:
    ///   - con sudo sin contraseña → lo instala con apt (estado `.installing`);
    ///   - sin sudo sin contraseña → pone `state = .tmuxMissing` (instrucción manual) y
    ///     ABORTA con `cancelBootstrap` (no es un error técnico, es una parada limpia).
    /// - Crea `~/.tmux.conf` solo si no existe (estado `.configuring`).
    private func ensureTmuxEnvironment() async throws {
        state = .verifying

        if try await !service.isTmuxInstalled() {
            guard try await service.canUseSudoNonInteractive() else {
                // Sin sudo sin contraseña: no intentamos instalar (se colgaría). Paramos.
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
    }

    /// Señal interna para detener el bootstrap sin marcar `state = .failed`
    /// (el estado ya quedó en `.tmuxMissing`, que tiene su propia UI).
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

    // MARK: - Gestión de sesiones (Fase 3)

    /// Valida el nombre, crea la sesión y refresca la lista. Lanza para que el
    /// formulario muestre el motivo (nombre inválido, duplicado, etc.).
    func createSession(named rawName: String) async throws {
        let name = try SessionNameValidator.validate(rawName)
        try await service.createSession(named: name)
        await refresh()
    }

    /// Valida el nombre, renombra la sesión y refresca. No-op si el nombre no cambia.
    /// Lanza para que el formulario muestre el motivo del fallo.
    func renameSession(_ session: TmuxSession, to rawName: String) async throws {
        let newName = try SessionNameValidator.validate(rawName)
        guard newName != session.name else { return }
        try await service.renameSession(from: session.name, to: newName)
        await refresh()
    }

    /// Mata la sesión y refresca. No tiene formulario: los errores van a
    /// `operationError` para mostrarse en una alerta.
    func kill(_ session: TmuxSession) async {
        do {
            try await service.killSession(named: session.name)
            await refresh()
        } catch {
            operationError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// Re-lista las sesiones sin repetir el bootstrap (tmux ya quedó garantizado por
    /// el primer `load()`). Se llama tras cualquier operación de gestión.
    func refresh() async {
        state = .loading
        do {
            let sessions = try await service.listSessions()
            state = .loaded(sessions)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            state = .failed(message)
        }
    }
}

// MARK: - Vista principal

struct ContentView: View {
    @State private var viewModel = SessionsViewModel(service: SSHService(configuration: .dev))
    @State private var selection: TmuxSession.ID?

    // Estado de los formularios/diálogos de gestión (Fase 3).
    @State private var isShowingCreateSheet = false
    @State private var renameTarget: TmuxSession?
    @State private var killTarget: TmuxSession?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("Sesiones tmux")
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isShowingCreateSheet = true
                        } label: {
                            Label("Nueva sesión", systemImage: "plus")
                        }
                        .help("Crear una nueva sesión tmux")
                        .disabled(viewModel.state.isBusy)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await viewModel.load() }
                        } label: {
                            Label("Refrescar", systemImage: "arrow.clockwise")
                        }
                        .help("Volver a consultar las sesiones tmux")
                        .disabled(viewModel.state.isBusy)
                    }
                }
                .sheet(isPresented: $isShowingCreateSheet) {
                    CreateSessionSheet { name in
                        try await viewModel.createSession(named: name)
                    }
                }
                .sheet(item: $renameTarget) { session in
                    RenameSessionSheet(session: session) { newName in
                        try await viewModel.renameSession(session, to: newName)
                    }
                }
                .confirmationDialog(
                    killTarget.map { "¿Matar la sesión '\($0.name)'?" } ?? "¿Matar la sesión?",
                    isPresented: killDialogBinding,
                    titleVisibility: .visible,
                    presenting: killTarget
                ) { session in
                    Button("Matar", role: .destructive) {
                        Task { await viewModel.kill(session) }
                    }
                    Button("Cancelar", role: .cancel) {}
                } message: { _ in
                    Text("Se cerrará y se perderá todo lo que corra en ella.")
                }
                .alert(
                    "No se pudo matar la sesión",
                    isPresented: operationErrorBinding,
                    presenting: viewModel.operationError
                ) { _ in
                    Button("OK", role: .cancel) {}
                } message: { message in
                    Text(message)
                }
        } detail: {
            detail
        }
        .frame(minWidth: 880, minHeight: 520)
        .task { await viewModel.load() }
    }

    // MARK: - Bindings de presentación

    /// Presenta el diálogo de confirmación de borrado mientras `killTarget` esté fijado.
    private var killDialogBinding: Binding<Bool> {
        Binding(
            get: { killTarget != nil },
            set: { if !$0 { killTarget = nil } }
        )
    }

    /// Presenta la alerta de error de operación mientras `operationError` esté fijado.
    private var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.operationError != nil },
            set: { if !$0 { viewModel.operationError = nil } }
        )
    }

    // MARK: Sidebar (lista de sesiones / estados)

    @ViewBuilder
    private var sidebar: some View {
        switch viewModel.state {
        case .idle:
            ProgressView("Conectando al servidor…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .verifying:
            ProgressView("Verificando tmux…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .installing:
            ProgressView("Instalando tmux…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .configuring:
            ProgressView("Configurando tmux…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loading:
            ProgressView("Listando sesiones…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .tmuxMissing:
            ContentUnavailableView {
                Label("tmux no está instalado", systemImage: "shippingbox")
            } description: {
                Text(SSHService.manualInstallInstruction)
            } actions: {
                Button("Reintentar") { Task { await viewModel.load() } }
                    .buttonStyle(.borderedProminent)
            }

        case .failed(let message):
            ErrorStateView(message: message) {
                Task { await viewModel.load() }
            }

        case .loaded(let sessions) where sessions.isEmpty:
            EmptyStateView()

        case .loaded(let sessions):
            List(selection: $selection) {
                ForEach(SessionGrouping.groups(from: sessions)) { group in
                    Section(group.name) {
                        ForEach(group.sessions) { session in
                            SessionRow(
                                session: session,
                                displayName: SessionGrouping.shortName(for: session.name)
                            )
                            .tag(session.id)
                            .contextMenu {
                                Button("Renombrar…") { renameTarget = session }
                                Button("Matar…", role: .destructive) { killTarget = session }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Detalle (terminal en vivo / placeholder)

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let session = viewModel.session(withID: id) {
            SessionTerminalView(session: session, service: viewModel.service)
                .id(session.id)
        } else {
            ContentUnavailableView(
                "Selecciona una sesión",
                systemImage: "terminal",
                description: Text("Elige una sesión de la lista para abrir su terminal en vivo.")
            )
        }
    }
}

// MARK: - Fila de sesión

struct SessionRow: View {
    let session: TmuxSession
    /// Nombre a mostrar (el corto dentro de un grupo). Si es `nil`, se usa el completo.
    /// La identidad/target real sigue siendo siempre `session.name`.
    var displayName: String? = nil

    private var title: String { displayName ?? session.name }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            attachedBadge
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        let windows = "\(session.windowCount) \(session.windowCount == 1 ? "ventana" : "ventanas")"
        let created = session.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "\(windows) · creada \(created)"
    }

    private var attachedBadge: some View {
        Label(
            session.isAttached ? "Activa" : "Inactiva",
            systemImage: session.isAttached ? "circle.fill" : "circle"
        )
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.medium))
        .foregroundStyle(session.isAttached ? Color.green : Color.secondary)
    }
}

// MARK: - Estados vacíos / error

struct EmptyStateView: View {
    var body: some View {
        ContentUnavailableView(
            "Sin sesiones",
            systemImage: "moon.zzz",
            description: Text("No hay sesiones tmux activas en el servidor.")
        )
    }
}

struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No se pudo conectar", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Reintentar", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Previews (datos de muestra, sin conexión real)

#if DEBUG
extension TmuxSession {
    static let samples: [TmuxSession] = [
        TmuxSession(name: "main",    windowCount: 3, isAttached: true,  createdAt: .now.addingTimeInterval(-3600)),
        TmuxSession(name: "deploy",  windowCount: 1, isAttached: false, createdAt: .now.addingTimeInterval(-86_400)),
        TmuxSession(name: "logs",    windowCount: 5, isAttached: false, createdAt: .now.addingTimeInterval(-120))
    ]
}

#Preview("Lista") {
    List(TmuxSession.samples) { SessionRow(session: $0) }
        .frame(width: 320, height: 320)
}

#Preview("Fila") {
    SessionRow(session: TmuxSession.samples[0])
        .padding()
}

#Preview("Vacío") {
    EmptyStateView()
        .frame(width: 520, height: 320)
}

#Preview("Error") {
    ErrorStateView(message: "No se pudo conectar a 100.86.237.26:2222.") {}
        .frame(width: 520, height: 320)
}
#endif
