import SwiftUI

/// Punto de entrada de Argos para iPhone/iPad.
///
/// Servidores, proyectos y sesiones tmux, terminal en vivo, archivos y agentes de Claude
/// persistentes; tres columnas en iPad. Comparte
/// con el Mac el núcleo (`ArgosCore/`): modelo, SSH, proyectos en el servidor.
@main
struct ArgosiOSApp: App {
    @State private var hub: ServerHub
    @State private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let hub = ServerHub()
        _hub = State(initialValue: hub)
        // La tarea de refresco en segundo plano debe registrarse antes de terminar de
        // arrancar.
        AgentNotifier.shared.register(hub: hub)
        // Nombre con el que este dispositivo aparece en `argos-ports` (skill de Claude).
        PortForwardDevice.name = UIDevice.current.model
        hub.startNetworkMonitoring()
    }

    private struct CoverState: Equatable {
        let cover: Bool
        let active: Bool
        let locked: Bool
    }

    private var coverState: CoverState {
        let active = scenePhase == .active
        return CoverState(
            cover: AppLockPolicy.shouldCover(enabled: lock.isEnabled, isLocked: lock.isLocked, isActive: active),
            active: active,
            locked: lock.isLocked
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hub)
                .environment(lock)
                .tint(.indigo)
                // Bloqueada, o con el bloqueo activo fuera de primer plano (selector de
                // apps): se tapa todo, también las hojas y alertas abiertas.
                .onChange(of: coverState, initial: true) { _, state in
                    AppLockWindows.shared.update(cover: state.cover, lock: lock, isActive: state.active)
                    hub.setLocked(AppLockPolicy.shouldDeferIncoming(enabled: lock.isEnabled, isLocked: lock.isLocked))
                }
                .task { await lock.unlock() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                lock.didEnterBackground()
                AgentNotifier.shared.prepareForBackground()
                hub.didEnterBackground()
            case .active:
                lock.didBecomeActive()
                hub.migrateSecretAccessibilityIfNeeded()
                AgentNotifier.shared.didReturnToForeground()
                hub.cloudSync?.sync()
                hub.didBecomeActive()
            default: break
            }
        }
    }
}
