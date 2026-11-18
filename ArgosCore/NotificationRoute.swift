//
//  NotificationRoute.swift
//  ArgosCore
//
//  A dónde lleva tocar una notificación: el servidor y, si se sabe, la sesión tmux y su
//  ventana, o un proyecto (por su carpeta), la pestaña de su detalle y el agente
//  persistente cuyo chat abrir. Viaja en el `userInfo` de la notificación, así que al
//  leerlo no se da nada por bueno (lógica pura, compartida por Mac e iPhone/iPad). Los
//  atajos («Abrir proyecto») y Spotlight usan la misma ruta. Las claves nuevas son
//  aditivas: una versión antigua que las ignore abre al menos el servidor.
//

import Foundation

struct NotificationRoute: Equatable, Sendable {
    /// Pestaña del detalle de un proyecto.
    enum Tab: String, CaseIterable, Sendable {
        case terminal, files, changes, agent
    }

    let serverID: UUID
    var session: String?
    var window: Int?
    /// Carpeta ABSOLUTA del proyecto (identifica el proyecto aunque se renombre).
    var projectPath: String?
    var tab: Tab?
    /// Agente persistente cuyo chat abrir (implica la pestaña de agentes).
    var agentID: String?

    private static let serverKey = "argos.serverID"
    private static let sessionKey = "argos.session"
    private static let windowKey = "argos.window"
    private static let projectPathKey = "argos.projectPath"
    private static let tabKey = "argos.tab"
    private static let agentKey = "argos.agentID"

    init(
        serverID: UUID,
        session: String? = nil,
        window: Int? = nil,
        projectPath: String? = nil,
        tab: Tab? = nil,
        agentID: String? = nil
    ) {
        self.serverID = serverID
        self.session = session
        self.window = window
        self.projectPath = projectPath.flatMap(Self.validPath)
        self.agentID = agentID.flatMap(Self.validAgentID)
        self.tab = self.agentID != nil ? .agent : tab
    }

    /// `nil` si la notificación no lleva un destino válido.
    init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo[Self.serverKey] as? String, let serverID = UUID(uuidString: raw) else { return nil }
        self.serverID = serverID
        self.session = (userInfo[Self.sessionKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.window = userInfo[Self.windowKey] as? Int
        self.projectPath = (userInfo[Self.projectPathKey] as? String).flatMap(Self.validPath)
        self.agentID = (userInfo[Self.agentKey] as? String).flatMap(Self.validAgentID)
        let tab = (userInfo[Self.tabKey] as? String).flatMap(Tab.init(rawValue:))
        self.tab = agentID != nil ? .agent : tab
    }

    /// Ruta absoluta, sin caracteres de control y de tamaño razonable.
    private static func validPath(_ raw: String) -> String? {
        guard raw.hasPrefix("/"), raw.utf8.count <= 4096,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return raw
    }

    /// Mismo formato que los ids de los agentes persistentes (UUID).
    private static func validAgentID(_ raw: String) -> String? {
        PersistentAgentScript.isValidID(raw) ? raw : nil
    }

    var userInfo: [String: Any] {
        var info: [String: Any] = [Self.serverKey: serverID.uuidString]
        if let session { info[Self.sessionKey] = session }
        if let window { info[Self.windowKey] = window }
        if let projectPath { info[Self.projectPathKey] = projectPath }
        if let tab { info[Self.tabKey] = tab.rawValue }
        if let agentID { info[Self.agentKey] = agentID }
        return info
    }
}
