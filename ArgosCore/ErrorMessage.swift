//
//  ErrorMessage.swift
//  Argos
//
//  Punto único de verdad para convertir un Error en texto de UI. Antes este
//  patrón estaba duplicado en 6 sitios; centralizarlo evita que una variante
//  quede inconsistente.
//
//  Los errores de transporte (Citadel, NIOSSH, NIO, SFTP) no son `LocalizedError`: sin
//  traducirlos llegaban a la UI como «(Citadel.SSHClientError error 3)».
//

import Foundation
@preconcurrency import Citadel
import NIOCore
import NIOPosix
import NIOSSH

extension Error {
    /// Mensaje legible para mostrar al usuario: prioriza `errorDescription` de
    /// `LocalizedError`; si no, cae a `localizedDescription`.
    var userMessage: String {
        if let transport = SSHErrorMessage.transportText(for: self) { return transport }
        return (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }
}

/// Traducción de los errores de transporte a mensajes accionables.
enum SSHErrorMessage {

    static let authenticationRejected =
        String(localized: "El servidor rechazó la contraseña o la clave. Revisa las credenciales del servidor (Editar servidor) y vuelve a conectar.")
    static let connectionClosed = String(localized: "Se cerró la conexión SSH con el servidor. Reintenta.")
    static let timedOut =
        String(localized: "Tiempo de espera agotado: el servidor no respondió. Comprueba tu conexión a internet y que el servidor esté encendido.")

    /// `nil` si el error no es de transporte (se usa su descripción normal).
    static func transportText(for error: Error) -> String? {
        switch error {
        case let ssh as NIOSSHError:
            return text(for: ssh.type, detail: String(describing: ssh))
        case let client as SSHClientError:
            return text(for: client)
        case is AuthenticationFailed:
            return authenticationRejected
        case let citadel as CitadelError:
            return text(for: citadel)
        case let connection as NIOConnectionError:
            return connectionFailure(
                host: connection.host, port: connection.port,
                dnsFailed: connection.dnsAError != nil || connection.dnsAAAAError != nil,
                refused: connection.connectionErrors.contains { isRefused($0.error) }
            )
        case let channel as ChannelError:
            return text(for: channel)
        case let io as IOError:
            return text(for: io)
        case let sftp as SFTPError:
            return text(for: sftp)
        case let status as SFTPMessage.Status:
            return sftpStatus(status.errorCode, message: status.message)
        default:
            return nil
        }
    }

    /// `NIOSSHError` es un struct: su `localizedDescription` solo dice «Error 1», que no
    /// ayuda a nadie. Se traduce a algo accionable según su tipo.
    static func text(for type: NIOSSHError.ErrorType, detail: String) -> String {
        switch type {
        case .channelSetupRejected:
            return String(localized: "El servidor rechazó abrir un canal SSH nuevo (¿demasiados canales abiertos en la conexión?). Reintenta en unos segundos. (\(detail))")
        case .tcpShutdown, .creatingChannelAfterClosure:
            return String(localized: "Se cortó la conexión SSH con el servidor. Reintenta. (\(detail))")
        default:
            return String(localized: "Error SSH: \(detail)")
        }
    }

    static func text(for error: SSHClientError) -> String {
        switch error {
        case .allAuthenticationOptionsFailed:
            return authenticationRejected
        case .unsupportedPasswordAuthentication:
            return String(localized: "El servidor no admite iniciar sesión con contraseña. Configura una clave SSH para este servidor.")
        case .unsupportedPrivateKeyAuthentication:
            return String(localized: "El servidor no admite iniciar sesión con clave. Usa contraseña o revisa su configuración de sshd.")
        case .unsupportedHostBasedAuthentication:
            return String(localized: "El servidor no admite este método de inicio de sesión. Revisa la configuración del servidor.")
        case .channelCreationFailed:
            return String(localized: "No se pudo abrir un canal SSH en el servidor. Reintenta en unos segundos.")
        }
    }

    static func text(for error: CitadelError) -> String {
        switch error {
        case .unauthorized:
            return authenticationRejected
        case .channelCreationFailed, .channelFailure:
            return String(localized: "El servidor no abrió el canal SSH a tiempo (¿muy cargado?). Reintenta en unos segundos.")
        case .commandOutputTooLarge:
            return String(localized: "La salida del comando remoto es demasiado grande.")
        default:
            return String(localized: "Fallo de cifrado o de protocolo en la conexión SSH (\(error)). Reintenta; si persiste, revisa la configuración del servidor.")
        }
    }

    /// No se llegó a conectar con `host:port`.
    static func connectionFailure(host: String, port: Int, dnsFailed: Bool, refused: Bool) -> String {
        if dnsFailed {
            return String(localized: "No se encontró el servidor «\(host)». Revisa la dirección y tu conexión a internet.")
        }
        if refused {
            return String(localized: "\(host) rechazó la conexión en el puerto \(String(port)). Comprueba el puerto y que el servicio SSH esté en marcha.")
        }
        return String(localized: "No se pudo conectar con \(host):\(String(port)). Comprueba que el servidor esté encendido y accesible, y tu conexión a internet.")
    }

    static func text(for error: ChannelError) -> String {
        switch error {
        case .connectTimeout:
            return timedOut
        case .ioOnClosedChannel, .alreadyClosed, .eof, .outputClosed, .inputClosed:
            return connectionClosed
        case .writeHostUnreachable:
            return String(localized: "No hay ruta hasta el servidor. Comprueba tu conexión a internet.")
        default:
            return String(localized: "Error de conexión con el servidor (\(error)). Reintenta.")
        }
    }

    static func text(for error: IOError) -> String {
        switch error.errnoCode {
        case ECONNREFUSED:
            return String(localized: "El servidor rechazó la conexión. Comprueba el puerto y que el servicio SSH esté en marcha.")
        case ECONNRESET, EPIPE, ENOTCONN:
            return connectionClosed
        case ETIMEDOUT:
            return timedOut
        case ENETUNREACH, EHOSTUNREACH, ENETDOWN:
            return String(localized: "No hay ruta hasta el servidor. Comprueba tu conexión a internet.")
        default:
            return String(localized: "Error de red: \(error.description)")
        }
    }

    static func text(for error: SFTPError) -> String {
        switch error {
        case .connectionClosed:
            return connectionClosed
        case .errorStatus(let status):
            return sftpStatus(status.errorCode, message: status.message)
        default:
            return String(localized: "El servidor respondió de forma inesperada a una operación de archivos (\(error)). Reintenta.")
        }
    }

    /// Estado de error de SFTP (archivo inexistente, permiso denegado…).
    static func sftpStatus(_ code: SFTPStatusCode, message: String) -> String {
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.isEmpty ? "" : " (\(detail))"
        switch code {
        case .noSuchFile:
            return String(localized: "El archivo o la carpeta no existe en el servidor.") + suffix
        case .permissionDenied:
            return String(localized: "Permiso denegado en el servidor: tu usuario no puede acceder a ese archivo o carpeta.") + suffix
        case .noConnection, .connectionLost:
            return connectionClosed
        case .unsupportedOperation:
            return String(localized: "El servidor no admite esa operación de archivos.") + suffix
        case .eof:
            return String(localized: "El archivo terminó antes de lo esperado.") + suffix
        default:
            return String(localized: "El servidor no pudo completar la operación de archivos.") + suffix
        }
    }

    private static func isRefused(_ error: Error) -> Bool {
        (error as? IOError)?.errnoCode == ECONNREFUSED
    }
}
