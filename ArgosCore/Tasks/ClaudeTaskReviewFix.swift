//
//  ClaudeTaskReviewFix.swift
//  ArgosCore
//
//  «Pedir a Claude que lo arregle» (lógica pura): el encargo nuevo que corrige lo que
//  bloqueó el revisor. Va al mismo sitio que el bloqueado (su agente en el mismo worktree y
//  rama, o la misma ventana de la terminal), con el informe como prompt, commit y push: al
//  terminar vuelve a pasar por la comprobación y el revisor (que verá también el encargo
//  original, ver `fixes=` en el despachador).
//

import Foundation

enum ClaudeTaskReviewFix {

    /// Hallazgos que se copian en el prompt como máximo.
    static let maxFindings = 20

    /// Prompt del arreglo (va a Claude: no se traduce).
    static func prompt(for task: ClaudeTask) -> String {
        var lines = [
            "El revisor automático de Argos bloqueó el push del encargo «\(task.title)».",
            "Corrige lo que señala sin salirte de lo que pedía ese encargo. No hagas commit ni push: Argos lo hará al terminar y volverá a revisarlo.",
        ]
        guard let review = task.review, review.verdict != .inconclusive else {
            lines.append("La revisión no fue concluyente (el revisor no respondió o su respuesta no se pudo leer). Revisa tú los cambios de esta rama respecto a main y corrige lo que haga falta.")
            return lines.joined(separator: "\n")
        }
        if !review.summary.isEmpty { lines += ["", "Resumen del revisor: \(review.summary)"] }
        let findings = review.sortedFindings.prefix(maxFindings)
        if !findings.isEmpty {
            lines += ["", "Hallazgos:"]
            for finding in findings {
                let severity = finding.severity?.rawValue ?? "?"
                let place = finding.location.map { " (\($0))" } ?? ""
                let category = finding.category.isEmpty ? "" : " [\(finding.category)]"
                lines.append("- \(severity)\(category)\(place): \(finding.message)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// El encargo nuevo; `nil` si al bloqueado le falta lo necesario (carpeta o rama).
    static func request(
        for task: ClaudeTask,
        permissionMode: ClaudeAgentCommand.PermissionMode
    ) -> ClaudeTaskRequest? {
        var request = ClaudeTaskRequest(
            prompt: prompt(for: task), session: task.session ?? "", window: task.window ?? 0
        )
        if task.isAgent {
            guard let directory = task.directory, !directory.isEmpty, let branch = task.branch, !branch.isEmpty else { return nil }
            request.target = .agent(id: UUID().uuidString.lowercased(), worktree: directory, branch: branch)
            request.reuseWorktree = true
            request.permissionMode = permissionMode
        } else {
            guard task.session?.isEmpty == false else { return nil }
        }
        request.customTitle = "Arreglo de la revisión: \(task.title)"  // se guarda en el servidor: no se traduce
        request.source = "review"
        // El arreglo sigue con el modelo y el esfuerzo del encargo revisado.
        request.modelChoice = task.modelChoice
        request.reference = task.folder
        request.commit = true
        request.push = true
        request.extraMeta["fixes"] = task.folder
        if let check = task.checkCommand { request.extraMeta["check"] = check }
        if let minutes = task.maxMinutes { request.extraMeta["max_minutes"] = String(max(1, minutes)) }
        return request
    }
}
