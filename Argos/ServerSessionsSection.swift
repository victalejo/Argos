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
    var statusFilter: ProjectStatusFilter = .all
    @Binding var renameTarget: SessionAction?
    @Binding var killTarget: SessionAction?
    @Binding var projectForm: ProjectFormRequest?
    @Binding var projectConfirmation: ProjectConfirmation?
    @Binding var importServer: Server?
    @Binding var projectSync: ProjectSyncRequest?
    let onBroadcast: (SessionHandle) -> Void

    @State private var collapsedGroups = CollapsedSessionGroups.shared
    @State private var projectSettings = ProjectSettings.shared
    @State private var syncCenter = ProjectSyncCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sshGrantError: String?

    var body: some View {
        switch vm.state {
        case .idle:
            // Arranque perezoso: este servidor aún no se ha cargado (no es el seleccionado).
            // Ofrecemos conectar bajo demanda en vez de mostrar un spinner engañoso.
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 9) {
                    Image(systemName: "network")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Listo para conectar")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Carga los proyectos de este servidor.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task { await vm.load() }
                } label: {
                    Label("Conectar servidor", systemImage: "bolt.horizontal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
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
            .padding(12)
            .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .selectionDisabled()

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
            .padding(12)
            .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .selectionDisabled()

        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label("No se pudo conectar", systemImage: "wifi.exclamationmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                #if APPSTORE
                if SSHDirectoryAccess.needsGrant(for: server, hasGrant: SSHDirectoryAccess.hasGrant()) {
                    Button(action: grantSSHDirectoryAndReconnect) {
                        Label("Conceder acceso a ~/.ssh…", systemImage: "key")
                    }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                if let sshGrantError {
                    Text(sshGrantError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                #endif
                Button {
                    Task { await vm.load() }
                } label: {
                    Label("Reintentar conexión", systemImage: "arrow.clockwise")
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .selectionDisabled()

        case .loaded:
            projectList
        }
    }

    #if APPSTORE
    /// Pide la carpeta ~/.ssh y, si se concede, reconecta sin más pasos.
    private func grantSSHDirectoryAndReconnect() {
        sshGrantError = nil
        switch SSHDirectoryGrant.request() {
        case .granted:
            Task { await vm.load() }
        case .cancelled:
            break
        case .failed(let message):
            sshGrantError = message
        }
    }
    #endif

    // MARK: - Proyectos

    /// Nombre del grupo de las sesiones que no pertenecen a ningún proyecto.
    private static let looseGroupName = "Sesiones sueltas"

    @ViewBuilder
    private var projectList: some View {
        let listing = vm.projectListing
        let entries = Self.matching(listing.entries, filter: filter).filter {
            statusFilter.includes(terminalStore.status(of: $0, serverID: server.id))
        }
        let loose = Self.matching(listing.looseSessions, filter: filter).filter {
            statusFilter.includes(terminalStore.status(of: $0, serverID: server.id))
        }
        // Con búsqueda o filtro de estado, los grupos se muestran desplegados.
        let isFiltering = !filter.isEmpty || statusFilter != .all
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
            VStack(alignment: .leading, spacing: 11) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Color.accentColor)
                Text("Tu próximo proyecto empieza aquí")
                    .font(.system(size: 12, weight: .semibold))
                Text("Organiza una carpeta del servidor y vuelve a ella con un clic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Crear primer proyecto") { projectForm = .new(server) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .selectionDisabled()
        } else if entries.isEmpty && loose.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("Sin coincidencias", systemImage: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                Text(statusFilter == .all
                     ? "Prueba con otro nombre o carpeta."
                     : "Ningún proyecto «\(statusFilter.title.lowercased())» aquí.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .selectionDisabled()
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
            let isCollapsed = showHeaders && !isFiltering
                && collapsedGroups.isCollapsed(serverID: server.id, group: group.name)
            ForEach(isCollapsed ? [] : group.entries) { entry in
                projectRow(entry)
            }
        }

        if !loose.isEmpty {
            groupHeader(name: Self.looseGroupName, count: loose.count, sessionNames: loose.map(\.name))
            let isCollapsed = !isFiltering
                && collapsedGroups.isCollapsed(serverID: server.id, group: Self.looseGroupName)
            ForEach(isCollapsed ? [] : loose) { session in
                sessionRow(session, displayName: nil)
            }
        }
    }

    private func importBanner(count: Int) -> some View {
        Button { importServer = server } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(count) \(count == 1 ? "sesión sin organizar" : "sesiones sin organizar")")
                        .font(.system(size: 11, weight: .medium))
                    Text("Convertir en proyectos")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(10)
            .background(Color.accentColor.opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
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
            claude: vm.claudeActivity.activity(forSession: project.sessionName),
            git: vm.gitSummary(for: project),
            sync: syncCenter.job(forProject: project.id),
            onOpenSync: { reopenSync(for: project) }
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
            if let job = syncCenter.job(forProject: project.id), job.isRunning {
                Button(job.isToMac ? "Ver envío al Mac en curso…" : "Ver envío al servidor en curso…") {
                    projectSync = job.request
                }
            } else if let checkout = project.macCheckout {
                if checkout.macID == MacSyncStore.macID {
                    Button("Enviar al servidor…") { projectSync = .toServer(server, project) }
                    if let manifest = MacSyncStore.manifest(for: project.id),
                       let folder = MacSyncStore.localFolder(of: manifest) {
                        Button("Abrir en Terminal con Claude Code") {
                            Task { _ = await LocalTerminalLauncher.openWithClaude(folder, remoteRoot: manifest.remoteRoot) }
                        }
                        Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                } else {
                    Text("Está en el Mac «\(checkout.macName)»")
                }
            } else {
                Button("Enviar al Mac…") { projectSync = .toMac(server, project) }
            }
            Divider()
            Button("Ramas en paralelo…") { projectForm = .worktrees(server, project) }
                .help("Abre otra rama del repositorio en su propia carpeta (git worktree) con su agente")
            Button("Editar proyecto…") { projectForm = .edit(server, project) }
            Button("Quitar proyecto…", role: .destructive) { projectConfirmation = .remove(server, project) }
        }
    }

    /// Reabre la hoja del envío del proyecto (en curso o ya terminado).
    private func reopenSync(for project: Project) {
        if let job = syncCenter.job(forProject: project.id) { projectSync = job.request }
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
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                collapsedGroups.toggle(serverID: server.id, group: group.name)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Text(group.name)
                    .lineLimit(1)
                Text("\(group.count)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.09), in: Capsule())
                Spacer()
                if isCollapsed, let claude {
                    ClaudeActivityBadge(activity: claude, size: 10)
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .padding(.bottom, 3)
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
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                Text("Preparando tu espacio de trabajo")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .selectionDisabled()
    }
}
