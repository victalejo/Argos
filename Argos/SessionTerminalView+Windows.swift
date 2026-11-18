//
//  SessionTerminalView+Windows.swift
//  Argos
//
//  Menú «Panel», confirmaciones de ventanas y paneles, atajos de pestaña (⌘T/⌘W/⌘1…)
//  y la cabecera del terminal (agentes instalados, carpeta y rama git).
//

import SwiftUI

extension SessionTerminalView {

    /// Menú "Panel" en la toolbar del detalle: divide, navega, hace zoom o cierra el
    /// panel activo de tmux sin teclear el prefijo. Deshabilitado mientras no hay conexión.
    @ToolbarContentBuilder
    var paneToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { run { await $0.splitPane(vertical: false) } } label: {
                    Label("Dividir a la derecha", systemImage: "rectangle.split.2x1")
                }
                Button { run { await $0.splitPane(vertical: true) } } label: {
                    Label("Dividir abajo", systemImage: "rectangle.split.1x2")
                }
                Divider()
                Button { run { await $0.selectPane(.left) } } label: { Label("Panel a la izquierda", systemImage: "arrow.left") }
                Button { run { await $0.selectPane(.right) } } label: { Label("Panel a la derecha", systemImage: "arrow.right") }
                Button { run { await $0.selectPane(.up) } } label: { Label("Panel de arriba", systemImage: "arrow.up") }
                Button { run { await $0.selectPane(.down) } } label: { Label("Panel de abajo", systemImage: "arrow.down") }
                Divider()
                Button { run { await $0.zoomPane() } } label: {
                    Label("Zoom del panel", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Button(role: .destructive) { showKillPaneConfirm = true } label: {
                    Label("Cerrar panel", systemImage: "xmark.rectangle")
                }
                .disabled(!windowsModel.activeWindowHasMultiplePanes)
            } label: {
                Label("Panel", systemImage: "rectangle.split.2x2")
            }
            .menuIndicator(.hidden)
            .disabled(!isConnected)
            .help("Acciones de panel de tmux (dividir, navegar, zoom, cerrar)")
        }
    }

    /// Renombrar ventana y confirmaciones de cerrar panel o ventana.
    var windowDialogs: TerminalWindowDialogs {
        TerminalWindowDialogs(
            sessionName: session.name,
            service: service,
            windowsModel: windowsModel,
            renamingWindow: $renamingWindow,
            closingWindow: $closingWindow,
            showKillPaneConfirm: $showKillPaneConfirm
        )
    }

    /// Cerrar con ⌘W (`index == nil`: la ventana activa) o la «×»: directo si solo hay
    /// un shell ocioso, con confirmación si corre algo y nunca la última ventana (mataría
    /// la sesión). Decide con una lista RECIÉN leída de tmux, no con la del sondeo (que
    /// puede tener segundos): si no, se podría matar sin preguntar algo recién lanzado.
    func requestClose(index: Int?) {
        let model = windowsModel
        Task {
            guard let fresh = await model.freshWindows() else { return }
            let target = index.map { wanted in fresh.first { $0.index == wanted } } ?? fresh.first { $0.isActive }
            guard let target else { return }
            switch WindowTabs.closeDecision(for: target, totalWindows: fresh.count) {
            case .blocked: NSSound.beep()
            case .immediate: await model.close(target)
            case .confirm: closingWindow = target
            }
        }
    }

    /// Acciones que esta vista publica para los atajos de la barra de menús.
    var tabActions: TabActions? {
        guard isConnected else { return nil }
        let windows = self.windows
        return TabActions(
            identity: TabIdentity(handle: handle, windows: windows, claude: claudeByWindow, installedAgents: installedAgents),
            newTitle: "Nueva ventana",
            closeTitle: "Cerrar ventana",
            newTab: { run { await $0.newWindow() } },
            closeTab: { requestClose(index: nil) },
            selectTab: { number in
                if let target = WindowTabs.window(atShortcut: number, in: windows) { run { await $0.select(target) } }
            },
            selectAdjacent: { offset in
                if let target = WindowTabs.adjacent(to: windows, offset: offset) { run { await $0.select(target) } }
            },
            newAgent: { newAgentWindow($0) },
            installedAgents: installedAgents
        )
    }

    /// Detecta los agentes instalados (con caché por servidor para pintar el menú al
    /// instante) y la carpeta/rama git que se muestran en la tarjeta y la barra.
    func loadAgentsAndBranch() async {
        installedAgents = InstalledAgentsCache.agents[handle.serverID]
        do {
            let fresh = try await service.installedCodingAgents()
            InstalledAgentsCache.agents[handle.serverID] = fresh
            installedAgents = fresh
        } catch {
            Log.terminal.notice("No se pudo detectar qué agentes hay instalados: \(error.userMessage, privacy: .public)")
        }
        if let projectPath {
            workingPath = projectPath
        } else {
            do {
                workingPath = try await service.sessionFirstPanePaths()[session.name]
            } catch {
                Log.terminal.notice("No se pudo leer la carpeta de la sesión: \(error.userMessage, privacy: .public)")
            }
        }
        await refreshBranch()
    }

    /// Relee la rama git (también cuando cambian las ventanas: tras un `checkout`).
    func refreshBranch() async {
        guard let workingPath else { return }
        do {
            gitBranch = try await ConnectionPriority.background { try await service.gitBranch(at: workingPath) }
        } catch {
            Log.terminal.notice("No se pudo leer la rama git: \(error.userMessage, privacy: .public)")
        }
    }
}

