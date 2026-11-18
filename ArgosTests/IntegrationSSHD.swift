//
//  IntegrationSSHD.swift
//  ArgosTests
//
//  Apoyo de las pruebas de integración contra un sshd REAL y temporal
//  (`scripts/sshd-test-start.sh`). Se activan solo si el entorno trae el servidor; con
//  xcodebuild las variables llevan el prefijo TEST_RUNNER_:
//
//    eval "$(scripts/sshd-test-start.sh --max-sessions 4 | sed 's/^/export TEST_RUNNER_/')"
//    xcodebuild test -scheme Argos -destination 'platform=macOS' \
//      -only-testing:ArgosTests/IntegrationSSHDTests CODE_SIGNING_ALLOWED=NO
//    scripts/sshd-test-stop.sh
//
//  Variables: ARGOS_E2E_SSH_HOST, _PORT, _USER, _KEY (clave Ed25519 sin passphrase),
//  ARGOS_E2E_SSH_MAX_SESSIONS (la `MaxSessions` con que arrancó el sshd) y
//  ARGOS_E2E_SSHD_DIR (directorio del sshd, para matarlo y reiniciarlo).
//

import Foundation
@testable import Argos

enum IntegrationSSHD {
    static let env = ProcessInfo.processInfo.environment

    static var enabled: Bool {
        env["ARGOS_E2E_SSH_HOST"] != nil && env["ARGOS_E2E_SSH_USER"] != nil
            && env["ARGOS_E2E_SSH_KEY"] != nil && env["ARGOS_E2E_SSH_PORT"] != nil
    }

    /// Hace falta además el directorio del sshd para poder matarlo y reiniciarlo.
    static var canRestart: Bool { enabled && env["ARGOS_E2E_SSHD_DIR"] != nil }

    /// El sshd corre en ESTA máquina (su directorio es local): solo entonces se puede mirar
    /// el resultado en el disco o en la tabla de procesos locales.
    static var isLocalServer: Bool {
        guard enabled, let dir = sshdDirectory else { return false }
        return FileManager.default.fileExists(atPath: dir + "/sshd_config")
    }

    static var host: String { env["ARGOS_E2E_SSH_HOST"] ?? "127.0.0.1" }
    static var port: Int { Int(env["ARGOS_E2E_SSH_PORT"] ?? "") ?? 22 }
    /// `MaxSessions` del sshd de prueba (10 es el valor por defecto de OpenSSH).
    static var maxSessions: Int { Int(env["ARGOS_E2E_SSH_MAX_SESSIONS"] ?? "") ?? 10 }
    static var sshdDirectory: String? { env["ARGOS_E2E_SSHD_DIR"] }

    static func server() -> Server {
        Server(
            name: "integration", host: host, port: port,
            username: env["ARGOS_E2E_SSH_USER"] ?? "", privateKeyPath: env["ARGOS_E2E_SSH_KEY"] ?? ""
        )
    }

    static func service() -> SSHService {
        SSHService(configuration: .init(server: server()))
    }

    /// La verificación TOFU guarda la huella en el `known_hosts.json` REAL de la app (no es
    /// inyectable): se olvida la del sshd de prueba antes y después para no dejar basura
    /// ni chocar con un puerto reutilizado por otro sshd temporal.
    static func forgetHostKey() {
        TOFUHostKeyValidator.forget(host: host, port: port)
    }

    // MARK: - Control del sshd

    enum ScriptError: Error, CustomStringConvertible {
        case failed(script: String, status: Int32, output: String)
        var description: String {
            switch self {
            case .failed(let script, let status, let output):
                return "\(script) terminó con \(status): \(output)"
            }
        }
    }

    /// Carpeta `scripts/` del repositorio (este archivo está en `ArgosTests/`).
    static var scriptsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts", isDirectory: true)
    }

    /// Ejecuta un script de `scripts/`. La salida va a un archivo (no a una tubería): el
    /// sshd se desacopla y, si heredara una tubería, la lectura no terminaría nunca.
    @discardableResult
    static func runScript(_ name: String, _ arguments: [String]) throws -> String {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("argos-it-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptsDirectory.appendingPathComponent(name).path] + arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()

        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            throw ScriptError.failed(script: name, status: process.terminationStatus, output: output)
        }
        return output
    }

    /// Mata el sshd (listener y sesiones, como una caída real) conservando su configuración.
    static func killServer() throws {
        guard let dir = sshdDirectory else { return }
        try runScript("sshd-test-stop.sh", ["--keep", dir])
    }

    /// Lo vuelve a arrancar con la misma clave de host y el mismo puerto.
    static func restartServer() throws {
        guard let dir = sshdDirectory else { return }
        try runScript("sshd-test-start.sh", ["--dir", dir])
    }

    // MARK: - Observación del servidor

    /// Canales SFTP abiertos ahora mismo: procesos `sftp-server` descendientes del sshd de
    /// prueba (cada canal SFTP lanza el suyo y termina al cerrarse el canal).
    static func openSFTPChannelCount() -> Int {
        guard let dir = sshdDirectory,
              let text = try? String(contentsOfFile: dir + "/sshd.pid", encoding: .utf8),
              let listener = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 0 }
        let rows = processTable()
        var descendants: Set<Int> = [listener]
        var grew = true
        while grew {
            grew = false
            for row in rows where descendants.contains(row.parent) && !descendants.contains(row.pid) {
                descendants.insert(row.pid)
                grew = true
            }
        }
        return rows.filter { descendants.contains($0.pid) && $0.command.contains("sftp-server") }.count
    }

    private struct ProcessRow { let pid: Int; let parent: Int; let command: String }

    private static func processTable() -> [ProcessRow] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int(parts[0]), let parent = Int(parts[1]) else { return nil }
            return ProcessRow(pid: pid, parent: parent, command: String(parts[2]))
        }
    }
}
