//
//  IntegrationGitTests.swift
//  ArgosTests
//
//  Panel «Cambios» contra un git real del servidor (`SSHGit`, `GitCommands`,
//  `GitFingerprint`): estado, diff, huellas `cksum`, commit normal y de más de 1.500
//  archivos (`--pathspec-from-file`), con rutas con espacios, acentos, comillas y saltos
//  de línea. Ver `IntegrationRemote`.
//

import Foundation
import Testing
@testable import Argos

extension IntegrationServerSuites {

@Suite("git en el servidor")
struct Git {

    private static let pathspecPrefix = "argos-pathspec-"

    /// Nombres que rompen un entrecomillado descuidado.
    private static let oddNames = [
        "con espacio.txt", "acentuado ñandú.txt", "comilla'simple.txt", "comilla\"doble.txt",
        "salto\nde línea.txt", "-empieza-por-guion.txt", "dólar $HOME y `x`.txt",
    ]

    /// Repositorio con un commit inicial en `box.root`; `nil` si el servidor no tiene git.
    private func repository(_ label: String) async throws -> RemoteBox? {
        let box = try await RemoteBox.open(label)
        guard try await box.has("git") else {
            await box.close()
            return nil
        }
        try await box.sh("cd \(box.q(box.root)) && git init -q . && git config user.email it@argos && "
            + "git config user.name 'Argos IT' && git config commit.gpgsign false && printf 'uno\\ndos\\n' > base.txt "
            + "&& git add base.txt && git commit -qm inicial")
        return box
    }

    private func status(_ box: RemoteBox) async throws -> GitRepositoryStatus {
        guard case .repository(let status) = try await box.service.gitStatus(at: box.root) else {
            throw IntegrationFailure("\(box.root) no se reconoce como repositorio")
        }
        return status
    }

