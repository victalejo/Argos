//
//  IntegrationCheckpointSupport.swift
//  ArgosTests
//
//  Repositorio git de prueba EN EL SERVIDOR para las suites de puntos de restauración
//  (`IntegrationCheckpointTests`, `IntegrationCheckpointSafetyTests`). Todo va por SSH con
//  el servicio real (`runCheckpointCommand`, `installCheckpointHook`, `CheckpointsModel`), y
//  el hook se ejecuta como lo hace Claude Code: el comando de `settings.json` con
//  `/bin/sh -c` y la entrada JSON de `UserPromptSubmit` por stdin.
//
//  Aislamiento: el repositorio vive en la carpeta del test (`<HOME aislado>/it/…`) y cada
//  script que lo prepara comprueba antes, en el servidor, que su `pwd -P` sigue ahí.
//

import Foundation
import Testing
@testable import Argos

struct RemoteCheckpointRepo: Sendable {
    let box: RemoteBox
    /// Ruta física (`pwd -P`) del repositorio.
    let path: String
    /// Ruta física de la carpeta del test (el límite de todo lo que se toca).
    let zone: String

    var store: String { "\(path)/.git/\(CheckpointScript.storeName)" }

    /// Repositorio con un commit inicial (`a.txt`) y los puntos activados (`enabled`) con el
    /// propio script; `nil` si el servidor no tiene git.
    static func open(_ label: String, enabled: Bool = true) async throws -> RemoteCheckpointRepo? {
        let box = try await RemoteBox.open(label)
        guard try await box.has("git") else {
            await box.close()
            return nil
        }
        guard box.root.hasPrefix(box.home + "/it/") else {
            await box.close()
            throw IntegrationFailure("la carpeta del test \(box.root) no está en el HOME aislado")
        }
        let zone = try await box.sh("cd \(box.q(box.root)) && pwd -P").trimmingCharacters(in: .newlines)
        let repo = RemoteCheckpointRepo(box: box, path: zone + "/repo", zone: zone)
        try await box.sh("mkdir -p \(box.q(repo.path))")
        try await repo.sh("git init -q . && git config user.email it@argos && git config user.name 'Argos IT' "
            + "&& git config commit.gpgsign false && echo base > a.txt && git add -A && git commit -qm inicial")
        if enabled {
            let output = try await repo.command(CheckpointCommands.enable(root: repo.path))
            guard output.contains("ARGOS_CP_OK") else { throw IntegrationFailure("enable: \(output)") }
        }
        return repo
    }

    func close() async { await box.close() }

    // MARK: - Shell en el repositorio

    /// Prefijo de todo script sobre el repositorio: entra y comprueba que sigue en la zona.
    private func guarded(_ directory: String) -> String {
        "cd \(q(directory)) && case \"$(pwd -P)/\" in \(q(zone + "/"))*) ;; *) echo 'fuera de la zona' >&2; exit 97 ;; esac"
    }

    /// Script en el repositorio (o en `directory`, que también debe estar en la zona). Lanza si falla.
    @discardableResult
    func sh(_ script: String, in directory: String? = nil) async throws -> String {
        try await box.sh("\(guarded(directory ?? path)) && { \(script)\n}")
    }

    /// Igual, sin lanzar por el código de salida.
    func run(_ script: String, in directory: String? = nil) async throws -> CommandOutput {
        try await box.run(ShellQuoting.posixShell("\(guarded(directory ?? path)) && { \(script)\n}"), timeout: .long)
    }

    func q(_ value: String) -> String { ShellQuoting.singleQuoted(value) }

    func write(_ relativePath: String, _ text: String) async throws {
        try await box.write(text, to: "\(path)/\(relativePath)")
    }

    /// Contenido de un archivo del repositorio (`nil` si no existe).
    func read(_ relativePath: String) async throws -> String? {
        let output = try await run("cat -- \(q("./" + relativePath))")
        return output.exitCode == 0 ? output.stdout : nil
    }

    func exists(_ relativePath: String) async throws -> Bool {
        let target = q("./" + relativePath)
        return try await run("[ -e \(target) ] || [ -L \(target) ]").exitCode == 0
    }

    /// Archivo de `megabytes` MB de ceros.
    func big(_ relativePath: String, megabytes: Int) async throws {
        try await sh("dd if=/dev/zero of=\(q("./" + relativePath)) bs=1048576 count=\(megabytes) 2>/dev/null")
    }

    // MARK: - Script de los puntos (por el servicio real)

    /// Ejecuta un comando de `CheckpointCommands` y devuelve stdout.
    @discardableResult
    func command(_ command: String) async throws -> String {
        try await box.service.runCheckpointCommand(command).stdout
    }

    /// Un modo cualquiera del script con sus argumentos (ruta del repositorio incluida).
    @discardableResult
    func mode(_ arguments: [String]) async throws -> String {
        try await command(CheckpointCommands.invocation(arguments))
    }

    func snapshot(_ label: String = "a mano") async throws -> String {
        let output = try await command(CheckpointCommands.snapshot(root: path, label: label))
        guard let commit = try CheckpointParser.parseSnapshot(output) else {
            throw IntegrationFailure("snapshot sin cambios: \(output)")
        }
        return commit
    }

