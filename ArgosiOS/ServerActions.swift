//
//  ServerActions.swift
//  ArgosiOS
//
//  Acciones del menú de un servidor en la lista (mantener pulsado): recursos,
//  indicador de Claude, pasar a una clave de este iPhone y «Olvidar host key» (a la que
//  remite el aviso de huella cambiada al escanear un QR). Cada una con su confirmación.
//

import SwiftUI

/// Acción pendiente de confirmar o mostrar.
enum ServerAction: Identifiable {
    case resources(Server)
    case installHooks(Server)
    case deviceKey(Server)
    case forgetHostKey(Server)

    var id: String {
        switch self {
        case .resources(let server): return "recursos-\(server.id)"
        case .installHooks(let server): return "hooks-\(server.id)"
        case .deviceKey(let server): return "clave-\(server.id)"
        case .forgetHostKey(let server): return "huella-\(server.id)"
        }
    }

    var server: Server {
        switch self {
        case .resources(let server), .installHooks(let server), .deviceKey(let server), .forgetHostKey(let server):
            return server
        }
    }
}

/// Entradas del menú de un servidor (se ponen dentro de un `contextMenu`).
struct ServerActionItems: View {
    let server: Server
    let perform: (ServerAction) -> Void

    var body: some View {
        Button("Recursos del servidor", systemImage: "gauge.with.dots.needle.50percent") { perform(.resources(server)) }
            .disabled(ImportedKeyStore.needsImport(server))
        Button("Activar indicador de Claude…", systemImage: "sparkles") { perform(.installHooks(server)) }
            .disabled(ImportedKeyStore.needsImport(server))
        if server.authMethod == .password {
            Button("Usar una clave de este iPhone…", systemImage: "key.horizontal") { perform(.deviceKey(server)) }
        }
        Button("Olvidar host key…", systemImage: "lock.open.trianglebadge.exclamationmark") { perform(.forgetHostKey(server)) }
    }
}

/// Confirmaciones, hoja de recursos y resultado de las acciones de servidor.
struct ServerActionsModifier: ViewModifier {
    @Binding var pending: ServerAction?
    @Environment(ServerHub.self) private var hub
    @State private var resources: Server?
    @State private var isWorking = false
    @State private var resultMessage: String?

    private var confirming: ServerAction? {
        if case .resources = pending { return nil }
        return pending
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: pending?.id) { _, _ in
                if case .resources(let server) = pending {
                    resources = server
                    pending = nil
                }
            }
            .confirmationDialog(
                confirming.map(title(for:)) ?? "",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible,
                presenting: confirming
            ) { action in
                Button(confirmLabel(for: action), role: action.isDestructive ? .destructive : nil) { run(action) }
                Button("Cancelar", role: .cancel) {}
            } message: { action in
                Text(message(for: action))
            }
            .sheet(item: $resources) { server in
                ServerResourcesScreen(serverName: server.name, service: hub.viewModel(for: server).service)
            }
            .overlay {
                if isWorking {
                    ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("Servidor", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(resultMessage ?? "")
            }
    }

    private func title(for action: ServerAction) -> String {
        switch action {
        case .resources: return ""
        case .installHooks(let server): return "¿Activar el indicador de Claude Code en «\(server.name)»?"
        case .deviceKey(let server): return "¿Usar una clave de este iPhone en «\(server.name)»?"
        case .forgetHostKey(let server): return "¿Olvidar la host key de «\(server.name)»?"
        }
    }

    private func confirmLabel(for action: ServerAction) -> String {
        switch action {
        case .resources: return ""
        case .installHooks: return "Activar"
        case .deviceKey: return "Crear e instalar la clave"
        case .forgetHostKey: return "Olvidar host key"
        }
    }

    private func message(for action: ServerAction) -> String {
        switch action {
        case .resources: return ""
        case .installHooks: return ClaudeHooksCopy.explanation
        case .deviceKey: return DeviceKeyCopy.explanation
        case .forgetHostKey(let server):
            return "Hazlo solo si reinstalaste \(server.host) o cambió su clave de forma legítima. "
                + "La próxima conexión confiará en la huella que presente el servidor; si no esperabas el cambio, "
                + "podría ser alguien suplantándolo."
        }
    }

    private func run(_ action: ServerAction) {
        let server = hub.store.server(withID: action.server.id) ?? action.server
        pending = nil
        switch action {
        case .resources:
            resources = server
        case .forgetHostKey:
            hub.forgetHostKey(of: server)
            resultMessage = "Se olvidó la huella de \(server.host). La próxima conexión guardará la nueva."
        case .installHooks:
            work {
                let message = await hub.installClaudeHooks(on: server)
                await AgentNotifier.shared.requestAuthorizationFromUserAction()
                return message
            }
        case .deviceKey:
            work {
                do {
                    try await hub.installDeviceKey(on: server)
                    return "«\(server.name)» ya entra con la clave de este iPhone. La contraseña se ha borrado de este dispositivo."
                } catch {
                    return error.userMessage
                }
            }
        }
    }

    private func work(_ task: @escaping @MainActor () async -> String) {
        isWorking = true
        Task { @MainActor in
            resultMessage = await task()
            isWorking = false
        }
    }
}

private extension ServerAction {
    var isDestructive: Bool {
        if case .forgetHostKey = self { return true }
        return false
    }
}

extension View {
    func serverActions(_ pending: Binding<ServerAction?>) -> some View {
        modifier(ServerActionsModifier(pending: pending))
    }
}
