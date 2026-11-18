//
//  SSHErrorMessageTests.swift
//  ArgosTests
//
//  Los NIOSSHError se explican en vez de mostrar «Error de NIOSSH.NIOSSHError 1».
//

import NIOSSH
import Testing
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
}
