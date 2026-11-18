//
//  ServerTipsSection.swift
//  ArgosiOS
//
//  Avisos contextuales al principio de la lista de proyectos de un servidor:
//  - El servidor tiene Claude Code pero no los hooks de Argos: sin ellos no hay
//    insignias ni avisos (antes solo se activaban desde el Mac y nada lo explicaba).
//  - Se entra por contraseña: ofrece pasar a una clave creada en este iPhone.
//  - Hay actividad de Claude y los avisos están sin activar: botón para pedir permiso
//    (siempre desde un toque, nunca desde un sondeo).
//  Cada consejo se puede descartar por servidor.
//

import SwiftUI

struct ServerTipsSection: View {
    let server: Server
    let viewModel: SessionsViewModel

    @Environment(ServerHub.self) private var hub
    /// Consejos descartados, como «<tipo>:<servidor>» separados por saltos de línea.
    @AppStorage("tips.dismissed") private var dismissed = ""
    @State private var hasClaude = false
    @State private var notificationsUndecided = false
    @State private var confirmingHooks = false
    @State private var confirmingKey = false
    @State private var isWorking = false
    @State private var resultMessage: String?

    private enum Tip: String { case hooks, deviceKey, notifications }

    private var showsHooks: Bool { hasClaude && hub.claudeHooks[server.id] == false && !isDismissed(.hooks) }
    private var showsDeviceKey: Bool { server.authMethod == .password && !isDismissed(.deviceKey) }
    private var showsNotifications: Bool {
        notificationsUndecided && !isDismissed(.notifications)
            && (hub.claudeHooks[server.id] == true || viewModel.claudeActivity != .empty)
    }

    var body: some View {
        Group {
            if showsHooks || showsDeviceKey || showsNotifications {
                Section {
                    if showsHooks { hooksTip }
                    if showsNotifications { notificationsTip }
                    if showsDeviceKey { deviceKeyTip }
                }
            }
        }
        .task(id: server.id) { await refresh() }
        .confirmationDialog("¿Activar el indicador de Claude Code en «\(server.name)»?", isPresented: $confirmingHooks, titleVisibility: .visible) {
            Button("Activar") { installHooks() }
        } message: {
            Text(ClaudeHooksCopy.explanation)
        }
        .confirmationDialog("¿Usar una clave de este iPhone en «\(server.name)»?", isPresented: $confirmingKey, titleVisibility: .visible) {
            Button("Crear e instalar la clave") { installDeviceKey() }
        } message: {
            Text(DeviceKeyCopy.explanation)
        }
        .alert("Listo", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
    }

    // MARK: - Consejos

    private var hooksTip: some View {
        tip(
            .hooks,
            title: "Activa el indicador de Claude",
            detail: "Así verás qué hace Claude en cada sesión y ventana, y te avisaremos cuando termine o espere tu permiso.",
            symbol: "sparkles",
            action: "Activar…"
        ) { confirmingHooks = true }
    }

    private var notificationsTip: some View {
        tip(
            .notifications,
            title: "Recibe avisos de Claude",
            detail: "Permite las notificaciones para saber cuándo Claude termina o espera tu respuesta.",
            symbol: "bell.badge",
            action: "Activar avisos"
        ) {
            Task {
                await AgentNotifier.shared.requestAuthorizationFromUserAction()
                await refreshNotifications()
            }
        }
    }

    private var deviceKeyTip: some View {
        tip(
            .deviceKey,
            title: "Entra con una clave en vez de contraseña",
            detail: "Argos crea una clave Ed25519 en este iPhone, la añade al servidor y comprueba que funciona antes de olvidar la contraseña.",
            symbol: "key.horizontal",
            action: "Usar una clave…"
        ) { confirmingKey = true }
    }

    private func tip(_ kind: Tip, title: String, detail: String, symbol: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                Spacer()
                Button("Descartar", systemImage: "xmark") { dismiss(kind) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            Text(detail).font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button(action, action: perform)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isWorking)
                if isWorking { ProgressView().controlSize(.small) }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Acciones

    private func refresh() async {
        await refreshNotifications()
        let agents: Set<CodingAgent>?
        if let cached = InstalledAgentsCache.agents[server.id] {
            agents = cached
        } else {
            agents = try? await viewModel.service.installedCodingAgents()
            if let agents { InstalledAgentsCache.agents[server.id] = agents }
        }
        hasClaude = agents?.contains(.claude) ?? false
        if hasClaude { await hub.checkClaudeHooks(of: server) }
    }

    private func refreshNotifications() async {
        notificationsUndecided = await AgentNotifier.shared.readiness().permission == .notDetermined
    }

    private func installHooks() {
        isWorking = true
        Task {
            defer { isWorking = false }
            resultMessage = await hub.installClaudeHooks(on: server)
            // Acción del usuario: buen momento para pedir el permiso de avisos.
            await AgentNotifier.shared.requestAuthorizationFromUserAction()
            await refreshNotifications()
        }
    }

    private func installDeviceKey() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await hub.installDeviceKey(on: server)
                resultMessage = "«\(server.name)» ya entra con la clave de este iPhone. La contraseña se ha borrado de este dispositivo."
                await hub.viewModel(for: hub.store.server(withID: server.id) ?? server).load()
            } catch {
                resultMessage = error.userMessage
            }
        }
    }

    private func isDismissed(_ kind: Tip) -> Bool {
        dismissed.split(separator: "\n").contains { $0 == "\(kind.rawValue):\(server.id.uuidString)" }
    }

    private func dismiss(_ kind: Tip) {
        dismissed = (dismissed.split(separator: "\n").map(String.init) + ["\(kind.rawValue):\(server.id.uuidString)"])
            .joined(separator: "\n")
    }
}

/// Textos compartidos por el consejo y el menú del servidor.
enum ClaudeHooksCopy {
    static let explanation = "Se añadirán hooks a ~/.claude/settings.json del servidor (con copia en "
        + "settings.json.argos-backup; tus hooks actuales se conservan). Avisan a Argos cuando Claude "
        + "trabaja, termina o espera tu respuesta. Las sesiones de Claude ya abiertas deben reiniciarse para usarlos."
}

enum DeviceKeyCopy {
    static let explanation = "Se crea una clave Ed25519 en este dispositivo, se añade a ~/.ssh/authorized_keys "
        + "del servidor y se prueba. Solo si funciona, el servidor pasa a usarla y se borra la contraseña de "
        + "este dispositivo. La clave aparece en «Dispositivos autorizados» del Mac por si quieres revocarla."
}
