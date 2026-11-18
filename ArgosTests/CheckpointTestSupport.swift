//
//  CheckpointTestSupport.swift
//  ArgosTests
//
//  Repositorio git temporal (con su propio $HOME) para ejecutar DE VERDAD el script de
//  los puntos de restauración con /bin/sh o dash.
//

import Foundation
@testable import Argos

struct ShellRun {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

final class CheckpointRepo {
    let base: URL
    let home: URL
    let repo: URL
    let shell: String

    static var shells: [String] {
        ["/bin/sh", "/bin/dash"].filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `enabled`: `git config argos.checkpoints true` (sin él, el hook no hace nada).
    init(shell: String = "/bin/sh", name: String = "proyecto", enabled: Bool = true) throws {
        self.shell = shell
        base = try LocalShell.makeTemporaryDirectory()
        home = base.appendingPathComponent("home", isDirectory: true)
        repo = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init -q && git config user.email t@t && git config user.name Test && git config commit.gpgsign false")
        if enabled { try git("config argos.checkpoints true") }
    }

    deinit { LocalShell.remove(base) }

    var environment: [String: String] {
        var env = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                   "GIT_CONFIG_NOSYSTEM": "1"]
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] { env["DEVELOPER_DIR"] = developer }
        return env
    }

    /// Repositorio de los puntos del worktree principal.
    var store: URL { repo.appendingPathComponent(".git/\(CheckpointScript.storeName)") }

    /// Ejecuta `executable arguments…` en `cwd` (por defecto, el repo).
    @discardableResult
    func exec(_ executable: String, _ arguments: [String], stdin: String? = nil, cwd: URL? = nil,
              extraEnvironment: [String: String] = [:]) throws -> ShellRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment.merging(extraEnvironment) { _, new in new }
        process.currentDirectoryURL = cwd ?? repo
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        try process.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ShellRun(exitCode: process.terminationStatus,
                        stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Script de shell en el repo (para preparar el escenario). Lanza si falla.
    @discardableResult
    func sh(_ script: String, stdin: String? = nil, cwd: URL? = nil) throws -> ShellRun {
        let result = try exec("/bin/sh", ["-c", script], stdin: stdin, cwd: cwd)
        guard result.exitCode == 0 else {
            throw CheckpointError.failed("script de prueba: \(script)\n\(result.stderr)")
        }
        return result
    }

    @discardableResult
    func git(_ arguments: String) throws -> ShellRun { try sh("git " + arguments) }

    /// git sobre el repositorio de los puntos (`store`), que ve los objetos del principal.
    @discardableResult
    func storeGit(_ arguments: String, store: URL? = nil) throws -> ShellRun {
        try sh("git --git-dir=\(ShellQuoting.singleQuoted((store ?? self.store).path)) " + arguments)
    }

    /// Un modo del script con el shell de la prueba (sh o dash).
    @discardableResult
    func checkpoint(_ arguments: [String], cwd: URL? = nil, extraEnvironment: [String: String] = [:]) throws -> ShellRun {
        try exec(shell, ["-c", CheckpointScript.source, CheckpointScript.processName] + arguments,
                 cwd: cwd, extraEnvironment: extraEnvironment)
    }

    /// Simula el hook `UserPromptSubmit`: el script en `$HOME` y la entrada JSON por stdin.
    @discardableResult
    func hook(prompt: String = "Arregla el bug", session: String = "sesion-1", cwd: URL? = nil,
              extraEnvironment: [String: String] = [:]) throws -> ShellRun {
        try installScript()
        let json = try String(decoding: JSONSerialization.data(withJSONObject: [
            "session_id": session, "transcript_path": "/x/t.jsonl", "cwd": (cwd ?? repo).path,
            "permission_mode": "default", "hook_event_name": "UserPromptSubmit", "prompt": prompt,
        ], options: [.sortedKeys]), as: UTF8.self)
        let script = home.appendingPathComponent(CheckpointScript.installedRelativePath).path
        return try exec(shell, [script, "hook"], stdin: json, cwd: cwd, extraEnvironment: extraEnvironment)
    }

    /// Duración del hook en segundos.
    func timedHook(prompt: String = "hola") throws -> TimeInterval {
        let start = Date()
        try hook(prompt: prompt)
        return Date().timeIntervalSince(start)
    }

    func installScript() throws {
        let url = home.appendingPathComponent(CheckpointScript.installedRelativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CheckpointScript.source.write(to: url, atomically: true, encoding: .utf8)
    }

    func write(_ relativePath: String, _ content: String) throws {
        let url = repo.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: false, encoding: .utf8)
    }

    func read(_ relativePath: String) -> String? {
        try? String(contentsOf: repo.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: repo.appendingPathComponent(relativePath).path)
    }

    func remove(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: repo.appendingPathComponent(relativePath))
    }

