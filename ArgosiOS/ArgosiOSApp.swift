import SwiftUI

/// Punto de entrada de Argos para iPhone/iPad.
///
/// Fase 3 (MVP): servidores, proyectos y sesiones tmux, y terminal en vivo. Comparte
/// con el Mac el núcleo (`ArgosCore/`): modelo, SSH, proyectos en el servidor.
@main
struct ArgosiOSApp: App {
    @State private var hub = ServerHub()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ServersView()
                .environment(hub)
                .tint(.indigo)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: hub.suspendTerminals()
            case .active: hub.reconnectTerminals()
            default: break
            }
        }
    }
}
