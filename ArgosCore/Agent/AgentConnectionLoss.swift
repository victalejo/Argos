//
//  AgentConnectionLoss.swift
//  ArgosCore
//
//  Mensajes para cuando el vigilante de conexión cierra una conexión dedicada que dejó de
//  responder (`SSHConnectionError.connectionLost`) en medio de algo de Claude: el panel
//  Agente o el login guiado. «Se cortó la red» se explica distinto de un fallo de Claude,
//  porque lo que toca hacer es reconectar, no revisar nada.
//

import Foundation

enum AgentConnectionLoss {
    /// Conversación del panel cortada: el `claude` remoto murió con el canal.
    static let conversation =
        "Se perdió la conexión con el servidor (¿cambio de red o reposo?) y Claude se detuvo. "
        + "Pulsa «Reanudar conversación» para retomarla donde iba."

    /// Login guiado cortado a medias.
    static let login =
        "Se perdió la conexión con el servidor durante el inicio de sesión. "
        + "Vuelve a intentarlo cuando la red se recupere."

    /// `true` si el error es la conexión dedicada dada por perdida.
    static func isConnectionLost(_ error: Error?) -> Bool {
        guard let error = error as? SSHConnectionError else { return false }
        return error == .connectionLost
    }

    /// Texto para el fin de una conversación del panel.
    static func conversationMessage(for error: Error) -> String {
        isConnectionLost(error) ? conversation : error.userMessage
    }
}
