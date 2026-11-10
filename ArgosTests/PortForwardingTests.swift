//
//  PortForwardingTests.swift
//  ArgosTests
//
//  Reenvío de puertos: parser de `ss`/`netstat` y `PortForwardsModel` con el mock.
//

import Foundation
import Testing
@testable import Argos

@Suite("ListeningPortParser")
struct ListeningPortParserTests {

    @Test("ss -Htlnp: IPv4 + IPv6 del mismo puerto se funden y se queda el proceso")
    func ssWithProcesses() {
        let output = """
        LISTEN 0      511        0.0.0.0:3000       0.0.0.0:*    users:(("node",pid=812,fd=21))
        LISTEN 0      511           [::]:3000          [::]:*
        LISTEN 0      4096     127.0.0.53%lo:53         0.0.0.0:*
        LISTEN 0      128        0.0.0.0:22         0.0.0.0:*
        LISTEN 0      244      127.0.0.1:5432       0.0.0.0:*
        LISTEN 0      511       10.0.0.5:8080       0.0.0.0:*    users:(("python3",pid=9,fd=3))
        """
        let ports = ListeningPortParser.parse(output)
        #expect(ports.map(\.port) == [22, 53, 3000, 5432, 8080])
        let node = ports.first { $0.port == 3000 }
        #expect(node?.processName == "node")
        #expect(node?.targetHost == "localhost")
        #expect(ports.first { $0.port == 8080 }?.targetHost == "10.0.0.5")
        #expect(ports.filter(\.isLikelyDevServer).map(\.port) == [3000, 5432, 8080])
    }

    @Test("ss sin -H: la cabecera se ignora")
    func ssWithHeader() {
        let output = """
        State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
        LISTEN 0      511                *:5173            *:*
        """
        #expect(ListeningPortParser.parse(output).map(\.port) == [5173])
    }

    @Test("netstat -tln")
    func netstat() {
        let output = """
        Active Internet connections (only servers)
        Proto Recv-Q Send-Q Local Address           Foreign Address         State
        tcp        0      0 127.0.0.1:8000          0.0.0.0:*               LISTEN
        tcp6       0      0 :::4000                 :::*                    LISTEN
        tcp        0      0 10.0.0.2:9000           10.0.0.9:51000          ESTABLISHED
        """
        let ports = ListeningPortParser.parse(output)
        #expect(ports.map(\.port) == [4000, 8000])
        let allLocal = ports.allSatisfy { $0.targetHost == "localhost" }
        #expect(allLocal)
    }

    @Test("Direcciones con corchetes, interfaz y comodín", arguments: [
        ("[::1]:3000", "::1", 3000),
        ("*:80", "*", 80),
        ("127.0.0.53%lo:53", "127.0.0.53", 53),
        (":::4000", "::", 4000),
    ])
    func splitHostPort(value: String, host: String, port: Int) {
        let parsed = ListeningPortParser.splitHostPort(value)
        #expect(parsed?.0 == host)
        #expect(parsed?.1 == port)
    }

    @Test("Puertos inválidos se descartan")
    func invalid() {
        #expect(ListeningPortParser.splitHostPort("0.0.0.0:0") == nil)
        #expect(ListeningPortParser.splitHostPort("0.0.0.0:99999") == nil)
        #expect(ListeningPortParser.splitHostPort("sin-puerto") == nil)
    }

    @Test("El comando corre bajo sh")
    func command() {
        #expect(ListeningPortParser.command.hasPrefix("sh -c '"))
    }
}

@MainActor
@Suite("PortForwardsModel")
struct PortForwardsModelTests {

    private static let web = ListeningPort(port: 3000, targetHost: "localhost", processName: "node")
    private static let dns = ListeningPort(port: 53, targetHost: "localhost", processName: nil)

    @Test("Carga puertos y oculta los de sistema")
    func loads() async {
        let mock = MockSSHService()
        mock.listening = [Self.dns, Self.web]
        let model = PortForwardsModel(service: mock)
        await model.refresh()
        #expect(model.hasLoaded)
        #expect(model.visiblePorts == [Self.web])
        #expect(model.hiddenSystemPortCount == 1)
        model.showsSystemPorts = true
        #expect(model.visiblePorts.count == 2)
    }

    @Test("Abre el túnel en el mismo puerto o en otro si está ocupado")
    func startsForward() async {
        let mock = MockSSHService()
        mock.listening = [Self.web]
        mock.busyLocalPorts = [3000]
        let model = PortForwardsModel(service: mock)
        await model.refresh()
        let forward = await model.start(Self.web)
        #expect(forward?.remotePort == 3000)
        #expect(forward?.localPort == 3001)
        #expect(forward?.localURL?.absoluteString == "http://localhost:3001")
        #expect(model.forward(forRemotePort: 3000) == forward)
        // Pedirlo otra vez devuelve el mismo túnel, no abre otro.
        let again = await model.start(Self.web)
        #expect(again == forward)
        #expect(mock.forwards.count == 1)
    }

    @Test("Cerrar el túnel")
    func stops() async {
        let mock = MockSSHService()
        let model = PortForwardsModel(service: mock)
        let forward = await model.startManual("8080")
        #expect(forward != nil)
        await model.stop(forward!)
        #expect(model.forwards.isEmpty)
        #expect(mock.forwards.isEmpty)
    }

    @Test("Puerto manual inválido y error del servicio")
    func errors() async {
        let mock = MockSSHService()
        let model = PortForwardsModel(service: mock)
        #expect(await model.startManual("abc") == nil)
        #expect(model.errorMessage != nil)
        model.errorMessage = nil
        mock.forwardError = PortForwardError.bindFailed("ocupado")
        #expect(await model.startManual("3000") == nil)
        #expect(model.errorMessage?.contains("ocupado") == true)
        #expect(model.busyPorts.isEmpty)
    }

    @Test("Validación de puertos", arguments: [("3000", 3000), (" 80 ", 80), ("0", nil), ("70000", nil), ("x", nil)] as [(String, Int?)])
    func parsePort(text: String, expected: Int?) {
        #expect(PortForwardsModel.parsePort(text) == expected)
    }
}