    func list() async throws -> CheckpointListing {
        guard case .listing(let listing) = try CheckpointParser.parseList(try await command(CheckpointCommands.list(path: path))) else {
            throw IntegrationFailure("list no devolvió una lista")
        }
        return listing
    }

    func preview(_ point: String) async throws -> String {
        try await command(CheckpointCommands.preview(root: path, commit: point, force: true))
    }

    /// Vista previa + restauración completa con el árbol visto, como hace la app.
    @discardableResult
    func restore(_ point: String) async throws -> String {
        let preview = try await preview(point)
        let tree = preview.components(separatedBy: "\n").first { $0.hasPrefix("ARGOS_CP_CURRENT ") }
            .map { String($0.dropFirst("ARGOS_CP_CURRENT ".count)) }
        return try await command(CheckpointCommands.restore(root: path, commit: point, expectedTree: tree, path: nil))
    }

    func restoreFile(_ point: String, _ file: String) async throws -> String {
        try await command(CheckpointCommands.restore(root: path, commit: point, expectedTree: nil, path: file))
    }

    // MARK: - Hook (como Claude Code)

    /// Entrada JSON de `UserPromptSubmit` (la documentada por Claude Code).
    static func hookInput(prompt: String, session: String, cwd: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "session_id": session, "transcript_path": "\(cwd)/.transcript.jsonl", "cwd": cwd,
            "permission_mode": "default", "hook_event_name": CheckpointHookInstaller.event, "prompt": prompt,
        ], options: [.sortedKeys])
    }

    /// Ejecuta `command` (por defecto, el del hook de puntos) con `/bin/sh -c` en `directory`
    /// y la entrada por stdin. `seconds`: lo que tardó, medido en el servidor.
    @discardableResult
    func hook(prompt: String = "Arregla el bug", session: String = "sesion-it", in directory: String? = nil,
              command: String = CheckpointHookInstaller.command) async throws -> (output: CommandOutput, seconds: Int) {
        let cwd = directory ?? path
        let input = try Self.hookInput(prompt: prompt, session: session, cwd: cwd).base64EncodedString()
        let script = "t0=$(date +%s); printf '%s' '\(input)' | base64 -d | /bin/sh -c \(q(command)); rc=$?; "
            + "t1=$(date +%s); printf '\\nARGOS_IT_HOOK %s %s\\n' \"$rc\" $((t1 - t0))"
        let raw = try await run(script, in: cwd)
        guard let range = raw.stdout.range(of: "\nARGOS_IT_HOOK ", options: .backwards) else {
            throw IntegrationFailure("el hook no terminó: \(raw.stderr)")
        }
        let tail = raw.stdout[range.upperBound...].split(separator: " ")
        let code = Int(tail.first ?? "") ?? -1
        let seconds = Int(tail.dropFirst().first?.trimmingCharacters(in: .newlines) ?? "") ?? -1
        let output: CommandOutput = (stdout: String(raw.stdout[..<range.lowerBound]), stderr: raw.stderr, exitCode: code)
        return (output, seconds)
    }

    /// Script del hook en `~/.config/argos` (sin tocar settings.json).
    func installScript() async throws {
        try await box.write(CheckpointScript.source, to: "\(box.home)/\(CheckpointScript.installedRelativePath)")
    }

    // MARK: - Almacén de puntos

    /// Commits de los puntos (del más reciente al más antiguo).
    func points(store: String? = nil) async throws -> [String] {
        let target = q(store ?? self.store)
        return try await sh("[ -f \(target)/HEAD ] || exit 0; git --git-dir=\(target) for-each-ref --sort=-refname "
            + "--format='%(objectname)' refs/checkpoints/")
            .split(separator: "\n").map(String.init)
    }

    /// Contenido de `file` en el punto (`nil` si no está).
    func show(_ point: String, _ file: String, store: String? = nil) async throws -> String? {
        let output = try await run("git --git-dir=\(q(store ?? self.store)) cat-file blob \(q("\(point):\(file)"))")
        return output.exitCode == 0 ? output.stdout : nil
    }

    func inLatest(_ file: String) async throws -> String? {
        guard let point = try await points().first else { return nil }
        return try await show(point, file)
    }

    /// Espera a que el sellado en segundo plano del hook deje su marca.
    func waitSealed(_ point: String) async throws -> Bool {
        try await eventually(seconds: 20) {
            try await run("[ -e \(q("\(store)/sealed/\(point)")) ]").exitCode == 0
        }
    }

    /// Motivos de los mensajes sin punto (`skips` del almacén).
    func skips() async throws -> String {
        try await sh("cat \(q(store + "/skips")) 2>/dev/null; true")
    }
}

/// Registros `tipo\0ruta\0` de una salida, tras `marker`.
func checkpointIssues(_ output: String, after marker: String = "ARGOS_CP_CONFLICT\n") -> [CheckpointIssue] {
    CheckpointParser.parseIssues(output, after: marker)
}
