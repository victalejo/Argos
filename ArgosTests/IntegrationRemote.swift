//
//  IntegrationRemote.swift
//  ArgosTests
//
//  Ayudantes de las pruebas de integración que ejercitan los SCRIPTS REMOTOS de Argos
//  contra un servidor de verdad (`IntegrationServerSuites`): el sshd temporal local de
//  macOS (CI) o un Linux real (Debian/Ubuntu, `sh` = dash) por un túnel. Todo lo que se
//  comprueba en el servidor se hace POR SSH (nunca con el sistema de archivos local), así
//  que las mismas pruebas valen para los dos.
//
//  Además de las variables de `IntegrationSSHD`, `ARGOS_E2E_SERVER_OS` (`uname -s` del
//  servidor, lo imprime `sshd-test-start.sh`) activa las pruebas que solo tienen sentido
//  en Linux (`setsid`, `timeout`, `/proc`, `find -printf` de GNU).
//
//  Para ejecutarlas contra un Linux remoto (ver `scripts/sshd-test-start.sh`):
//    ssh servidor 'scripts/sshd-test-start.sh --port 42817 --dir ~/it/sshd'
//    scp servidor:it/sshd/user_key /tmp/k && ssh -N -L 127.0.0.1:42817:127.0.0.1:42817 servidor &
//    TEST_RUNNER_ARGOS_E2E_SSH_HOST=127.0.0.1 TEST_RUNNER_ARGOS_E2E_SSH_PORT=42817 \
//    TEST_RUNNER_ARGOS_E2E_SSH_USER=<usuario> TEST_RUNNER_ARGOS_E2E_SSH_KEY=/tmp/k \
//    TEST_RUNNER_ARGOS_E2E_SERVER_OS=Linux xcodebuild test … -only-testing:ArgosTests/IntegrationServerSuites
//  (sin `ARGOS_E2E_SSHD_DIR`: las pruebas que miran el disco local se saltan solas).
//

import Foundation
import Testing
@testable import Argos

/// Contenedor de TODAS las suites de scripts remotos: en serie entre sí (comparten el
/// HOME aislado, el servidor tmux y `~/.config/argos`), y solo con servidor de pruebas.
@Suite("Integración: scripts remotos (servidor real)", .enabled(if: IntegrationSSHD.enabled), .serialized)
struct IntegrationServerSuites {}

enum IntegrationRemote {
    static var serverOS: String { IntegrationSSHD.env["ARGOS_E2E_SERVER_OS"] ?? "" }
    static var isLinux: Bool { serverOS == "Linux" }
    static let linuxOnly: Comment = "Solo en Linux (setsid / timeout / procps / GNU find); en macOS no aplica"
}

/// Error de un ayudante (mensaje para el informe del test).
struct IntegrationFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Conexión de prueba + una carpeta propia y vacía en el servidor (`root`), que se borra
/// al cerrar. `home` es el HOME (aislado) de las sesiones del servidor de pruebas.
struct RemoteBox: Sendable {
    let service: SSHService
    let home: String
    let root: String

    static func open(_ label: String) async throws -> RemoteBox {
        // La limpieza del test anterior (diferida) termina antes de empezar este.
        await IntegrationCleanup.drain()
        IntegrationSSHD.forgetHostKey()
        let service = IntegrationSSHD.service()
        let home = try await service.runAgentScript("printf '%s' \"$HOME\"")
        guard home.hasPrefix("/") else { throw IntegrationFailure("HOME remoto inesperado: \(home)") }
        let root = "\(home)/it/\(label)-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await service.runAgentScript("mkdir -p \(ShellQuoting.singleQuoted(root))")
        return RemoteBox(service: service, home: home, root: root)
    }

    /// Borra la carpeta y desconecta.
    func close() async {
        _ = try? await service.runAgentScript("rm -rf \(ShellQuoting.singleQuoted(root))")
        await service.disconnect()
        IntegrationSSHD.forgetHostKey()
    }

    /// Script POSIX (`sh -c`) en el servidor; lanza si sale con error.
    @discardableResult
    func sh(_ script: String) async throws -> String {
        try await service.runAgentScript(script)
    }

    /// Salida completa (sin lanzar por el código de salida).
    func run(_ command: String, timeout: CommandTimeout = .standard) async throws -> CommandOutput {
        try await service.run(command, timeout: timeout)
    }

    /// Escribe `text` tal cual en `path` (absoluta o relativa a `root`), vía base64.
    func write(_ text: String, to path: String) async throws {
        try await writeData(Data(text.utf8), to: path)
    }

    func writeData(_ data: Data, to path: String) async throws {
        let target = absolute(path)
        try await sh("mkdir -p \"$(dirname \(q(target)))\"")
        if data.count <= 32 * 1024 {
            try await sh("printf '%s' '\(data.base64EncodedString())' | base64 -d > \(q(target))")
        } else {
            _ = try await service.upload(data: data, toRemotePath: target)
        }
    }

    /// Contenido de `path` (vacío si no existe).
    func read(_ path: String) async throws -> String {
        try await sh("cat \(q(absolute(path))) 2>/dev/null; true")
    }

    func exists(_ path: String) async throws -> Bool {
        try await sh("if [ -e \(q(absolute(path))) ] || [ -L \(q(absolute(path))) ]; then echo si; fi")
            .contains("si")
    }

    func has(_ tool: String) async throws -> Bool {
        try await sh("command -v \(q(tool)) >/dev/null 2>&1 && echo si; true").contains("si")
    }

    func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : "\(root)/\(path)"
    }

    func q(_ value: String) -> String { ShellQuoting.singleQuoted(value) }
}

/// Limpiezas que un `defer` no puede esperar (son asíncronas): se lanzan al salir del test
/// y el siguiente `RemoteBox.open` las espera, así dos pruebas nunca se pisan.
final class IntegrationCleanup: @unchecked Sendable {
    private static let shared = IntegrationCleanup()
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    static func later(_ body: @escaping @Sendable () async -> Void) {
        let task = Task { await body() }
        shared.lock.lock()
        shared.tasks.append(task)
        shared.lock.unlock()
    }

    static func drain() async {
        for task in takePending() { await task.value }
    }

    private static func takePending() -> [Task<Void, Never>] {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        let pending = shared.tasks
        shared.tasks.removeAll()
        return pending
    }
}

/// Espera (sondeando) hasta que `condition` se cumpla o venza el plazo. Devuelve si se cumplió.
@discardableResult
func eventually(
    seconds: Double, every interval: Duration = .milliseconds(250), _ condition: () async throws -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try await Task.sleep(for: interval)
    }
    return try await condition()
}
