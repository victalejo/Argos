//
//  SyncStagingTests.swift
//  ArgosTests
//
//  «Enviar al servidor» atómico: texto exacto de los comandos, troceo por bytes,
//  exclusión de temporales y el script de colocación ejecutado con sh.
//

import Testing
import Foundation
@testable import Argos

@Suite("Envío atómico al servidor")
struct SyncStagingTests {

    private static func file(_ path: String, link: String? = nil) -> SyncFile {
        SyncFile(path: path, size: 1, mtime: 1_000, mode: 0o644, linkTarget: link)
    }

    @Test("Los temporales de Argos no se listan ni se comparan")
    func temporariesExcluded() {
        #expect(SyncExclusions.isExcluded("src/a.swift.argos-up"))
        #expect(SyncExclusions.isExcluded("a.argos-down"))
        #expect(SyncExclusions.isExcluded(".git/config.argos-raw"))
        #expect(!SyncExclusions.isExcluded("src/argos-up.swift"))
        let listing = "f\t3\t1000.0\t644\t\tsrc/a.swift.argos-up\0f\t3\t1000.0\t644\t\tsrc/a.swift\0"
        #expect(ServerFileList.parse(listing).map(\.path) == ["src/a.swift"])
    }

    @Test("Texto exacto del comando de colocación")
    func placeCommandText() {
        let commands = SyncStaging.placeCommands(root: "/srv/my app", files: [
            Self.file("a b.txt"), Self.file("ln", link: "../x"), Self.file("../fuera"),
        ])
        #expect(commands.count == 1)
        let script = "cd '/srv/my app' || exit 1\n\(SyncStaging.placeFunctions)\nplace 'a b.txt'\nlink 'ln' '../x'\nexit $fail"
        #expect(commands.first == ShellQuoting.posixShell(script))
    }

