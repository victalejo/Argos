//
//  OpenProjectIntent.swift
//  ArgosiOS
//
//  Atajo «Abrir proyecto»: abre Argos en un proyecto y una pestaña. Pasa por el mismo
//  camino que un aviso tocado (`NotificationRoute` → `ServerHub.follow`), así que con el
//  bloqueo de Face ID activo espera a que se desbloquee la app.
//

import AppIntents
import Foundation

struct OpenProjectIntent: AppIntent {
    static let title: LocalizedStringResource = "Abrir proyecto"
    static let description: IntentDescription? = IntentDescription(
        "Abre un proyecto de Argos en la pestaña que elijas (Terminal, Archivos, Cambios o Agentes).",
        categoryName: "Proyectos"
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = true

    @Parameter(title: "Proyecto", requestValueDialog: "¿Qué proyecto?")
    var project: ProjectEntity

    @Parameter(title: "Pestaña", default: .terminal)
    var tab: ProjectTabOption

    static var parameterSummary: some ParameterSummary {
        Summary("Abrir \(\.$project) en \(\.$tab)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let cache = ProjectShortcutCacheStore().load()
        guard let route = NotificationRoute.open(identifier: project.id, cache: cache, tab: tab.routeTab) else {
            throw ShortcutError.projectNotFound
        }
        AgentNotifier.shared.open(route)
        ProjectShortcutIndex.markUsed(project.id)
        return .result()
    }
}
