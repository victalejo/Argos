//
//  IntegrationKeysTimeoutTests.swift
//  ArgosTests
//
//  Claves autorizadas (`authorizeKeyCommand` / `revokeKeyCommand`) y plazo remoto
//  (`RemoteTimeout`, `timeout` de coreutils) contra un servidor real. `~/.ssh` es el del
//  HOME AISLADO del servidor de pruebas: el sshd de pruebas no lo usa para autenticar.
//

import Foundation
import Testing
@testable import Argos

extension IntegrationServerSuites {

@Suite("Claves autorizadas y plazo remoto")
struct KeysAndTimeout {

    private static let keysFile = "$HOME/.ssh/authorized_keys"

    private func deviceKeyLine(_ suffix: String) -> String {
        let blob = Data((0..<51).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ suffix.count) }).base64EncodedString()
        return "ssh-ed25519 \(blob) \(AuthorizedDeviceKey.commentPrefix)20261118-\(suffix)"
    }

    @Test("authorize: sin archivo, con y sin salto final; revoke solo quita la suya", .timeLimit(.minutes(1)))
    func authorizeAndRevoke() async throws {
        let box = try await RemoteBox.open("keys")
        defer { IntegrationCleanup.later { await box.close() } }
        try await box.sh("rm -rf \"$HOME/.ssh\"")

        // 1) Sin ~/.ssh: se crea (700) con el archivo (600).
        try await box.service.authorizeKey(line: deviceKeyLine("aaaa1111"))
        let perms = try await box.sh("ls -ld \"$HOME/.ssh\" \(Self.keysFile) | cut -c1-10")
        #expect(perms.split(separator: "\n").map(String.init) == ["drwx------", "-rw-------"])

        // 2) Archivo SIN salto final (editado a mano): la clave nueva va en su propia línea.
        try await box.sh("printf '%s' 'ssh-ed25519 AAAAmanual usuario@portatil' > \(Self.keysFile)")
        try await box.service.authorizeKey(line: deviceKeyLine("bbbb2222"))
        // 3) Con salto final: no se añade una línea vacía.
        try await box.service.authorizeKey(line: deviceKeyLine("cccc3333"))
        let lines = try await box.sh("cat \(Self.keysFile)").split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 4 && lines.last == "", "Tres líneas y salto final: \(lines)")
        #expect(lines.first == "ssh-ed25519 AAAAmanual usuario@portatil")

        let listed = try await box.service.listAuthorizedDeviceKeys().map(\.comment)
        #expect(listed == ["\(AuthorizedDeviceKey.commentPrefix)20261118-bbbb2222", "\(AuthorizedDeviceKey.commentPrefix)20261118-cccc3333"])

        try await box.service.revokeKey(comment: "\(AuthorizedDeviceKey.commentPrefix)20261118-bbbb2222")
        let after = try await box.sh("cat \(Self.keysFile)")
        #expect(after.contains("AAAAmanual") && after.contains("cccc3333") && !after.contains("bbbb2222"))
        try await box.sh("rm -rf \"$HOME/.ssh\"")
    }

    @Test("Plazo remoto: con `timeout`, un comando colgado muere a tiempo (124) y no deja procesos",
          .timeLimit(.minutes(1)))
    func remoteTimeoutKillsHungCommand() async throws {
        let box = try await RemoteBox.open("timeout")
        defer { IntegrationCleanup.later { await box.close() } }
        let marker = "argos-it-hang-\(UUID().uuidString.prefix(8))"
        let start = ContinuousClock.now
        let output = try await box.run(RemoteTimeout.wrap("exec sh -c 'sleep 30' \(marker)", seconds: 2))
        let elapsed = ContinuousClock.now - start
        if try await box.has("timeout") {
            #expect(output.exitCode == RemoteTimeout.expiredExitCode)
            #expect(elapsed < .seconds(15))
            let left = try await box.sh("ps -eo args= | grep -F -- '\(marker)' | grep -v grep; true")
            #expect(left.isEmpty, "El comando colgado sigue vivo: \(left)")
        } else {
            // Sin `timeout` (macOS sin coreutils): el comando corre tal cual hasta el final.
            #expect(output.exitCode == 0)
        }
    }

    @Test("Plazo remoto ante un comando que ignora TERM: KILL a los 5 s (`-k 5`)",
          .enabled(if: IntegrationRemote.isLinux, IntegrationRemote.linuxOnly), .timeLimit(.minutes(1)))
    func remoteTimeoutEscalatesToKill() async throws {
        let box = try await RemoteBox.open("timeout-kill")
        defer { IntegrationCleanup.later { await box.close() } }
        let start = ContinuousClock.now
        let output = try await box.run(RemoteTimeout.wrap("trap '' TERM; exec sleep 30", seconds: 1))
        #expect(output.exitCode == 137 || output.exitCode == RemoteTimeout.expiredExitCode)
        #expect(ContinuousClock.now - start < .seconds(15))

        // Con NIETOS que ignoran TERM, el `timeout` de uutils (Ubuntu ≥ 25.10) manda el KILL
        // solo a su hijo directo, no al grupo como el de GNU: el nieto sigue vivo y mantiene
        // abierto el canal hasta que termina. Se documenta aquí (ver informe de integración).
        let flavor = try await box.sh("timeout --version 2>/dev/null | head -n 1; true")
        let grandchild = ContinuousClock.now
        _ = try await box.run(RemoteTimeout.wrap("trap '' TERM; sleep 12; true", seconds: 1))
        let lasted = ContinuousClock.now - grandchild
        if flavor.contains("uutils") {
            withKnownIssue("uutils timeout -k no mata al grupo con KILL", isIntermittent: true) {
                #expect(lasted < .seconds(10))
            }
        } else {
            #expect(lasted < .seconds(10), "GNU timeout -k debe matar al grupo")
        }
    }

    @Test("Un sondeo envuelto (claudeActivity, listSessions) responde aunque tmux no esté arrancado",
          .timeLimit(.minutes(1)))
    func wrappedPollsWork() async throws {
        let box = try await RemoteBox.open("timeout-polls")
        defer { IntegrationCleanup.later { await box.close() } }
        guard try await box.has("tmux") else { return }
        _ = try await box.service.listSessions()
        _ = try await box.service.claudeActivity()
    }
}

}
