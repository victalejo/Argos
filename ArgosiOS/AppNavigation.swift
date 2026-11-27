//
//  AppNavigation.swift
//  ArgosiOS
//
//  Dónde está el usuario: servidor, proyecto/sesión y pestaña del detalle (Terminal,
//  Archivos, Cambios, Agentes). Un único modelo para iPhone e iPad: la raíz es un solo
//  `NavigationSplitView` que en ancho compacto se colapsa en una pila, así que girar un
//  iPhone grande o redimensionar en iPad (Split View, Stage Manager) ya no reconstruye
//  la navegación ni cierra el terminal. Se guarda con `@SceneStorage` para restaurarlo
//  también tras un arranque en frío.
//

import Observation
import SwiftUI

@MainActor
@Observable
final class AppNavigation {
    private(set) var serverID: Server.ID?
    private(set) var target: ProjectTarget?
    var mode: DetailMode = .terminal
    /// Columna visible cuando la vista está colapsada (iPhone, iPad estrecho).
    var compactColumn: NavigationSplitViewColumn = .sidebar

    /// Elige un servidor (lista de servidores o aviso tocado).
    func selectServer(_ id: Server.ID?) {
        if id != serverID {
            serverID = id
            target = nil
            mode = .terminal
        }
        compactColumn = id == nil ? .sidebar : .content
    }

    /// Abre un proyecto o sesión en el detalle. En iPhone quien navega es la selección de
    /// la lista de proyectos (`ProjectsView`), enlazada a `target`: en iOS 27 cambiar
    /// `compactColumn` desde el código no basta.
    func open(_ newTarget: ProjectTarget?) {
        if newTarget?.id != target?.id { mode = .terminal }
        target = newTarget
        if newTarget != nil { compactColumn = .detail }
    }

    /// El detalle de `targetID` dejó de verse (en iPhone, volver atrás a la lista). Si
    /// sigue siendo el abierto, el modelo vuelve a la columna de proyectos aunque iOS no
    /// lo haya comunicado por el enlace de `preferredCompactColumn`.
    func detailDidDisappear(targetID: String, isCompact: Bool) {
        guard isCompact, target?.id == targetID, compactColumn == .detail else { return }
        compactColumn = .content
    }

    /// Si el servidor guardado ya no existe (borrado, otro dispositivo), se vuelve al inicio.
    func dropMissingServer(exists: (Server.ID) -> Bool) {
        guard let serverID, !exists(serverID) else { return }
        self.serverID = nil
        target = nil
        mode = .terminal
        compactColumn = .sidebar
    }

    // MARK: - Restauración

    private struct Snapshot: Codable, Equatable {
        var serverID: Server.ID?
        var target: ProjectTarget?
        var mode: String
    }

    /// Estado en texto para `@SceneStorage`.
    var encoded: String {
        let snapshot = Snapshot(serverID: serverID, target: target, mode: Self.name(of: mode))
        guard let data = try? JSONEncoder().encode(snapshot) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func restore(from encoded: String) {
        guard !encoded.isEmpty else { return }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(encoded.utf8))
            serverID = snapshot.serverID
            target = snapshot.serverID == nil ? nil : snapshot.target
            mode = Self.mode(named: snapshot.mode)
            compactColumn = target != nil ? .detail : (serverID != nil ? .content : .sidebar)
        } catch {
            Log.store.notice("No se pudo restaurar la navegación: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func name(of mode: DetailMode) -> String {
        switch mode {
        case .terminal: return "terminal"
        case .files: return "files"
        case .changes: return "changes"
        case .agent: return "agent"
        }
    }

    private static func mode(named name: String) -> DetailMode {
        switch name {
        case "files": return .files
        case "changes": return .changes
        case "agent": return .agent
        default: return .terminal
        }
    }
}