    @Test("Estado y diff con nombres raros (sin seguimiento, modificado, borrado, renombrado)", .timeLimit(.minutes(2)))
    func statusAndDiff() async throws {
        guard let box = try await repository("git-status") else { return }
        defer { IntegrationCleanup.later { await box.close() } }
        for (index, name) in Self.oddNames.enumerated() {
            try await box.write("linea \(index)\n", to: name)
        }
        try await box.sh("cd \(box.q(box.root)) && printf 'uno\\nDOS\\n' > base.txt && printf x > a && git add a "
            + "&& git commit -qm a && git mv a b")

        let current = try await status(box)
        #expect(current.branch.hasCommits)
        let byPath = Dictionary(uniqueKeysWithValues: current.changes.map { ($0.path, $0) })
        for name in Self.oddNames {
            #expect(byPath[name]?.kind == .untracked, "\(name)")
        }
        #expect(byPath["base.txt"]?.kind == .modified)
        #expect(byPath["b"]?.kind == .renamed && byPath["b"]?.originalPath == "a")

        let modified = try await box.service.gitDiff(root: box.root, change: try #require(byPath["base.txt"]), hasCommits: true)
        #expect(modified.hasContent && modified.additions == 1 && modified.deletions == 1)
        let raw = try await box.service.run(GitCommands.diff(root: box.root, change: try #require(byPath["base.txt"]), hasCommits: true))
        #expect(raw.stdout.contains("-dos") && raw.stdout.contains("+DOS"))
        for name in Self.oddNames {
            let change = try #require(byPath[name])
            let diff = try await box.service.run(GitCommands.diff(root: box.root, change: change, hasCommits: true))
            #expect(diff.stdout.contains("+linea"), "diff de \(name): \(diff.stderr)")
        }
    }

    @Test("Huellas cksum: estables sin cambios y distintas al reeditar una línea", .timeLimit(.minutes(2)))
    func fingerprints() async throws {
        guard let box = try await repository("git-fp") else { return }
        defer { IntegrationCleanup.later { await box.close() } }
        try await box.write("nuevo\n", to: Self.oddNames[4])
        try await box.sh("cd \(box.q(box.root)) && printf 'uno\\nDOS\\n' > base.txt")
        let changes = try await status(box).changes.sorted { $0.path < $1.path }
        #expect(changes.count == 2)

        let first = try await box.service.gitFingerprints(root: box.root, changes: changes, hasCommits: true)
        let again = try await box.service.gitFingerprints(root: box.root, changes: changes, hasCommits: true)
        #expect(first.count == 2 && first == again)
        #expect(first.allSatisfy { $0.split(separator: " ").count == 2 }, "cksum = «suma bytes»: \(first)")

        // Misma longitud, otra letra: cksum lo distingue.
        try await box.sh("cd \(box.q(box.root)) && printf 'uno\\nDOZ\\n' > base.txt")
        let edited = try await box.service.gitFingerprints(root: box.root, changes: changes, hasCommits: true)
        let baseIndex = try #require(changes.firstIndex { $0.path == "base.txt" })
        #expect(edited[baseIndex] != first[baseIndex])
        #expect(edited[1 - baseIndex] == first[1 - baseIndex])

        // Repositorio sin commits: también da huella.
        try await box.sh("cd \(box.q(box.root)) && rm -rf .git && git init -q . && git add base.txt")
        let unborn = try await status(box)
        #expect(unborn.branch.hasCommits == false)
        let fresh = try await box.service.gitFingerprints(root: box.root, changes: unborn.changes, hasCommits: false)
        #expect(fresh.count == unborn.changes.count)
    }

    @Test("Commit normal solo de lo marcado, con nombres raros", .timeLimit(.minutes(2)))
    func inlineCommit() async throws {
        guard let box = try await repository("git-commit") else { return }
        defer { IntegrationCleanup.later { await box.close() } }
        for name in Self.oddNames { try await box.write("x\n", to: name) }
        try await box.write("fuera\n", to: "no-marcado.txt")
        let changes = try await status(box).changes.filter { Self.oddNames.contains($0.path) }
        #expect(changes.count == Self.oddNames.count)
        #expect(GitCommands.commitFitsInline(root: box.root, message: "m", changes: changes))

        let summary = try await box.service.gitCommit(root: box.root, message: "nombres 'raros' y \"comillas\"", changes: changes)
        #expect(summary.contains("nombres"))
        let left = try await status(box).changes.map(\.path)
        #expect(left == ["no-marcado.txt"])
        let subject = try await box.sh("cd \(box.q(box.root)) && git log -1 --format=%s")
        #expect(subject.trimmingCharacters(in: .newlines) == "nombres 'raros' y \"comillas\"")
    }

    @Test("Commit de más de 1.500 archivos por --pathspec-from-file", .timeLimit(.minutes(4)))
    func hugeCommitUsesPathspecFile() async throws {
        guard let box = try await repository("git-huge") else { return }
        defer { IntegrationCleanup.later { await box.close() } }
        let count = 1_600
        try await box.sh("cd \(box.q(box.root)) && mkdir -p 'carpeta con espacio' && i=0; while [ $i -lt \(count) ]; do "
            + "printf '%s\\n' $i > \"carpeta con espacio/archivo ñ $i.txt\"; i=$((i+1)); done && "
            + "printf x > \(box.q(Self.oddNames[4])) && printf y > fuera.txt")
        let all = try await status(box).changes
        let selected = all.filter { $0.path != "fuera.txt" }
        #expect(selected.count == count + 1)
        #expect(GitCommands.commitFitsInline(root: box.root, message: "m", changes: selected) == false,
                "La prueba debe ir por --pathspec-from-file")

        _ = try await box.service.gitCommit(root: box.root, message: "muchos", changes: selected)
        #expect(try await status(box).changes.map(\.path) == ["fuera.txt"])
        let committed = try await box.sh("cd \(box.q(box.root)) && git show --name-only --format= HEAD | wc -l")
        #expect(Int(committed.trimmingCharacters(in: .whitespacesAndNewlines)) == count + 1)
        // Las listas de rutas subidas por SFTP se borran al terminar (trap EXIT).
        let leftovers = try await box.sh("ls /tmp | grep -c '\(Self.pathspecPrefix)'; true")
        #expect(leftovers.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
    }

    @Test("Descartar: un modificado vuelve a HEAD y uno sin seguimiento se borra", .timeLimit(.minutes(1)))
    func discard() async throws {
        guard let box = try await repository("git-discard") else { return }
        defer { IntegrationCleanup.later { await box.close() } }
        try await box.write("tirar\n", to: Self.oddNames[2])
        try await box.sh("cd \(box.q(box.root)) && printf cambio > base.txt")
        for change in try await status(box).changes {
            try await box.service.gitDiscard(root: box.root, change: change)
        }
        #expect(try await status(box).isClean)
        #expect(try await box.read("base.txt") == "uno\ndos\n")
    }
}

}
