//
//  AskClaudeIntent.swift
//  ArgosiOS
//
//  Atajo «Pedir a Claude en ‹proyecto›»: manda un encargo al agente persistente más
//  reciente del proyecto (o crea uno) y termina, SIN abrir Argos. El agente sigue en el
//  servidor; su aviso de «terminó / espera tu permiso» llega como siempre.
//
//  Seguridad:
//  - Exige el dispositivo desbloqueado (`authenticationPolicy`) y, si Argos tiene activo
//    su bloqueo con Face ID, la misma autenticación que la app antes de conectar
//    (`ShortcutAuthenticator`); sin interfaz para pedirla, se niega y propone abrir Argos.
//  - Antes de mandar trabajo a un agente que actúa sin preguntar o que acepta ediciones
//    solo, pide confirmación con servidor, proyecto y modo, salvo que el usuario active
//    «Permitir atajos sin confirmar» en Ajustes (desactivado por defecto).
//  - Con poca memoria o demasiados agentes no arranca otro (`AgentLaunchGuard`).
//  - El encargo y el token van por la entrada estándar, nunca en la línea de comandos.
//

import AppIntents
import Foundation

struct AskClaudeIntent: ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Pedir a Claude"
    static let description: IntentDescription? = IntentDescription(
        "Manda un encargo al agente de Claude Code de un proyecto de Argos sin abrir la app. El agente trabaja en el servidor y Argos te avisa cuando termine o necesite permiso.",
        categoryName: "Agentes"
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = false

    @Parameter(title: "Proyecto", requestValueDialog: "¿En qué proyecto?")
    var project: ProjectEntity

    @Parameter(
        title: "Encargo",
        inputOptions: String.IntentInputOptions(multiline: true),
        requestValueDialog: "¿Qué quieres que haga Claude?"
    )
    var task: String?

    /// Un encargo de la biblioteca del proyecto; si además hay texto, va detrás.
    @Parameter(title: "Encargo guardado")
    var savedPrompt: SavedPromptEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Pedir a Claude en \(\.$project): \(\.$task)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let typed = task?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if savedPrompt == nil {
            if typed.isEmpty { throw $task.needsValueError("¿Qué quieres que haga Claude?") }
            _ = try ShortcutTask.validated(typed)
        }
        // Antes de tocar la red: el bloqueo de la app manda (no lo salta «sin confirmar»).
        try await ShortcutAuthenticator.requireUnlock(for: self)
        let target = try ShortcutAgentSender.target(forProjectID: project.id)
        let prepared = try await ShortcutAgentSender.prepare(target)
        let text: String
        do {
            text = try await resolvedText(typed: typed, prepared: prepared)
        } catch {
            ShortcutAgentSender.close(prepared.service)
            throw error
        }
        let mode = prepared.plan.permissionMode
        if ShortcutAgentPlanner.requiresConfirmation(mode: mode, allowsUnconfirmed: ShortcutPreferences.allowsUnconfirmed()) {
            do {
                try await requestConfirmation(actionName: .send, dialog: IntentDialog(stringLiteral: confirmationText(prepared)))
            } catch {
                ShortcutAgentSender.close(prepared.service)
                throw error
            }
        }
        try await ShortcutAgentSender.send(text, prepared: prepared)
        let name = prepared.target.project.displayName
        let done = prepared.plan.startsClaude
            ? String(localized: "Claude arranca en «\(name)».")
            : String(localized: "Enviado a Claude en «\(name)».")
        return .result(dialog: IntentDialog(stringLiteral: done))
    }

    /// Lo escrito y, si se eligió, el encargo guardado leído del servidor con sus
    /// variables rellenas (el texto de la biblioteca nunca se guarda en el dispositivo).
    private func resolvedText(typed: String, prepared: ShortcutAgentSender.Prepared) async throws -> String {
        guard let promptID = savedPrompt?.id else { return try ShortcutTask.validated(typed) }
        let service = prepared.service
        let path = prepared.target.project.path
        let saved = try await Deadline.value(within: Self.promptTimeout, timeoutError: { ShortcutError.timedOut }) {
            let report = try await service.loadProjectsReport()
            let prompt = try ShortcutPromptResolver.savedPrompt(id: promptID, report: report, projectPath: path)
            return await PromptExpansion.expand(prompt.text, service: service, projectPath: path)
        }
        return try ShortcutPromptResolver.combined(saved: saved, typed: typed)
    }

    /// Leer la biblioteca y las variables de git (la conexión ya está abierta).
    private static let promptTimeout: Duration = .seconds(8)

    private func confirmationText(_ prepared: ShortcutAgentSender.Prepared) -> String {
        let modeTitle = ShortcutAgentPlanner.modeTitle(prepared.plan.permissionMode)
        let project = prepared.target.project.displayName
        let server = prepared.target.server.name
        // Frases completas (no trozos concatenados): el orden cambia entre idiomas.
        switch prepared.plan {
        case .reuse:
            return String(localized: "Se mandará al agente en marcha de «\(project)» en \(server), en modo «\(modeTitle)»: puede hacer cambios sin pedirte permiso. ¿Enviar el encargo?")
        case .resume:
            return String(localized: "Se reanudará el último agente de «\(project)» en \(server), en modo «\(modeTitle)»: puede hacer cambios sin pedirte permiso. ¿Enviar el encargo?")
        case .create:
            return String(localized: "Se creará un agente nuevo de «\(project)» en \(server), en modo «\(modeTitle)»: puede hacer cambios sin pedirte permiso. ¿Enviar el encargo?")
        }
    }
}