    /// Commits de los puntos, del más reciente al más antiguo.
    func points(store: URL? = nil) throws -> [String] {
        let target = store ?? self.store
        guard FileManager.default.fileExists(atPath: target.appendingPathComponent("HEAD").path) else { return [] }
        return try storeGit("for-each-ref --sort=-refname --format='%(objectname)' refs/checkpoints/", store: target).stdout
            .split(separator: "\n").map(String.init)
    }

    /// Archivos del árbol de un punto.
    func files(of point: String) throws -> [String] {
        try storeGit("ls-tree -r -z --name-only \(point)").stdout.split(separator: "\0").map(String.init).sorted()
    }

    func show(_ point: String, _ path: String) throws -> String {
        try storeGit("show \(ShellQuoting.singleQuoted("\(point):\(path)"))").stdout
    }

    /// `git status` y el índice real, para comprobar que capturar no los toca.
    func realState() throws -> String {
        let status = try sh("GIT_OPTIONAL_LOCKS=0 git status --porcelain=v1 -z --untracked-files=all").stdout
        let index = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
        return status + "|" + index.base64EncodedString()
    }

    /// Vista previa + restauración completa, como hace la app.
    @discardableResult
    func restore(_ point: String, extraEnvironment: [String: String] = [:]) throws -> String {
        let preview = try checkpoint(["preview", repo.path, point, "full"]).stdout
        let tree = preview.components(separatedBy: "\n").first { $0.hasPrefix("ARGOS_CP_CURRENT ") }
            .map { String($0.dropFirst("ARGOS_CP_CURRENT ".count)) } ?? "-"
        return try checkpoint(["restore", repo.path, point, tree], extraEnvironment: extraEnvironment).stdout
    }

    /// Espera a que el sellado en segundo plano del hook termine (o a que pase `seconds`).
    func waitForSeal(_ point: String, seconds: Double = 10) {
        let marker = store.appendingPathComponent("sealed/\(point)").path
        let deadline = Date().addingTimeInterval(seconds)
        while !FileManager.default.fileExists(atPath: marker), Date() < deadline { usleep(100_000) }
    }

    /// Contenido de `path` en el punto más reciente (la copia previa tras restaurar).
    func inLatest(_ path: String) throws -> String? {
        guard let point = try points().first else { return nil }
        return try? show(point, path)
    }

    /// Runner del modelo: ejecuta el comando tal como iría por SSH, con /bin/sh.
    var runner: CheckpointRunner {
        let environment = environment
        let home = home
        return { command in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = environment
            process.currentDirectoryURL = home
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CheckpointCommandOutput(stdout: String(decoding: outData, as: UTF8.self),
                                           stderr: String(decoding: errData, as: UTF8.self),
                                           exitCode: Int(process.terminationStatus))
        }
    }
}

/// Doble del hook de captura para el modelo.
final class FakeCheckpointHooks: @unchecked Sendable {
    var installed = false
    private(set) var installs = 0
    private(set) var uninstalls = 0

    var control: CheckpointHookControl {
        CheckpointHookControl(
            isInstalled: { self.installed },
            install: { self.installs += 1; self.installed = true },
            uninstall: { self.uninstalls += 1; self.installed = false }
        )
    }
}
