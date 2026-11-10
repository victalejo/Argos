import SwiftUI

/// Punto de entrada de Argos para iPhone/iPad.
///
/// Servidores, proyectos y sesiones tmux, terminal en vivo, archivos y agentes de Claude
/// persistentes; tres columnas en iPad. Comparte
/// con el Mac el núcleo (`ArgosCore/`): modelo, SSH, proyectos en el servidor.
@main
struct ArgosiOSApp: App {
    @State private var hub: ServerHub
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let hub = ServerHub()
        _hub = State(initialValue: hub)
        // La tarea de refresco en segundo plano debe registrarse antes de terminar de
        // arrancar.
        AgentNotifier.shared.register(hub: hub)
        // Nombre con el que este dispositivo aparece en `argos-ports` (skill de Claude).
        PortForwardDevice.name = UIDevice.current.model
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hub)
                .tint(.indigo)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                AgentNotifier.shared.prepareForBackground()
                hub.suspendTerminals()
                hub.suspendAgents()
            case .active:
                hub.cloudSync?.sync()
                hub.reconnectTerminals()
                hub.resumeAgents()
            default: break
            }
        }
    }
}