    @Test("Texto exacto de borrar temporales y de limpiar huérfanos")
    func discardAndCleanupText() {
        #expect(SyncStaging.discardCommands(root: "/r", paths: ["a", "it's", "../x"])
                == [ShellQuoting.posixShell("cd '/r' || exit 1; rm -f -- 'a.argos-up' 'it'\\''s.argos-up'")])
        let cleanup = SyncStaging.staleCleanupCommand(root: "/r")
        #expect(cleanup.hasPrefix("sh -c "))
        #expect(cleanup.contains("-name '\\''*.argos-up'\\'' -mmin +30 -exec rm -f -- {} +"))
        #expect(cleanup.contains("-name '\\''node_modules'\\''"))
    }

    @Test("Miles de archivos se reparten en lotes que caben en un argumento")
    func batching() {
        let files = (0..<5_000).map { Self.file("carpeta/bastante/profunda/archivo-numero-\($0).swift") }
        let commands = SyncStaging.placeCommands(root: "/r", files: files)
        #expect(commands.count > 1)
        for command in commands { #expect(command.utf8.count <= RemoteCommandLimit.maxCommandBytes) }
        let placed = commands.joined().components(separatedBy: "place '\\''carpeta/").count - 1
        #expect(placed == 5_000)
    }

    @Test("Colocar reemplaza archivos y enlaces sin hueco y nunca sobre una carpeta")
    func placeScriptRuns() throws {
        let root = try LocalShell.makeTemporaryDirectory()
        defer { LocalShell.remove(root) }
        let manager = FileManager.default
        func write(_ text: String, _ path: String) throws {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        try write("viejo", "a.txt")
        try write("nuevo", "a.txt.argos-up")
        try write("nuevo", "nuevo.txt.argos-up")
        // Destino que es un enlace a una carpeta: mv NO debe meter el archivo dentro.
        try manager.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: root.appendingPathComponent("enlace").path, withDestinationPath: "dir")
        try write("archivo", "enlace.argos-up")
        // Destino que es una carpeta de verdad: se rechaza y se borra el temporal.
        try manager.createDirectory(at: root.appendingPathComponent("carpeta"), withIntermediateDirectories: true)
        try write("x", "carpeta.argos-up")

        let files = [Self.file("a.txt"), Self.file("nuevo.txt"), Self.file("enlace"), Self.file("carpeta"),
                     Self.file("ln", link: "a.txt")]
        let command = try #require(SyncStaging.placeCommands(root: root.path, files: files).first)
        let result = try LocalShell.run(command, home: root)
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("carpeta"))
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "nuevo")
        #expect(try String(contentsOf: root.appendingPathComponent("nuevo.txt"), encoding: .utf8) == "nuevo")
        #expect(try String(contentsOf: root.appendingPathComponent("enlace"), encoding: .utf8) == "archivo")
        #expect(try manager.contentsOfDirectory(atPath: root.appendingPathComponent("dir").path).isEmpty)
        #expect(try manager.destinationOfSymbolicLink(atPath: root.appendingPathComponent("ln").path) == "a.txt")
        let leftovers = try manager.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".argos-up") }
        #expect(leftovers.isEmpty)
    }

    @Test("La limpieza borra solo temporales antiguos")
    func cleanupRuns() throws {
        let root = try LocalShell.makeTemporaryDirectory()
        defer { LocalShell.remove(root) }
        let old = root.appendingPathComponent("viejo.txt.argos-up")
        let recent = root.appendingPathComponent("reciente.txt.argos-up")
        let normal = root.appendingPathComponent("normal.txt")
        for url in [old, recent, normal] { try Data("x".utf8).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: normal.path)
        let result = try LocalShell.run(SyncStaging.staleCleanupCommand(root: root.path), home: root)
        #expect(result.exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: normal.path))
    }

    @Test("El troceo por bytes no parte elementos y respeta el tope")
    func batchesByBytes() {
        #expect(RemoteCommandLimit.batches([]) == [])
        #expect(RemoteCommandLimit.batches(["aa", "bb", "cc"], maxBytes: 6) == [["aa", "bb"], ["cc"]])
        #expect(RemoteCommandLimit.batches(["muy-largo"], maxBytes: 3) == [["muy-largo"]])
        #expect(throws: RemoteCommandError.tooLong(bytes: 100_001)) {
            try RemoteCommandLimit.check(String(repeating: "a", count: 100_001))
        }
    }
}

@Suite("Limpieza de /tmp y authorized_keys")
struct RemoteHygieneTests {

    @Test("La limpieza de /tmp solo toca archivos de Argos de este usuario")
    func tmpCleanupText() {
        let command = RemoteUpload.staleCleanupCommand
        #expect(command.hasPrefix("find /tmp -maxdepth 1 -type f "))
        #expect(command.contains("-name 'argos-pasted-*' -o -name 'argos-pathspec-*' -o -name 'argos-[0-9]*-*'"))
        #expect(command.contains("-user \"$(id -u)\" -mmin +4320 -exec rm -f -- {} +"))
        #expect(RemoteUpload.pathspecPath().hasPrefix("/tmp/argos-pathspec-"))
    }

    @Test("Autorizar una clave añade antes el salto de línea que falte", arguments: [
        ("", "ssh-ed25519 B y\n"),
        ("ssh-rsa A x", "ssh-rsa A x\nssh-ed25519 B y\n"),
        ("ssh-rsa A x\n", "ssh-rsa A x\nssh-ed25519 B y\n"),
    ])
    func authorizeKeyRuns(existing: String, expected: String) throws {
        let home = try LocalShell.makeTemporaryDirectory()
        defer { LocalShell.remove(home) }
        if !existing.isEmpty {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
            try Data(existing.utf8).write(to: home.appendingPathComponent(".ssh/authorized_keys"))
        }
        let result = try LocalShell.run(SSHService.authorizeKeyCommand(line: "ssh-ed25519 B y"), home: home)
        #expect(result.exitCode == 0)
        #expect(try String(contentsOf: home.appendingPathComponent(".ssh/authorized_keys"), encoding: .utf8) == expected)
    }
}
