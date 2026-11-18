//
//  IntegrationSyncTests.swift
//  ArgosTests
//
//  «Enviar al servidor» contra un servidor real (`SSHProjectSync`, `SyncStaging`,
//  `ServerFileList`): subida a `.argos-up`, colocación con `mv -f` por lotes, destino que
//  es un enlace o una carpeta, enlaces simbólicos, limpieza de huérfanos y listado con
//  `find -printf` (solo GNU find: Linux). Ver `IntegrationRemote`.
//

import Foundation
import Testing
@testable import Argos

extension IntegrationServerSuites {

@Suite("Envío al servidor (sync)")
struct Sync {

    /// Archivo local temporal con `text`, con su `SyncFile` (modo y fecha fijos).
    private func localFile(_ path: String, _ text: String, mode: UInt16 = 0o644, in folder: URL) throws -> (SyncFile, URL) {
        let url = folder.appendingPathComponent(UUID().uuidString)
        try Data(text.utf8).write(to: url)
        return (SyncFile(path: path, size: UInt64(text.utf8.count), mtime: 1_600_000_000, mode: mode, linkTarget: nil), url)
    }

    private func localFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("argos-it-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Subir a .argos-up y colocar en lote: contenido, permisos, fecha y nombres raros", .timeLimit(.minutes(2)))
    func stageAndPlace() async throws {
        let box = try await RemoteBox.open("sync")
        let folder = try localFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            IntegrationCleanup.later { await box.close() }
        }
        let names = ["a.txt", "dir/run.sh", "dir/con espacio y ñ.txt", "dir/comilla'doble\"x.txt"]
        var files: [(SyncFile, URL)] = []
        for (index, name) in names.enumerated() {
            files.append(try localFile(name, "contenido \(index)\n", mode: name.hasSuffix(".sh") ? 0o755 : 0o644, in: folder))
        }
        try await box.service.makeRemoteDirectories(root: box.root, relativeDirectories: ["dir"])
        for (file, url) in files {
            try await box.service.stageSyncFile(root: box.root, file: file, from: url)
        }
        // Subidos pero sin colocar: solo existen los temporales.
        for name in names {
            #expect(try await box.exists(name + SyncStaging.suffix))
            #expect(try await box.exists(name) == false)
        }

        try await box.service.placeStagedSyncFiles(root: box.root, files: files.map(\.0))
        for (index, name) in names.enumerated() {
            #expect(try await box.read(name) == "contenido \(index)\n", "\(name)")
            #expect(try await box.exists(name + SyncStaging.suffix) == false)
        }
        let modes = try await box.sh("cd \(box.q(box.root)) && ls -l a.txt dir/run.sh | cut -c1-10")
        #expect(modes.split(separator: "\n").map(String.init) == ["-rw-r--r--", "-rwxr-xr-x"])
        let mtime = try await box.sh("cd \(box.q(box.root)) && { stat -c %Y a.txt 2>/dev/null || stat -f %m a.txt; }")
        #expect(mtime.trimmingCharacters(in: .whitespacesAndNewlines) == "1600000000")
    }

    @Test("Destino enlace: se sustituye por el archivo sin tocar lo enlazado; carpeta: error y sin temporal",
          .timeLimit(.minutes(2)))
    func linkAndDirectoryDestinations() async throws {
        let box = try await RemoteBox.open("sync-link")
        let folder = try localFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            IntegrationCleanup.later { await box.close() }
        }
        try await box.write("fuera\n", to: "fuera/objetivo.txt")
        try await box.sh("cd \(box.q(box.root)) && mkdir -p p/carpeta && ln -s ../fuera/objetivo.txt p/enlace.txt && ln -s ../fuera p/enlace-dir")

        let viaLink = try localFile("enlace.txt", "nuevo\n", in: folder)
        let viaDirLink = try localFile("enlace-dir", "otro\n", in: folder)
        let root = box.absolute("p")
        try await box.service.uploadSyncFile(root: root, file: viaLink.0, from: viaLink.1)
        try await box.service.uploadSyncFile(root: root, file: viaDirLink.0, from: viaDirLink.1)
        #expect(try await box.read("p/enlace.txt") == "nuevo\n")
        #expect(try await box.sh("[ -L \(box.q(box.absolute("p/enlace.txt"))) ] && echo enlace; true").isEmpty)
        #expect(try await box.read("fuera/objetivo.txt") == "fuera\n", "Lo enlazado sigue intacto")
        #expect(try await box.read("p/enlace-dir") == "otro\n")
        #expect(try await box.exists("fuera/enlace-dir") == false, "mv no debe meter el archivo dentro de la carpeta enlazada")

