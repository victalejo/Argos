//
//  SSHDirectoryAccessTests.swift
//  ArgosTests
//
//  Acceso a ~/.ssh sin la excepción temporal de sandbox (canal App Store): las rutas
//  con `~` se expanden al home POSIX real, solo las rutas DENTRO de ~/.ssh usan el
//  permiso concedido, y el estado decide si hay que pedir acceso al usuario.
//

import Foundation
import Testing
@testable import Argos

@Suite("Acceso a ~/.ssh (bookmark de carpeta)")
struct SSHDirectoryAccessTests {

    private let home = "/Users/ana"

    // MARK: - Expansión de ~

    @Test("~/ruta se expande al home real")
    func expandsTilde() {
        #expect(SSHDirectoryAccess.expandTilde("~/.ssh/id_ed25519", home: home) == "/Users/ana/.ssh/id_ed25519")
    }

    @Test("~ solo es el home")
    func expandsBareTilde() {
        #expect(SSHDirectoryAccess.expandTilde("~", home: home) == "/Users/ana")
    }

    @Test("Rutas absolutas y ~usuario no se tocan")
    func leavesOthersAlone() {
        #expect(SSHDirectoryAccess.expandTilde("/etc/ssh/key", home: home) == "/etc/ssh/key")
        #expect(SSHDirectoryAccess.expandTilde("~otro/.ssh/key", home: home) == "~otro/.ssh/key")
    }

    // MARK: - ¿Está dentro de ~/.ssh?

    @Test("Archivos dentro de ~/.ssh (también con ~ y subcarpetas)", arguments: [
        "/Users/ana/.ssh/id_ed25519",
        "~/.ssh/config",
        "/Users/ana/.ssh/keys/prod",
        "/Users/ana/.ssh",
    ])
    func insideSSHDirectory(path: String) {
        #expect(SSHDirectoryAccess.isInsideSSHDirectory(path, home: home))
    }

    @Test("Rutas fuera de ~/.ssh, prefijos engañosos y escapes con ..", arguments: [
        "/Users/ana/.sshfoo/id",
        "/Users/ana/Documents/id_ed25519",
        "/Users/ana/.ssh/../Documents/id",
        "/Users/otro/.ssh/id_ed25519",
        "",
    ])
    func outsideSSHDirectory(path: String) {
        #expect(!SSHDirectoryAccess.isInsideSSHDirectory(path, home: home) )
    }

    // MARK: - Estado

    @Test("Con permiso concedido el estado es .granted aunque el sandbox no deje leer")
    func grantedWins() {
        #expect(SSHDirectoryAccess.status(hasGrant: true, directoryReadable: false) == .granted)
    }

    @Test("Sin permiso pero legible (canal GitHub, excepción de sandbox) es .implicit")
    func implicitWhenReadable() {
        #expect(SSHDirectoryAccess.status(hasGrant: false, directoryReadable: true) == .implicit)
    }

    @Test("Sin permiso y sin poder leer (canal App Store) hay que pedirlo")
    func needsGrant() {
        #expect(SSHDirectoryAccess.status(hasGrant: false, directoryReadable: false) == .needsGrant)
    }

    // MARK: - Persistencia del permiso

    @Test("Sin bookmark guardado no hay permiso; revocar lo borra")
    func grantStorage() throws {
        let suite = "argos.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!SSHDirectoryAccess.hasGrant(defaults: defaults))
        defaults.set(Data([1, 2, 3]), forKey: SSHDirectoryAccess.bookmarkKey)
        #expect(SSHDirectoryAccess.hasGrant(defaults: defaults))
        SSHDirectoryAccess.revoke(defaults: defaults)
        #expect(!SSHDirectoryAccess.hasGrant(defaults: defaults))
    }

    @Test("Sin permiso, withAccess ejecuta el bloque leyendo directamente")
    func withAccessWithoutGrant() throws {
        let suite = "argos.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let value = SSHDirectoryAccess.withAccess(defaults: defaults) { 42 }
        #expect(value == 42)
    }

    // MARK: - Mensaje de error de clave ilegible

    @Test("Clave en ~/.ssh ilegible y sin permiso: el mensaje explica cómo concederlo")
    func keyErrorHintsAtGrant() {
        let hint = SSHDirectoryAccess.unreadableKeyHint(path: "~/.ssh/id_ed25519", hasGrant: false, home: home)
        #expect(hint?.contains("Ajustes") == true)
    }

    @Test("Con permiso o fuera de ~/.ssh no se añade la pista")
    func noHintOtherwise() {
        #expect(SSHDirectoryAccess.unreadableKeyHint(path: "~/.ssh/id", hasGrant: true, home: home) == nil)
        #expect(SSHDirectoryAccess.unreadableKeyHint(path: "/tmp/id", hasGrant: false, home: home) == nil)
    }
}
