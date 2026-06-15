//
//  ContentView.swift
//  Argos
//
//  Fase 1: lista las sesiones tmux del servidor remoto vía SSH, con estados
//  claros (cargando / error+reintentar / vacío / lista) y refresco en la toolbar.
//

import SwiftUI
import Observation

// MARK: - Estado de carga

enum SessionsLoadState {
    case idle
    case loading
    case installing
    case tmuxMissing
    case loaded([TmuxSession])
    case failed(String)

    /// La toolbar se deshabilita mientras hay una operación de red en curso.
    var isBusy: Bool {
        switch self {
        case .loading, .installing: return true
        default: return false
        }
    }
}

// MARK: - View Model

@MainActor
@Observable
final class SessionsViewModel {
    private(set) var state: SessionsLoadState = .idle
    private let service: SSHService

    init(service: SSHService) {
        self.service = service
    }

    func load() async {
        state = .loading
        do {
            let sessions = try await service.listSessions()
            state = .loaded(sessions)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(message)
        }
    }
}

// MARK: - Vista principal

struct ContentView: View {
    @State private var viewModel = SessionsViewModel(service: SSHService(configuration: .dev))

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Sesiones tmux")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await viewModel.load() }
                        } label: {
                            Label("Refrescar", systemImage: "arrow.clockwise")
                        }
                        .help("Volver a consultar las sesiones tmux")
                        .disabled(viewModel.state.isLoading)
                    }
                }
        }
        .frame(minWidth: 520, minHeight: 380)
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView("Conectando al servidor…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ErrorStateView(message: message) {
                Task { await viewModel.load() }
            }

        case .loaded(let sessions) where sessions.isEmpty:
            EmptyStateView()

        case .loaded(let sessions):
            List(sessions) { session in
                SessionRow(session: session)
            }
        }
    }
}

// MARK: - Fila de sesión

struct SessionRow: View {
    let session: TmuxSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
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
        .frame(width: 520, height: 320)
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
