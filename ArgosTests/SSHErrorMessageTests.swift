//
//  SSHErrorMessageTests.swift
//  ArgosTests
//
//  Los NIOSSHError se explican en vez de mostrar «Error de NIOSSH.NIOSSHError 1».
//

import Foundation
import NIOCore
import NIOSSH
import Testing
@preconcurrency import Citadel
@testable import Argos

@Suite("Mensajes de errores SSH")
struct SSHErrorMessageTests {

    @Test("Canal rechazado sugiere demasiados canales y reintentar")
    func channelRejected() {
        let text = SSHErrorMessage.text(for: .channelSetupRejected, detail: "d")
        #expect(text.contains("rechazó abrir un canal"))
        #expect(text.contains("Reintenta"))
    }

    @Test("Conexión cortada")
    func connectionLost() {
        #expect(SSHErrorMessage.text(for: .tcpShutdown, detail: "d").contains("Se cortó la conexión"))
        #expect(SSHErrorMessage.text(for: .creatingChannelAfterClosure, detail: "d").contains("Se cortó la conexión"))
    }

    @Test("Otros tipos muestran el detalle, nunca «Error 1»")
    func otherTypes() {
        let text = SSHErrorMessage.text(for: .protocolViolation, detail: "NIOSSHError.protocolViolation")
        #expect(text == "Error SSH: NIOSSHError.protocolViolation")
    }

    // MARK: - Transporte (Citadel, NIO, SFTP)

    @Test("Contraseña o clave rechazada")
    func authenticationRejected() {
        for error: Error in [SSHClientError.allAuthenticationOptionsFailed, CitadelError.unauthorized] {
            #expect(error.userMessage == SSHErrorMessage.authenticationRejected)
        }
        #expect(SSHErrorMessage.authenticationRejected.contains("rechazó la contraseña o la clave"))
        #expect(SSHClientError.unsupportedPasswordAuthentication.userMessage.contains("no admite iniciar sesión con contraseña"))
    }

    @Test("Servidor inaccesible: DNS, puerto cerrado o sin respuesta")
    func unreachable() {
        #expect(SSHErrorMessage.connectionFailure(host: "srv", port: 22, dnsFailed: true, refused: false)
            .contains("No se encontró el servidor «srv»"))
        #expect(SSHErrorMessage.connectionFailure(host: "srv", port: 2222, dnsFailed: false, refused: true)
            .contains("rechazó la conexión en el puerto 2222"))
        #expect(SSHErrorMessage.connectionFailure(host: "srv", port: 22, dnsFailed: false, refused: false)
            .contains("No se pudo conectar con srv:22"))
        #expect(IOError(errnoCode: ECONNREFUSED, reason: "connect").userMessage.contains("rechazó la conexión"))
        #expect(IOError(errnoCode: ENETUNREACH, reason: "connect").userMessage.contains("No hay ruta"))
    }

    @Test("Tiempo de espera agotado")
    func timeouts() {
        #expect(ChannelError.connectTimeout(.seconds(30)).userMessage == SSHErrorMessage.timedOut)
        #expect(IOError(errnoCode: ETIMEDOUT, reason: "read").userMessage == SSHErrorMessage.timedOut)
        #expect(SSHConnectionError.commandTimedOut(.seconds(90)).userMessage.contains("no terminó en 90 s"))
    }

    @Test("Conexión cerrada")
    func closed() {
        for error: Error in [ChannelError.ioOnClosedChannel, ChannelError.alreadyClosed, ChannelError.eof,
                             IOError(errnoCode: ECONNRESET, reason: "read"), SFTPError.connectionClosed] {
            #expect(error.userMessage == SSHErrorMessage.connectionClosed)
        }
        #expect(SSHConnectionError.connectionLost.userMessage.contains("dejó de responder"))
    }

    @Test("SFTP: archivo inexistente y permiso denegado")
    func sftpStatus() {
        #expect(SSHErrorMessage.sftpStatus(.noSuchFile, message: "No such file").contains("no existe en el servidor"))
        #expect(SSHErrorMessage.sftpStatus(.noSuchFile, message: "No such file").contains("(No such file)"))
        #expect(SSHErrorMessage.sftpStatus(.permissionDenied, message: "").contains("Permiso denegado"))
        #expect(SSHErrorMessage.sftpStatus(.connectionLost, message: "") == SSHErrorMessage.connectionClosed)
        #expect(SSHErrorMessage.sftpStatus(.failure, message: " ").hasSuffix("operación de archivos."))
    }

    @Test("Nunca «(Citadel.… error N)»")
    func neverRawCitadel() {
        for error: Error in [SSHClientError.channelCreationFailed, CitadelError.channelFailure,
                             CitadelError.invalidMac, SFTPError.invalidResponse] {
            #expect(!error.userMessage.contains("error 0"))
            #expect(!error.userMessage.contains("Citadel."))
        }
    }

    @Test("Los errores propios conservan su descripción")
    func localizedUntouched() {
        #expect(SSHService.SSHServiceError.tmuxNotInstalled.userMessage == "tmux no está instalado en el servidor.")
    }
}
