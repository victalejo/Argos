//
//  DoctorModel.swift
//  ArgosCore
//
//  Modelo de la pantalla del Doctor (Mac e iPhone/iPad). Ejecuta UNA comprobación remota
//  (`DoctorScript.command` por `runAgentScript`), la interpreta con `DoctorEvaluator` y
//  aplica los arreglos de un toque con API que Argos ya tiene. Es efímero: se puede
//  recrear sin efectos.
//

import Foundation
import Observation

enum DoctorError: LocalizedError, Equatable {
    case incompleteOutput

    var errorDescription: String? {
        switch self {
        case .incompleteOutput:
            return "El servidor no devolvió una comprobación completa. Vuelve a intentarlo; si se repite, "
                 + "revisa que el servidor tenga `sh` y responda con normalidad."
        }
    }
}

@MainActor
@Observable
final class DoctorModel {

    enum State: Equatable {
        case idle
        case loading
        case loaded(DoctorResult)
        case failed(String)
    }

    private let service: any SSHServicing
    private let now: @Sendable () -> Date

    /// Nombre del servidor (para el título y el informe).
    let serverName: String
    private(set) var state: State = .idle
    /// Arreglo en curso (para deshabilitar su botón).
    private(set) var fixing: DoctorCheckID?
    /// Fallo del último arreglo; la UI lo muestra y lo borra.
    var fixError: String?

    init(service: any SSHServicing, serverName: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        self.serverName = serverName
        self.now = now
    }

    var result: DoctorResult? {
        if case .loaded(let result) = state { return result }
        return nil
    }

    var isLoading: Bool { state == .loading }

    /// Una pasada completa. Si ya hay un resultado, se conserva en pantalla hasta que llegue el nuevo.
    func run() async {
        guard !isLoading else { return }
        let previous = result
        state = .loading
        do {
            let started = now()
            let output = try await service.runAgentScript(DoctorScript.command)
            let finished = now()
            let facts = DoctorFacts.parse(output)
            guard facts.isComplete else { throw DoctorError.incompleteOutput }
            let hooksUpToDate = await hooksUpToDate(facts)
            // Hora del dispositivo en mitad de la consulta: compensa la latencia de ida y vuelta.
            let midpoint = started.addingTimeInterval(finished.timeIntervalSince(started) / 2)
            let context = DoctorEvaluator.Context(deviceNow: midpoint, hooksUpToDate: hooksUpToDate)
            state = .loaded(DoctorResult(checks: DoctorEvaluator.evaluate(facts, context: context), finishedAt: finished))
        } catch {
            Log.ssh.error("doctor: \(error.userMessage, privacy: .public)")
            state = previous.map { .loaded($0) } ?? .failed(error.userMessage)
            if previous != nil { fixError = error.userMessage }
        }
    }

    /// Aplica un arreglo de un toque y vuelve a comprobar. Los comandos para copiar no pasan por aquí.
    func apply(_ fix: DoctorFix, to id: DoctorCheckID) async {
        guard fixing == nil else { return }
        fixing = id
        defer { fixing = nil }
        do {
            switch fix {
            case .installClaudeHooks:
                try await service.installClaudeHooks()
            case .installPortsSkill:
                _ = try await service.runAgentScript(PortForwardServerFiles.installCommand)
            case .copyCommand:
                return
            }
        } catch {
            Log.ssh.error("doctor fix \(id.rawValue, privacy: .public): \(error.userMessage, privacy: .public)")
            fixError = error.userMessage
            return
        }
        await run()
    }

    /// Solo se consulta si hay hooks de Argos: comparar con la versión actual cuesta una lectura SFTP.
    private func hooksUpToDate(_ facts: DoctorFacts) async -> Bool? {
        guard let count = Int(facts["hooks.marker"] ?? ""), count > 0 else { return nil }
        do {
            return try await service.claudeHooksInstalled()
        } catch {
            Log.ssh.notice("doctor: no se pudo verificar los hooks: \(error.userMessage, privacy: .public)")
            return nil
        }
    }
}
