//
//  ErrorMessage.swift
//  Argos
//
//  Punto único de verdad para convertir un Error en texto de UI. Antes este
//  patrón estaba duplicado en 6 sitios; centralizarlo evita que una variante
//  quede inconsistente.
//

import Foundation
import NIOSSH

extension Error {
    /// Mensaje legible para mostrar al usuario: prioriza `errorDescription` de
    /// `LocalizedError`; si no, cae a `localizedDescription`.
    var userMessage: String {
        if let ssh = self as? NIOSSHError {
            return SSHErrorMessage.text(for: ssh.type, detail: String(describing: ssh))
        }
        return (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }
}

/// `NIOSSHError` es un struct: su `localizedDescription` solo dice «Error 1», que no
/// ayuda a nadie. Se traduce a algo accionable según su tipo.
enum SSHErrorMessage {
    static func text(for type: NIOSSHError.ErrorType, detail: String) -> String {
        switch type {
        case .channelSetupRejected:
            return "El servidor rechazó abrir un canal SSH nuevo (¿demasiados canales abiertos "
                + "en la conexión?). Reintenta en unos segundos. (\(detail))"
        case .tcpShutdown, .creatingChannelAfterClosure:
            return "Se cortó la conexión SSH con el servidor. Reintenta. (\(detail))"
        default:
            return "Error SSH: \(detail)"
        }
    }
}
