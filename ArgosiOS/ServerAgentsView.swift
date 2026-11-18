//
//  ServerAgentsView.swift
//  ArgosiOS
//
//  «Agentes en este servidor»: TODOS los agentes de Argos vivos en el servidor, de
//  cualquier proyecto (persistentes y conversaciones del panel del Mac), con su memoria
//  e inactividad. Permite detener uno, detener todos e hibernar los inactivos (cada
//  `claude` ocupa ~0,5 GB: el servidor ya se quedó una vez sin memoria por acumularlos).
//

import SwiftUI

struct ServerAgentsView: View {
    let server: Server
    let service: any SSHServicing

    @State private var inventory: ServerAgentInventory?
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var confirmStopAll = false
    /// Error de la última acción (parar, hibernar): se muestra en una alerta y no lo borra
    /// el refresco posterior.
    @State private var actionError: String?
    @State private var showsStopped = false

    private var hibernation: PersistentAgentHibernation { AgentHibernationPreferences.current() }

    var body: some View {
        Group {
            if let inventory {
                list(inventory)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("No se pudieron leer los agentes", systemImage: "sparkles")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Reintentar") {
                        Task {
                            await service.resetConnectionHealth()
                            await load()
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Agentes en \(server.name)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert("No se pudo completar", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .confirmationDialog("¿Detener todos los agentes?", isPresented: $confirmStopAll, titleVisibility: .visible) {
            Button("Detener todos", role: .destructive) { Task { await stopAll() } }
        } message: {
            Text("Se paran todos los agentes de Argos de este servidor, también las conversaciones abiertas en el Mac. Los de iPhone/iPad se pueden reanudar después.")
        }
    }

    @ViewBuilder
    private func list(_ inventory: ServerAgentInventory) -> some View {
        let live = inventory.liveAgents
        let stopped = inventory.agents.filter { !$0.isAlive }
        let candidates = hibernation.isEnabled ? inventory.hibernationCandidates(idleSeconds: hibernation.idleSeconds) : []
        List {
            Section {
                LabeledContent("En marcha", value: "\(live.count)")
                LabeledContent("Memoria que usan", value: ResourceFormat.kilobytes(inventory.liveResidentKB))
                if let free = inventory.freeMemoryKB {
                    LabeledContent("Memoria libre del servidor", value: ResourceFormat.kilobytes(free))
                }
            }
            Section {
                Button("Hibernar inactivos (\(candidates.count))", systemImage: "moon.zzz") {
                    Task { await hibernate(candidates) }
                }
                .disabled(candidates.isEmpty || isWorking)
                Button("Detener todos", systemImage: "stop.circle", role: .destructive) { confirmStopAll = true }
                    .disabled(live.isEmpty || isWorking)
            } footer: {
                Text(hibernation.isEnabled
                     ? "Hibernar para los agentes quietos sin actividad desde hace \(PersistentAgentHibernation.title(forHours: hibernation.idleHours)) o más; se reanudan solos al escribirles. \(PersistentAgentHibernation.backgroundWorkWarning)"
                     : "La hibernación automática está desactivada: «Hibernar inactivos» no encontrará candidatos.")
            }
            if live.isEmpty {
                Section { Text("No hay agentes en marcha.").foregroundStyle(.secondary) }
            } else {
                Section("En marcha") {
                    ForEach(live) { agent in
                        ServerAgentRow(agent: agent)
                            .swipeActions {
                                Button("Detener", role: .destructive) { Task { await stop([agent]) } }
                            }
                            .contextMenu {
                                Button("Detener", systemImage: "stop.circle", role: .destructive) { Task { await stop([agent]) } }
                            }
                    }
                }
            }
            if !stopped.isEmpty {
                Section("Detenidos o en reposo", isExpanded: $showsStopped) {
                    ForEach(stopped) { ServerAgentRow(agent: $0) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { if isWorking { ProgressView() } }
    }

    private func load() async {
        do {
            inventory = try await service.serverAgentInventory()
            errorMessage = nil
        } catch {
            errorMessage = error.userMessage
        }
    }

    private func stop(_ agents: [ServerAgentProcess]) async {
        await run {
            let persistent = agents.compactMap { agent -> String? in
                if case .persistent = agent.kind { return agent.sessionID }
                return nil
            }
            let panel = agents.compactMap { agent -> (pid: Int32, sessionID: String)? in
                if case .panel(let pid) = agent.kind { return (pid, agent.sessionID) }
                return nil
            }
            var failed: [String] = []
            if !persistent.isEmpty {
                let output = try await service.runAgentScript(ServerAgentInventory.stopPersistent(ids: persistent))
                failed = ServerAgentInventory.failures(in: output)
            }
            if !panel.isEmpty { _ = try await service.runAgentScript(ServerAgentInventory.stopPanel(panel)) }
            return failed
        }
    }

    private func stopAll() async {
        await stop(inventory?.liveAgents ?? [])
    }

    private func hibernate(_ agents: [ServerAgentProcess]) async {
        let minimum = hibernation.idleSeconds
        await run {
            let output = try await service.runAgentScript(
                ServerAgentInventory.hibernate(ids: agents.map(\.sessionID), minIdleSeconds: minimum)
            )
            return ServerAgentInventory.failures(in: output)
        }
    }

    /// Ejecuta una acción que devuelve los agentes que no pudo tratar (p. ej. atascados).
    private func run(_ action: () async throws -> [String]) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let failed = try await action()
            if !failed.isEmpty {
                let names = failed.map { id in inventory?.agents.first { $0.sessionID == id }?.title ?? id }
                actionError = String(localized: "No se pudieron parar: \(names.joined(separator: ", ")). Inténtalo de nuevo; si sigue, reinicia el servidor.")
            }
        } catch {
            actionError = error.userMessage
            Log.agent.error("Acción sobre agentes fallida: \(error.localizedDescription, privacy: .private)")
        }
        await load()
    }
}

private struct ServerAgentRow: View {
    let agent: ServerAgentProcess

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(agent.isAlive ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 26)
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
        }
    }

    private var icon: String {
        if agent.hasPendingPermission { return "hand.raised.fill" }
        switch agent.kind {
        case .persistent(let meta): return meta.isHibernated ? "moon.zzz" : "sparkles"
        case .panel: return "desktopcomputer"
        }
    }

    private var detail: String {
        var parts: [String] = []
        if case .persistent(let meta) = agent.kind { parts.append(ProjectRowPath.short(meta.workingDirectory)) }
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

/// Ruta corta para mostrar (`~/…` y solo las dos últimas carpetas).
enum ProjectRowPath {
    static func short(_ path: String) -> String {
        let components = path.split(separator: "/")
        guard components.count > 2 else { return path }
        return "…/" + components.suffix(2).joined(separator: "/")
    }
}