/// Renombrar ventana y confirmaciones de cerrar panel o ventana.
struct TerminalWindowDialogs: ViewModifier {
    let sessionName: String
    let service: any SSHServicing
    let windowsModel: TerminalWindowsModel
    @Binding var renamingWindow: TmuxWindow?
    @Binding var closingWindow: TmuxWindow?
    @Binding var showKillPaneConfirm: Bool

    func body(content: Content) -> some View {
        content
            .sheet(item: $renamingWindow) { window in
                SessionNameSheet(mode: .renameWindow(current: window.name)) { newName in
                    try await service.renameWindow(session: sessionName, index: window.index, to: newName)
                    await windowsModel.refresh()
                }
            }
            .confirmationDialog("¿Cerrar el panel activo?", isPresented: $showKillPaneConfirm, titleVisibility: .visible) {
                Button("Cerrar panel", role: .destructive) { Task { await windowsModel.killPane() } }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Se cerrará el panel activo y se perderá lo que corra en él.")
            }
            .confirmationDialog(
                "¿Cerrar la ventana \(closingWindow?.index ?? 0): \(closingWindow?.name ?? "")?",
                isPresented: Binding(get: { closingWindow != nil }, set: { if !$0 { closingWindow = nil } }),
                titleVisibility: .visible,
                presenting: closingWindow
            ) { window in
                Button("Cerrar ventana", role: .destructive) { Task { await windowsModel.close(window) } }
                Button("Cancelar", role: .cancel) {}
            } message: { _ in
                Text("Se cerrarán sus paneles y se perderá lo que corra en ellos.")
            }
    }
}

/// Identidad de las acciones de pestaña del terminal (ver `TabActions.identity`).
///
/// Resume cada ventana en lo que importa a los menús (índice, activa, agente), no en el
/// comando exacto: así un `ls` o un `git` en primer plano no reconstruye la barra de
/// menús. Cambia siempre que cambian las ventanas que capturan los closures.
private struct TabIdentity: Hashable {
    struct WindowKey: Hashable {
        let index: Int
        let isActive: Bool
        let agent: CodingAgent?
    }

    let handle: SessionHandle
    let windows: [WindowKey]
    let installedAgents: Set<CodingAgent>?

    init(handle: SessionHandle, windows: [TmuxWindow], claude: [Int: ClaudeActivity], installedAgents: Set<CodingAgent>?) {
        self.handle = handle
        self.windows = windows.map {
            WindowKey(
                index: $0.index,
                isActive: $0.isActive,
                agent: WindowTabs.agent(for: $0, claudeReported: claude[$0.index] != nil)
            )
        }
        self.installedAgents = installedAgents
    }
}
