//
//  SessionsColumn.swift
//  Argos
//
//  Columna central: la lista de sesiones tmux del servidor seleccionado, con sus
//  estados de carga y la gestión (crear / renombrar / matar). Extraída del antiguo
//  ContentView para separarla de la gestión de servidores.
//

import SwiftUI

struct SessionsColumn: View {
    let viewModel: SessionsViewModel
    @Binding var selection: TmuxSession.ID?

    @State private var isShowingCreateSheet = false
    @State private var renameTarget: TmuxSession?
    @State private var killTarget: TmuxSession?

    var body: some View {
        content
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
                SessionNameSheet(mode: .create) { name in
                    try await viewModel.createSession(named: name)
                }
            }
            .sheet(item: $renameTarget) { session in
                SessionNameSheet(mode: .rename(current: session.name)) { newName in
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
    }

    @ViewBuilder
    private var content: some View {
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

    private var killDialogBinding: Binding<Bool> {
        Binding(get: { killTarget != nil }, set: { if !$0 { killTarget = nil } })
    }

    private var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.operationError != nil },
            set: { if !$0 { viewModel.operationError = nil } }
        )
    }
}

// MARK: - Fila de sesión

struct SessionRow: View {
    let session: TmuxSession
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
