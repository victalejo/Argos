//
//  ServerEditImpact.swift
//  ArgosCore
//
//  Qué supone guardar un servidor editado (lógica pura). Antes cualquier guardado
//  reconstruía el servicio y cerraba todos sus terminales y agentes, aunque solo se
//  hubiera cambiado el nombre.
//

import Foundation

enum ServerEditImpact {

    /// ¿Hace falta una conexión nueva? Solo si cambia a dónde o cómo se conecta: host,
    /// puerto, usuario, método, clave (ruta, acceso o passphrase) o el secreto guardado.
    /// `previous == nil` (servidor nuevo) siempre la necesita.
    static func requiresNewConnection(previous: Server?, updated: Server, secretChanged: Bool) -> Bool {
        guard let previous else { return true }
        if secretChanged { return true }
        return previous.host != updated.host
            || previous.port != updated.port
            || previous.username != updated.username
            || previous.authMethod != updated.authMethod
            || previous.privateKeyPath != updated.privateKeyPath
            || previous.privateKeyBookmark != updated.privateKeyBookmark
            || previous.requiresPassphrase != updated.requiresPassphrase
    }

    /// Normaliza un secreto para compararlo (vacío = sin secreto).
    static func normalizedSecret(_ secret: String?) -> String? {
        guard let secret, !secret.isEmpty else { return nil }
        return secret
    }

    /// ¿El secreto que se va a guardar es distinto del que ya había?
    static func secretChanged(stored: String?, new: String?) -> Bool {
        normalizedSecret(stored) != normalizedSecret(new)
    }
}

/// Lo que hay en marcha al salir de la app (para pedir confirmación).
struct QuitWorkInProgress: Equatable, Sendable {
    /// Conversaciones del panel de agente trabajando o esperando un permiso.
    let busyAgents: Int
    /// Envíos de proyectos al Mac o al servidor en curso.
    let runningSyncs: Int

    var needsConfirmation: Bool { busyAgents > 0 || runningSyncs > 0 }

    /// Texto de la confirmación (`nil` si no hace falta).
    var message: String? {
        guard needsConfirmation else { return nil }
        var parts: [String] = []
        if busyAgents > 0 {
            parts.append(String(localized: "\(busyAgents) agentes de Claude están trabajando"))
        }
        if runningSyncs > 0 {
            parts.append(String(localized: "hay \(runningSyncs) envíos en curso"))
        }
        let joined = parts.count == 2
            ? String(localized: "\(parts[0]) y \(parts[1])")
            : parts.joined()
        let summary = joined.prefix(1).uppercased() + joined.dropFirst()
        return String(localized: "\(summary). Si sales, se detendrán. Las sesiones de tmux del servidor siguen corriendo.")
    }
}
