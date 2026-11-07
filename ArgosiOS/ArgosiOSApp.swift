import SwiftUI

/// Punto de entrada de Argos para iPhone/iPad.
///
/// Servidores, proyectos y sesiones tmux, terminal en vivo, archivos y agentes de Claude
/// persistentes; tres columnas en iPad. Comparte
/// con el Mac el núcleo (`ArgosCore/`): modelo, SSH, proyectos en el servidor.
@main
struct ArgosiOSApp: App {
    @State private var hub = ServerHub()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hub)
                .tint(.indigo)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                hub.suspendTerminals()
                hub.suspendAgents()
            case .active:
                hub.reconnectTerminals()
                hub.resumeAgents()
            default: break
            }
        }
    }
}
