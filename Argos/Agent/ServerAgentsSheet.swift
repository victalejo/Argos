//
//  ServerAgentsSheet.swift
//  Argos
//
//  «Agentes en este servidor» en el Mac (equivalente a `ArgosiOS/ServerAgentsView`): TODOS
//  los agentes de Argos del servidor, de cualquier proyecto o dispositivo (persistentes y
//  conversaciones del panel), con su memoria e inactividad. Detener uno, «Detener todos» e
//  «Hibernar inactivos» (cada `claude` ocupa ~0,5 GB).
//

import SwiftUI

struct ServerAgentsSheet: View {
    let serverName: String
    let service: any SSHServicing
    /// Se llama tras cada acción (para releer las listas del panel).
    var onChange: () -> Void = {}
    let onClose: () -> Void

    @State private var inventory: ServerAgentInventory?
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var isWorking = false
    @State private var confirmStopAll = false

    private var hibernation: PersistentAgentHibernation { AgentHibernationPreferences.current() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 480)
        .task { await load() }
        .alert("No se pudo completar", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .confirmationDialog("¿Detener todos los agentes?", isPresented: $confirmStopAll, titleVisibility: .visible) {
            Button("Detener todos", role: .destructive) { Task { await stop(inventory?.liveAgents ?? []) } }
        } message: {
            Text("Se paran todos los agentes de Argos de \(serverName), también los del iPhone/iPad y de otros Mac. Los persistentes se pueden reanudar después.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agentes en \(serverName)").font(.headline)
                if let inventory { summary(inventory) }
            }
            Spacer()
            if isWorking { ProgressView().controlSize(.small) }
            Button("Recargar", systemImage: "arrow.clockwise") {
                Task {
                    await service.resetConnectionHealth()
                    await load()
                }
            }
            .labelStyle(.iconOnly)
            .disabled(isWorking)
        }
        .padding(16)
    }

    private func summary(_ inventory: ServerAgentInventory) -> some View {
        let free = inventory.freeMemoryKB.map { String(localized: " · \(ResourceFormat.kilobytes($0)) libres") } ?? ""
        return Text("\(inventory.liveAgents.count) en marcha · usan \(ResourceFormat.kilobytes(inventory.liveResidentKB))\(free)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var content: some View {
        if let inventory {
            ServerAgentsList(inventory: inventory, isWorking: isWorking) { agent in
                Task { await stop([agent]) }
            }
        } else if let loadError {
            ContentUnavailableView("No se pudieron leer los agentes", systemImage: "sparkles", description: Text(loadError))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        let candidates = hibernation.isEnabled
            ? (inventory?.hibernationCandidates(idleSeconds: hibernation.idleSeconds) ?? []) : []
        return HStack {
            Button("Hibernar inactivos (\(candidates.count))", systemImage: "moon.zzz") {
                Task { await hibernate(candidates) }
            }
            .disabled(candidates.isEmpty || isWorking)
            .help(hibernation.isEnabled
                  ? "Para los agentes quietos sin actividad desde hace \(PersistentAgentHibernation.title(forHours: hibernation.idleHours)) o más; se reanudan al escribirles."
                  : "La hibernación automática está desactivada en Ajustes.")
            Button("Detener todos", systemImage: "stop.circle", role: .destructive) { confirmStopAll = true }
                .disabled((inventory?.liveAgents.isEmpty ?? true) || isWorking)
            Spacer()
            Button("Cerrar", action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func load() async {
        do {
            inventory = try await service.serverAgentInventory()
            loadError = nil
        } catch {
            loadError = error.userMessage
        }
    }

    private func stop(_ agents: [ServerAgentProcess]) async {
        await run { try await ServerAgentActions.stop(agents, service: service) }
    }

    private func hibernate(_ agents: [ServerAgentProcess]) async {
        let minimum = hibernation.idleSeconds
        await run { try await ServerAgentActions.hibernate(agents, minIdleSeconds: minimum, service: service) }
    }

    /// Acción explícita del usuario: levanta antes el bloqueo de conexión.
    private func run(_ action: () async throws -> [String]) async {
        isWorking = true
        defer { isWorking = false }
        await service.resetConnectionHealth()
        do {
            actionError = ServerAgentActions.failureMessage(try await action(), inventory: inventory)
        } catch {
            actionError = error.userMessage
            Log.agent.error("Acción sobre agentes fallida: \(error.localizedDescription, privacy: .private)")
        }
        await load()
        onChange()
    }
}

private struct ServerAgentsList: View {
    let inventory: ServerAgentInventory
    let isWorking: Bool
    let onStop: (ServerAgentProcess) -> Void

    var body: some View {
        let live = inventory.liveAgents
        let stopped = inventory.agents.filter { !$0.isAlive }
        List {
            Section("En marcha") {
                if live.isEmpty {
                    Text("No hay agentes en marcha.").foregroundStyle(.secondary)
                }
                ForEach(live) { agent in
                    ServerAgentRow(agent: agent, isWorking: isWorking) { onStop(agent) }
                }
            }
            if !stopped.isEmpty {
                Section("Detenidos o en reposo") {
                    ForEach(stopped) { ServerAgentRow(agent: $0, isWorking: isWorking, onStop: nil) }
                }
            }
        }
    }
}

private struct ServerAgentRow: View {
    let agent: ServerAgentProcess
    let isWorking: Bool
    let onStop: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(agent.isAlive ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.title).font(.body.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if agent.isAlive {
                Text(ResourceFormat.kilobytes(agent.residentKB))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let onStop {
                Button("Detener", role: .destructive, action: onStop)
                    .controlSize(.small)
                    .disabled(isWorking)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        if agent.hasPendingPermission { return "hand.raised.fill" }
        switch agent.kind {
        case .persistent(let meta): return meta.isHibernated ? "moon.zzz" : "server.rack"
        case .panel: return "laptopcomputer"
        }
    }

    private var detail: String {
        var parts: [String] = []
        if case .persistent(let meta) = agent.kind { parts.append(ProjectRow.shortPath(meta.workingDirectory)) }
        if agent.hasPendingPermission { parts.append(String(localized: "espera tu permiso")) }
        if let idle = agent.idleSeconds, agent.isAlive {
            parts.append(String(localized: "inactivo \(Duration.seconds(idle).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2)))"))
        }
        if case .persistent(let meta) = agent.kind, !agent.isAlive {
            parts.append(meta.isHibernated ? String(localized: "en reposo") : String(localized: "detenido"))
        }
        return parts.joined(separator: " · ")
    }
}
