//
//  SSHConfigParserTests.swift
//  ArgosTests
//

import Testing
@testable import Argos

@Suite("SSHConfigParser")
struct SSHConfigParserTests {

    private let sample = """
    # comentario
    Host dev
        HostName 100.86.237.26
        User victalejo
        Port 2222
        IdentityFile ~/.ssh/id_ed25519

    Host victalejo
      HostName 10.0.0.5
      User victalejo
      IdentityFile ~/.ssh/alelink_server
      IdentitiesOnly yes

    Host github.com
      IdentityFile ~/.ssh/id_ed25519_bitbucket

    Host *
      ForwardAgent yes
    """

    @Test("Parsea todos los bloques Host")
    func parsesBlocks() {
        let hosts = SSHConfigParser.parse(sample)
        #expect(hosts.count == 4)
        #expect(hosts.map(\.alias) == ["dev", "victalejo", "github.com", "*"])
    }

    @Test("Extrae HostName/User/Port/IdentityFile del bloque correcto")
    func extractsFields() throws {
        let hosts = SSHConfigParser.parse(sample)
        let dev = try #require(hosts.first { $0.alias == "dev" })
        #expect(dev.hostName == "100.86.237.26")
        #expect(dev.user == "victalejo")
        #expect(dev.port == 2222)
        #expect(dev.identityFile == "~/.ssh/id_ed25519")
        #expect(dev.effectiveHost == "100.86.237.26")
    }

    @Test("Sin HostName, effectiveHost es el alias")
    func effectiveHostFallsBackToAlias() throws {
        let hosts = SSHConfigParser.parse(sample)
        let gh = try #require(hosts.first { $0.alias == "github.com" })
        #expect(gh.hostName == nil)
        #expect(gh.effectiveHost == "github.com")
    }

    @Test("Detecta comodines")
    func detectsWildcard() throws {
        let hosts = SSHConfigParser.parse(sample)
        let star = try #require(hosts.first { $0.alias == "*" })
        #expect(star.isWildcard)
        #expect(hosts.first { $0.alias == "dev" }?.isWildcard == false)
    }

    @Test("Tolera indentación variable, '=' y comillas")
    func toleratesFormatting() throws {
        let cfg = """
        Host servidor
        Port=2200
        User = "mi usuario"
        HostName\tejemplo.com
        """
        let hosts = SSHConfigParser.parse(cfg)
        let h = try #require(hosts.first)
        #expect(h.port == 2200)
        #expect(h.user == "mi usuario")
        #expect(h.hostName == "ejemplo.com")
    }

    @Test("Texto vacío => sin hosts")
    func empty() {
        #expect(SSHConfigParser.parse("").isEmpty)
        #expect(SSHConfigParser.parse("# solo comentarios\n\n").isEmpty)
    }
}
