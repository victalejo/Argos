//
//  NotificationRoute.swift
//  ArgosCore
//
//  A dónde lleva tocar una notificación: el servidor y, si se sabe, la sesión tmux y su
//  ventana. Viaja en el `userInfo` de la notificación, así que al leerlo no se da nada
//  por bueno (lógica pura, compartida por Mac e iPhone/iPad).
//

import Foundation

struct NotificationRoute: Equatable, Sendable {
    let serverID: UUID
    var session: String?
    var window: Int?

    private static let serverKey = "argos.serverID"
    private static let sessionKey = "argos.session"
    private static let windowKey = "argos.window"

    init(serverID: UUID, session: String? = nil, window: Int? = nil) {
        self.serverID = serverID
        self.session = session
        self.window = window
    }

    /// `nil` si la notificación no lleva un destino válido.
    init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo[Self.serverKey] as? String, let serverID = UUID(uuidString: raw) else { return nil }
        self.serverID = serverID
        self.session = (userInfo[Self.sessionKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.window = userInfo[Self.windowKey] as? Int
    }

    var userInfo: [String: Any] {
        var info: [String: Any] = [Self.serverKey: serverID.uuidString]
        if let session { info[Self.sessionKey] = session }
        if let window { info[Self.windowKey] = window }
        return info
    }
}
