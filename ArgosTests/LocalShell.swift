//
//  LocalShell.swift
//  ArgosTests
//
//  Ejecuta un script remoto de Argos con el `sh` del Mac sobre una carpeta temporal
//  (como `$HOME` o raíz de proyecto). No sustituye a un servidor Linux real, pero
//  comprueba el comportamiento de los scripts POSIX, no solo su texto.
//

import Foundation

enum LocalShell {
    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// `command` es el comando completo tal como se enviaría (p. ej. `sh -c '…'`).
    static func run(_ command: String, home: URL, workingDirectory: URL? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.currentDirectoryURL = workingDirectory ?? home
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        return Result(
            exitCode: process.terminationStatus,
            stdout: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    /// Carpeta temporal nueva (se borra con `remove`).
    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("argos-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Ruta real (en macOS /var → /private/var) para comparar rutas sin sorpresas.
        return url.resolvingSymlinksInPath()
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