        // Una carpeta no se reemplaza por un archivo.
        let onDirectory = try localFile("carpeta", "x", in: folder)
        await #expect(throws: (any Error).self) {
            try await box.service.uploadSyncFile(root: root, file: onDirectory.0, from: onDirectory.1)
        }
        #expect(try await box.sh("[ -d \(box.q(box.absolute("p/carpeta"))) ] && echo dir").contains("dir"))
        #expect(try await box.exists("p/carpeta" + SyncStaging.suffix) == false)

        // Un enlace del Mac se crea como enlace.
        let link = SyncFile(path: "nuevo-enlace", size: 0, mtime: 0, mode: 0o777, linkTarget: "enlace.txt")
        try await box.service.placeStagedSyncFiles(root: root, files: [link])
        #expect(try await box.sh("readlink \(box.q(box.absolute("p/nuevo-enlace")))").contains("enlace.txt"))
    }

    @Test("Colocar más archivos de los que caben en un comando va por lotes", .timeLimit(.minutes(3)))
    func placesInBatches() async throws {
        let box = try await RemoteBox.open("sync-batch")
        defer { IntegrationCleanup.later { await box.close() } }
        let count = 2_500
        let long = String(repeating: "n", count: 60)
        let files = (0..<count).map {
            SyncFile(path: "d/\(long)-\($0).txt", size: 1, mtime: 0, mode: 0o644, linkTarget: nil)
        }
        #expect(SyncStaging.placeCommands(root: box.root, files: files).count > 1, "La prueba debe cubrir varios lotes")
        // Temporales creados en el servidor (sin SFTP: sería lentísimo para 2.500).
        try await box.sh("cd \(box.q(box.root)) && mkdir d && i=0; while [ $i -lt \(count) ]; do "
            + "printf x > \"d/\(long)-$i.txt\(SyncStaging.suffix)\"; i=$((i+1)); done")
        try await box.service.placeStagedSyncFiles(root: box.root, files: files)
        let placed = try await box.sh("cd \(box.q(box.root))/d && ls | grep -c '\\.txt$'; ls | grep -c 'argos-up$'; true")
        #expect(placed.split(separator: "\n").map(String.init) == ["\(count)", "0"])
    }

    @Test("Limpieza de huérfanos: solo los .argos-up viejos y fuera de carpetas excluidas", .timeLimit(.minutes(1)))
    func staleTemporaries() async throws {
        let box = try await RemoteBox.open("sync-stale")
        defer { IntegrationCleanup.later { await box.close() } }
        try await box.sh("cd \(box.q(box.root)) && mkdir -p sub node_modules && "
            + "for f in viejo.txt sub/viejo2.txt node_modules/dep.js; do printf x > \"$f.argos-up\"; "
            + "touch -t 200001010000 \"$f.argos-up\"; done && printf x > reciente.txt.argos-up")
        try await box.service.removeStaleSyncTemporaries(root: box.root)
        #expect(try await box.exists("viejo.txt.argos-up") == false)
        #expect(try await box.exists("sub/viejo2.txt.argos-up") == false)
        #expect(try await box.exists("reciente.txt.argos-up"), "Puede ser otro envío en curso")
        #expect(try await box.exists("node_modules/dep.js.argos-up"), "No se entra en carpetas excluidas")
    }

    @Test("Listado con find -printf: rutas raras, enlaces, sin temporales ni carpetas excluidas",
          .enabled(if: IntegrationRemote.isLinux, IntegrationRemote.linuxOnly), .timeLimit(.minutes(1)))
    func listing() async throws {
        let box = try await RemoteBox.open("sync-list")
        defer { IntegrationCleanup.later { await box.close() } }
        try await box.sh("""
        cd \(box.q(box.root)) && mkdir -p 'sub dir' node_modules/x .git/objects && \
        printf hola > 'sub dir/año con espacio.txt' && printf x > 'tab\tname.txt' && \
        printf x > node_modules/x/i.js && printf x > a.txt.argos-up && printf x > b.argos-down && \
        printf x > .DS_Store && printf ref > .git/HEAD && printf x > .git/objects/o && \
        ln -s 'sub dir/año con espacio.txt' enlace && chmod 750 'sub dir/año con espacio.txt' && \
        touch -t 202001020304.05 'sub dir/año con espacio.txt'
        """)
        let files = try await box.service.syncFileList(root: box.root)
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        #expect(Set(byPath.keys) == ["sub dir/año con espacio.txt", "tab\tname.txt", "enlace", ".git/HEAD", ".git/objects/o"])
        let odd = try #require(byPath["sub dir/año con espacio.txt"])
        #expect(odd.size == 4 && odd.mode == 0o750 && odd.linkTarget == nil)
        let expectedMtime = try await box.sh("stat -c %Y \(box.q(box.absolute("sub dir/año con espacio.txt")))")
        #expect(String(odd.mtime) == expectedMtime.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(byPath["enlace"]?.linkTarget == "sub dir/año con espacio.txt")
    }

    @Test("Tras un envío completo, git status no ve temporales de Argos", .timeLimit(.minutes(1)))
    func gitStatusAfterPlacing() async throws {
        let box = try await RemoteBox.open("sync-git")
        let folder = try localFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            IntegrationCleanup.later { await box.close() }
        }
        guard try await box.has("git") else { return }
        try await box.sh("cd \(box.q(box.root)) && git init -q . && git config user.email t@t && git config user.name t "
            + "&& printf a > a.txt && git add a.txt && git commit -qm uno")
        let upload = try localFile("a.txt", "cambiado\n", in: folder)
        try await box.service.uploadSyncFile(root: box.root, file: upload.0, from: upload.1)
        guard case .repository(let status) = try await box.service.gitStatus(at: box.root) else {
            Issue.record("No se reconoció el repositorio")
            return
        }
        #expect(status.changes.map(\.path) == ["a.txt"])
    }
}

}
