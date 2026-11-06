import SwiftUI

/// Punto de entrada de Argos para iPhone/iPad.
///
/// Fase 1: esqueleto. Su función es compilar `ArgosCore` para iOS en la CI y
/// demostrar que el núcleo (modelo, SSH, stores) es portable. La UI real llega en
/// la Fase 3.
@main
struct ArgosiOSApp: App {
    @State private var store = ServerStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List(store.servers) { server in
                    VStack(alignment: .leading) {
                        Text(server.name).font(.headline)
                        Text("\(server.username)@\(server.host)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .overlay {
                    if store.servers.isEmpty {
                        ContentUnavailableView(
                            "Argos para iPhone",
                            systemImage: "terminal",
                            description: Text("Muy pronto: tus sesiones tmux, en el bolsillo.")
                        )
                    }
                }
                .navigationTitle("Servidores")
            }
        }
    }
}
