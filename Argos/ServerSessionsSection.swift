//
//  ServerSessionsSection.swift
//  Argos
//
//  Contenido de la sección de UN servidor en la columna central: estado de conexión /
//  bootstrap de tmux y, una vez cargado, sus proyectos por grupo (colapsables) y las
//  sesiones sueltas, con sus menús contextuales.
//

import AppKit
import SwiftUI

// MARK: - Sección de sesiones de un servidor

struct ServerSessionsSection: View {
    let server: Server
    let vm: SessionsViewModel
    let terminalStore: TerminalSessionStore
    let filter: String
    @Binding var renameTarget: SessionAction?
    @Binding var killTarget: SessionAction?
    @Binding var projectForm: ProjectFormRequest?
    @Binding var projectConfirmation: ProjectConfirmation?
    @Binding var importServer: Server?
    let onBroadcast: (SessionHandle) -> Void

    @State private var collapsedGroups = CollapsedSessionGroups.shared
    @State private var projectSettings = ProjectSettings.shared

    var body: some View {
        switch vm.state {
        case .idle:
            // Arranque perezoso: este servidor aún no se ha cargado (no es el seleccionado).
            // Ofrecemos conectar bajo demanda en vez de mostrar un spinner engañoso.
            Button {
                Task { await vm.load() }
            } label: {
                Label("Sin cargar — pulsa para conectar", systemImage: "powerplug")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .selectionDisabled()
        case .verifying:
            loadingRow("Verificando tmux…")
        case .installing:
            loadingRow("Instalando tmux…")
        case .configuring:
            loadingRow("Configurando tmux…")
        case .loading:
            loadingRow("Listando sesiones…")

        case .tmuxMissing:
            VStack(alignment: .leading, spacing: 6) {
                Label("tmux no está instalado", systemImage: "shippingbox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(Self.installCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        Self.copyToClipboard(Self.installCommand)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copiar el comando de instalación")
                    Spacer()
                    Button("Reintentar") { Task { await vm.load() } }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 2)

        case .hostKeyChanged(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("La identidad del servidor cambió", systemImage: "exclamationmark.shield.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    // Resuelve el caso legítimo (reinstalación del servidor): olvida la
                    // huella ANCLADA y reintenta, re-confiando en la nueva. La acción vive
                    // aquí (junto al error) en vez de en el menú contextual de otra columna.
                    Button("Olvidar host key y reintentar") {
                        TOFUHostKeyValidator.forget(host: server.host, port: server.port)
                        Task { await vm.load() }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    Spacer()
                }
            }
            .padding(.vertical, 2)

        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Reintentar") { Task { await vm.load() } }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }

        case .loaded:
            projectList
        }
    }

    // MARK: - Proyectos

    /// Nombre del grupo de las sesiones que no pertenecen a ningún proyecto.
    private static let looseGroupName = "Sesiones sueltas"

    @ViewBuilder
    private var projectList: some View {
        let listing = vm.projectListing
        let entries = Self.matching(listing.entries, filter: filter)
        let loose = Self.matching(listing.looseSessions, filter: filter)
        let groups = ProjectListing.groups(entries)
        // Sin grupos reales ni sueltas, los encabezados solo añadirían ruido.
        let showHeaders = groups.count > 1 || !loose.isEmpty
            || (groups.first.map { $0.name != SessionGrouping.ungroupedName } ?? false)

        if let error = vm.projectsError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
                .selectionDisabled()
        }

        if listing.entries.isEmpty && listing.looseSessions.isEmpty {
            Button { projectForm = .new(server) } label: {
                Label("Sin proyectos — crear uno", systemImage: "folder.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .selectionDisabled()
        } else if entries.isEmpty && loose.isEmpty {
            Label("Sin coincidencias", systemImage: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if filter.isEmpty && !listing.looseSessions.isEmpty {
            importBanner(count: listing.looseSessions.count)
        }

        ForEach(groups) { group in
            if showHeaders {
                groupHeader(
                    name: group.name,
                    count: group.entries.count,
                    sessionNames: group.entries.map(\.project.sessionName)
                )
            }
            let isCollapsed = showHeaders && filter.isEmpty
                && collapsedGroups.isCollapsed(serverID: server.id, group: group.name)
            ForEach(isCollapsed ? [] : group.entries) { entry in
                projectRow(entry)
            }
        }

        if !loose.isEmpty {
            groupHeader(name: Self.looseGroupName, count: loose.count, sessionNames: loose.map(\.name))
            let isCollapsed = filter.isEmpty
                && collapsedGroups.isCollapsed(serverID: server.id, group: Self.looseGroupName)
            ForEach(isCollapsed ? [] : loose) { session in
                sessionRow(session, displayName: nil)
            }
        }
    }

    private func importBanner(count: Int) -> some View {
        Button { importServer = server } label: {
            Label(
                "Importar \(count) \(count == 1 ? "sesión suelta" : "sesiones sueltas") como proyectos…",
                systemImage: "square.and.arrow.down.on.square"
            )
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .selectionDisabled()
        .help("Guarda cada sesión como proyecto anclado a su carpeta actual")
    }

    @ViewBuilder
    private func projectRow(_ entry: ProjectEntry) -> some View {
        let project = entry.project
        let handle = SessionHandle(serverID: server.id, sessionID: project.sessionName)
        let connection = entry.session.map {
            terminalStore.connectionState(for: handle, isAttached: $0.isAttached)
        }
        ProjectRow(
            entry: entry,
            connection: connection,
            claude: vm.claudeActivity.activity(forSession: project.sessionName)
        )
        .tag(handle)
        .contextMenu {
            if entry.isRunning {
                if connection == .live || connection == .connecting || connection == .error {
                    Button("Desconectar (sigue corriendo)") { terminalStore.close(handle) }
                }
                Button("Enviar comando…") { onBroadcast(handle) }
                Button("Detener…") { projectConfirmation = .stop(server, project) }
            } else {
                Button("Abrir") { open(project) }
            }
            Divider()
            Button("Editar proyecto…") { projectForm = .edit(server, project) }
            Button("Quitar proyecto…", role: .destructive) { projectConfirmation = .remove(server, project) }
        }
    }

    private func open(_ project: Project) {
        Task {
            do {
                try await vm.openProject(project, defaultStartupCommand: projectSettings.defaultStartupCommand)
            } catch {
                vm.operationError = error.userMessage
            }
        }
    }

    /// Encabezado de un grupo de sesiones: clic para colapsar/expandir. Colapsado
    /// muestra cuántas sesiones oculta y el aviso de Claude más urgente del grupo.
    /// No es seleccionable (no es una sesión).
    @ViewBuilder
    private func groupHeader(name: String, count: Int, sessionNames: [String]) -> some View {
        let group = (name: name, count: count)
        let isCollapsed = collapsedGroups.isCollapsed(serverID: server.id, group: name)
        let claude = vm.claudeActivity.activity(forSessions: sessionNames)
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                collapsedGroups.toggle(serverID: server.id, group: group.name)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Text(group.name)
                    .textCase(.uppercase)
                if isCollapsed {
                    Text("\(group.count)")
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                    if let claude {
                        ClaudeActivityBadge(activity: claude, size: 10)
                    }
                }
                Spacer()
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .selectionDisabled()
        .help(isCollapsed ? "Expandir el grupo \(group.name)" : "Colapsar el grupo \(group.name)")
        .accessibilityLabel("Grupo \(group.name), \(group.count) elementos")
        .accessibilityValue(isCollapsed ? "colapsado" : "expandido")
    }

    /// Una fila de sesión con su menú contextual. `displayName` muestra el nombre corto
    /// dentro de un grupo (el id real sigue siendo el nombre completo).
    @ViewBuilder
    private func sessionRow(_ session: TmuxSession, displayName: String?) -> some View {
        let handle = SessionHandle(serverID: server.id, sessionID: session.id)
        let state = terminalStore.connectionState(for: handle, isAttached: session.isAttached)
        SessionRow(
            session: session,
            state: state,
            displayName: displayName,
            claude: vm.claudeActivity.activity(forSession: session.name)
        )
            .tag(handle)
            .contextMenu {
                if state == .live || state == .connecting || state == .error {
                    Button("Desconectar (dormir)") {
                        terminalStore.close(handle)
                    }
                    Divider()
                }
                Button("Convertir en proyecto…") { projectForm = .convert(server, session) }
                Divider()
                Button("Enviar comando…") { onBroadcast(handle) }
                Button("Renombrar…") {
                    renameTarget = SessionAction(server: server, session: session)
                }
                Button("Matar…", role: .destructive) {
                    killTarget = SessionAction(server: server, session: session)
                }
            }
    }

    /// Comando manual de instalación de tmux (Debian/Ubuntu; el bootstrap usa apt).
    private static let installCommand = "sudo apt install -y tmux"

    private static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Filtra proyectos por nombre, grupo o carpeta (case/diacritic-insensitive).
    private static func matching(_ entries: [ProjectEntry], filter: String) -> [ProjectEntry] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            [entry.project.sessionName, entry.project.path].contains {
                $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// Filtra por subcadena (case/diacritic-insensitive). Filtro vacío = todas.
    private static func matching(_ sessions: [TmuxSession], filter: String) -> [TmuxSession] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sessions }
        return sessions.filter {
            $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    @ViewBuilder
    private func loadingRow(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
