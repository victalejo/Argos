//
//  ClaudeBudgetModel.swift
//  ArgosCore
//
//  Apartado «Presupuesto» de la pantalla de Encargos (Mac e iPhone/iPad): fijar los topes
//  del proyecto y ver lo gastado frente a cada uno. Quien frena es el despachador del
//  servidor; aquí solo se lee y se guarda la configuración.
//

import Foundation
import Observation

@MainActor
@Observable
final class ClaudeBudgetModel {

    private(set) var reading: ClaudeBudgetReading?
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    // Formulario.
    var windowEnabled = false
    var windowPercent = ClaudeBudgetModel.defaultWindowPercent
    var dailyEnabled = false
    var dailyUSD = ClaudeBudgetModel.defaultDailyUSD

    static let defaultWindowPercent = 20
    static let defaultDailyUSD = 5.0
    /// Cada cuánto se relee el consumo con la pantalla abierta.
    static let refreshInterval: Duration = .seconds(30)

    @ObservationIgnored private let service: any SSHServicing
    @ObservationIgnored let projectKey: String
    @ObservationIgnored private var formLoaded = false

    init(service: any SSHServicing, projectKey: String) {
        self.service = service
        self.projectKey = projectKey
    }

    /// Lo que pide el formulario ahora mismo.
    var draft: ClaudeProjectBudget {
        ClaudeProjectBudget(
            windowPercent: windowEnabled ? windowPercent : nil,
            dailyUSD: dailyEnabled ? dailyUSD : nil
        )
    }

    var saved: ClaudeProjectBudget { reading?.budget ?? ClaudeProjectBudget() }
    var hasChanges: Bool { reading != nil && draft != saved }
    /// El servidor tiene un formato más nuevo (de otra versión de Argos): no se pisa.
    var canEdit: Bool { reading.map { !$0.budget.isNewerFormat } ?? false }
    var canSave: Bool { canEdit && hasChanges && !isSaving && draftIsValid }

    var draftIsValid: Bool {
        (!windowEnabled || ClaudeProjectBudget.windowRange.contains(windowPercent))
            && (!dailyEnabled || ClaudeProjectBudget.dailyRange.contains(dailyUSD))
    }

    func evaluation(now: Date = Date()) -> ClaudeBudgetEvaluation? {
        reading?.evaluation(projectKey: projectKey, now: now)
    }

    /// Bloqueo anotado por el despachador que sigue vigente.
    func activeBlock(now: Date = Date()) -> ClaudeBudgetBlock? {
        reading?.block.flatMap { $0.isActive(now: now) ? $0 : nil }
    }

    /// Lee y relee mientras la tarea viva. Con un tope puesto, pone al día el índice de uso.
    func watch() async {
        await reload()
        if !saved.isEmpty { await refreshIndex() }
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.refreshInterval)
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    func reload() async {
        do {
            let fresh = try await ConnectionPriority.background { try await self.service.readProjectBudget(projectKey: self.projectKey) }
            reading = fresh
            if !formLoaded { fillForm(from: fresh.budget) }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            Log.ssh.error("Presupuesto: \(error.userMessage, privacy: .public)")
            errorMessage = error.userMessage
        }
    }

    func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.saveProjectBudget(draft, projectKey: projectKey)
            errorMessage = nil
        } catch {
            Log.ssh.error("Presupuesto: \(error.userMessage, privacy: .public)")
            errorMessage = error.userMessage
        }
        await reload()
    }

    private func fillForm(from budget: ClaudeProjectBudget) {
        formLoaded = true
        windowEnabled = budget.windowPercent != nil
        windowPercent = budget.windowPercent ?? Self.defaultWindowPercent
        dailyEnabled = budget.dailyUSD != nil
        dailyUSD = budget.dailyUSD ?? Self.defaultDailyUSD
    }

    private func refreshIndex() async {
        do {
            try await ConnectionPriority.background { try await self.service.startClaudeUsageIndex() }
        } catch {
            Log.ssh.notice("Presupuesto: no se pudo poner al día el uso: \(error.userMessage, privacy: .public)")
        }
    }
}
