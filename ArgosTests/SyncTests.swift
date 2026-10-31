//
//  SyncTests.swift
//  ArgosTests
//
//  "Enviar al Mac" / "Enviar al servidor": listado del servidor, exclusiones, rutas
//  seguras y el planificador de cambios/conflictos contra el manifiesto.
//

import Foundation
import Testing
@testable import Argos

@Suite("Enviar al Mac: sincronización")
struct SyncTests {

    private func file(_ path: String, size: UInt64 = 10, mtime: Int = 100, mode: UInt16 = 0o644, link: String? = nil) -> SyncFile {
        SyncFile(path: path, size: size, mtime: mtime, mode: mode, linkTarget: link)
    }

    // MARK: - Listado del servidor

    @Test("Parsea el find real: archivos, enlaces, nombres con tabulador")
    func parsesServerList() {
        let output = "f\t1\t1793392565.6775649120\t664\t\tsub/con\ttab y espacio.txt\0"
            + "l\t3\t1793392565.68\t777\tsub\tenlace\0"
            + "f\t5\t100.0\t755\t\tscripts/run.sh\0"
        let files = ServerFileList.parse(output)
        #expect(files.count == 3)
        #expect(files[0].path == "sub/con\ttab y espacio.txt")
        #expect(files[0].mtime == 1_793_392_565)
        #expect(files[0].mode == 0o664)
        #expect(files[1].linkTarget == "sub")
        #expect(files[2].mode == 0o755)
    }

    @Test("Descarta rutas peligrosas o excluidas y registros corruptos")
    func rejectsUnsafeRecords() {
        let output = "f\t1\t1.0\t644\t\t../../etc/passwd\0"
            + "f\t1\t1.0\t644\t\t/abs\0"
            + "f\t1\t1.0\t644\t\tnode_modules/x/index.js\0"
            + "f\tx\t1.0\t644\t\tmal.txt\0"
            + "f\t1\tinf\t644\t\tinf.txt\0"
            + "f\t1\t1.0\t644\t\tok.txt\0"
        #expect(ServerFileList.parse(output).map(\.path) == ["ok.txt"])
    }

    @Test("Exclusiones: dependencias y builds fuera; .git y .env dentro")
    func exclusions() {
        #expect(SyncExclusions.isExcluded("node_modules/a.js"))
        #expect(SyncExclusions.isExcluded("apps/web/.next/cache/x"))
        #expect(SyncExclusions.isExcluded("sub/.DS_Store"))
        #expect(!SyncExclusions.isExcluded(".git/HEAD"))
        #expect(!SyncExclusions.isExcluded(".env.local"))
        #expect(!SyncExclusions.isExcluded("src/build.ts"), "un ARCHIVO llamado build.ts sí viaja")
    }

    @Test("Rutas relativas seguras")
    func safePaths() {
        #expect(SyncPath.isSafeRelative("src/app/page.tsx"))
        #expect(!SyncPath.isSafeRelative("../x"))
        #expect(!SyncPath.isSafeRelative("a/../../x"))
        #expect(!SyncPath.isSafeRelative("/etc/passwd"))
        #expect(!SyncPath.isSafeRelative("a//b"))
        #expect(!SyncPath.isSafeRelative(""))
    }

    // MARK: - Planificador

    @Test("Sin cambios en ningún lado: plan vacío")
    func noChanges() {
        let base = [file("a.ts")]
        let plan = SyncPlanner.plan(manifest: ["a.ts": base[0]], local: base, server: base)
        #expect(plan.isEmpty)
        #expect(plan.keptServerChanges.isEmpty)
    }

    @Test("Cambios del Mac: sube modificados y nuevos, borra lo borrado")
    func macChanges() {
        let manifest = ["a.ts": file("a.ts"), "b.ts": file("b.ts"), "c.ts": file("c.ts")]
        let local = [file("a.ts", mtime: 200), file("c.ts"), file("nuevo.ts")]
        let server = [file("a.ts"), file("b.ts"), file("c.ts")]
        let plan = SyncPlanner.plan(manifest: manifest, local: local, server: server)
        #expect(plan.uploads.map(\.path) == ["a.ts", "nuevo.ts"])
        #expect(plan.deletions == ["b.ts"])
        #expect(plan.conflicts.isEmpty)
    }

    @Test("Cambios solo en el servidor se conservan, no se pisan")
    func serverOnlyChangesKept() {
        let manifest = ["a.ts": file("a.ts")]
        let plan = SyncPlanner.plan(manifest: manifest, local: [file("a.ts")], server: [file("a.ts", mtime: 300), file("srv.ts")])
        #expect(plan.isEmpty)
        #expect(plan.keptServerChanges == ["a.ts", "srv.ts"])
    }

    @Test("Conflictos: modificado en ambos, borrado en uno y modificado en el otro")
    func conflicts() {
        let manifest = ["a.ts": file("a.ts"), "b.ts": file("b.ts"), "c.ts": file("c.ts")]
        let local = [file("a.ts", mtime: 200), file("c.ts", mtime: 200)]
        let server = [file("a.ts", mtime: 300), file("b.ts", mtime: 300)]
        let plan = SyncPlanner.plan(manifest: manifest, local: local, server: server)
        #expect(Set(plan.conflicts) == [
            SyncConflict(path: "a.ts", kind: .bothModified),
            SyncConflict(path: "b.ts", kind: .deletedOnMacModifiedOnServer),
            SyncConflict(path: "c.ts", kind: .modifiedOnMacDeletedOnServer),
        ])
        #expect(plan.uploads.isEmpty && plan.deletions.isEmpty)
    }

    @Test("El mismo cambio en ambos lados no es conflicto")
    func identicalChangeIsNotConflict() {
        let plan = SyncPlanner.plan(manifest: ["a.ts": file("a.ts")], local: [file("a.ts", mtime: 500)], server: [file("a.ts", mtime: 500)])
        #expect(plan.isEmpty)
    }

    @Test("Resolver conflictos a favor del Mac o del servidor")
    func resolveConflicts() {
        let manifest = ["a.ts": file("a.ts"), "b.ts": file("b.ts")]
        let local = [file("a.ts", mtime: 200)]
        let server = [file("a.ts", mtime: 300), file("b.ts", mtime: 300)]
        let plan = SyncPlanner.plan(manifest: manifest, local: local, server: server)

        let mac = SyncPlanner.resolving(plan, preferMac: true, local: local)
        #expect(mac.conflicts.isEmpty)
        #expect(mac.uploads.map(\.path) == ["a.ts"])
        #expect(mac.deletions == ["b.ts"])

        let server2 = SyncPlanner.resolving(plan, preferMac: false, local: local)
        #expect(server2.conflicts.isEmpty && server2.uploads.isEmpty && server2.deletions.isEmpty)
        #expect(Set(server2.keptServerChanges) == ["a.ts", "b.ts"])
    }

    @Test("Un cambio de permisos (chmod +x) cuenta como cambio")
    func modeChange() {
        let plan = SyncPlanner.plan(manifest: ["s.sh": file("s.sh")], local: [file("s.sh", mode: 0o755)], server: [file("s.sh")])
        #expect(plan.uploads.map(\.mode) == [0o755])
    }

    // MARK: - Enlaces simbólicos (seguridad)

    @Test("Se descartan archivos que cuelgan de un enlace del listado")
    func dropsFilesUnderSymlinks() {
        let files = [file("a", link: "/Users/victima"), file("a/.zshrc"), file("ab/ok.txt"), file("b.txt")]
        #expect(SyncPath.withoutPathsUnderSymlinks(files).map(\.path) == ["a", "ab/ok.txt", "b.txt"])
    }

    @Test("Solo enlaces relativos que no salen de la carpeta")
    func safeSymlinkTargets() {
        #expect(SyncPath.isSafeSymlink(path: "enlace", target: "sub"))
        #expect(SyncPath.isSafeSymlink(path: "a/b/l", target: "../c/d"))
        #expect(!SyncPath.isSafeSymlink(path: "l", target: "/etc/passwd"))
        #expect(!SyncPath.isSafeSymlink(path: "l", target: "../fuera"))
        #expect(!SyncPath.isSafeSymlink(path: "a/l", target: "../../fuera"))
        #expect(!SyncPath.isSafeSymlink(path: "../l", target: "x"))
    }

    // MARK: - Git

    @Test("Los hooks de git no viajan; .git/config se trae pero nunca se sube")
    func gitHooksAndConfig() {
        #expect(SyncExclusions.isExcluded(".git/hooks/pre-commit"))
        #expect(SyncExclusions.isExcluded(".GIT/HOOKS/post-checkout"))
        #expect(!SyncExclusions.isExcluded(".git/config"))
        let config = file(".git/config")
        let plan = SyncPlanner.plan(manifest: [".git/config": config], local: [file(".git/config", size: 5)], server: [config])
        #expect(plan.isEmpty)
    }

    @Test("Enlace en mayúsculas no deja pasar archivos 'a través' (Mac sin distinguir mayúsculas)")
    func caseInsensitiveSymlinkFilter() {
        let files = [file("A", link: "x"), file("a/pwned"), file("b")]
        #expect(SyncPath.withoutPathsUnderSymlinks(files).map(\.path) == ["A", "b"])
    }

    @Test("Config de git: lista blanca; descarta include, filtros, comandos y lo ambiguo")
    func rebuildsGitConfig() {
        let config = """
        [core]
        \trepositoryformatversion = 0
        \tfilemode = true
        \tfsmonitor = /tmp/evil.sh
        \tsshCommand = ssh -o ProxyCommand=evil
        [include]
        \tpath = /tmp/evil.config
        [includeIf "gitdir:~/"]
        \tpath = /tmp/evil2
        [remote "origin"]
        \turl = git@github.com:v/p.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [remote "x"]
        \turl = ext::sh -c evil
        [branch "main"]
        \tremote = origin
        \tmerge = refs/heads/main
        [filter "lfs"]
        \tsmudge = evil
        [alias]
        \tpwn = !rm -rf ~
        [user]
        \tname = "Víctor # Alejo" ; comentario
        """
        let (clean, removed) = GitConfigSanitizer.rebuild(config)
        #expect(clean.contains("[remote \"origin\"]"))
        #expect(clean.contains("url = \"git@github.com:v/p.git\""))
        #expect(clean.contains("merge = \"refs/heads/main\""))
        #expect(clean.contains("repositoryformatversion = \"0\""))
        #expect(clean.contains("name = \"Víctor # Alejo\""))
        #expect(!clean.contains("evil") && !clean.contains("rm -rf") && !clean.contains("include"))
        #expect(!clean.contains("[remote \"x\"]"))
        #expect(removed == 7)
    }

    @Test("Estructura de git: hooks de submódulos y repos anidados, .git como archivo")
    func gitStructure() {
        #expect(SyncExclusions.isExcluded(".git/modules/lib/hooks/post-checkout"))
        #expect(SyncExclusions.isExcluded("sub/.git/hooks/pre-commit"))
        #expect(SyncExclusions.isExcluded(".git/hooks"))
        #expect(!SyncExclusions.isExcluded(".git/objects/ab/cdef"))
        #expect(SyncExclusions.isUploadExcluded(".git/config"))
        #expect(!SyncExclusions.isUploadExcluded(".git/modules/lib/config"))
        #expect(!SyncExclusions.isUploadExcluded("src/config"))
        #expect(SyncExclusions.isUnsafeGitEntry(file(".git")))
        #expect(SyncExclusions.isUnsafeGitEntry(file("sub/.GIT", link: "/elsewhere")))
        #expect(!SyncExclusions.isUnsafeGitEntry(file(".gitignore")))
    }

    @Test("Lista blanca de git: solo lo necesario del .git raíz; fuera anidados, commondir, enlaces y bare")
    func gitAllowlist() {
        let files = [
            file(".git/HEAD"), file(".git/config"), file(".git/index"), file(".git/packed-refs"),
            file(".git/objects/ab/cdef"), file(".git/refs/heads/main"), file(".git/logs/HEAD"),
            file(".git/info/exclude"),
            file(".git/commondir"), file(".git/gitdir"), file(".git/worktrees/w/gitdir"),
            file(".git/modules/lib/config"), file(".git/info/attributes"), file(".git/description"),
            file(".git/objects", link: "../fuera"),
            file("sub/.git/HEAD"), file("vendor/lib/.git/config"),
            file("trampa/HEAD"), file("trampa/objects/x"), file("trampa/hooks/pre-commit"),
            file("trampa/config"), file("trampa/commondir"),
            file("src/app.ts"), file("docs/HEAD.md"),
        ]
        let kept = Set(SyncGitFilter.apply(files).map(\.path))
        #expect(kept == [
            ".git/HEAD", ".git/config", ".git/index", ".git/packed-refs",
            ".git/objects/ab/cdef", ".git/refs/heads/main", ".git/logs/HEAD", ".git/info/exclude",
            "trampa/HEAD", "trampa/objects/x", "src/app.ts", "docs/HEAD.md",
        ])
    }

    @Test("Repo bare 'disfrazado' (objects/refs como enlaces o vacíos) tampoco cuela config ni hooks")
    func disguisedBareRepo() {
        let files = [
            file("x/HEAD"), file("x/config"), file("x/hooks/post-checkout"),
            file("x/objects", link: "/tmp/o"), file("x/refs", link: "/tmp/r"),
            file("y/HEAD", link: "z"), file("y/config"),
            file("w/commondir"), file("w/sub/gitdir"), file("w/config.worktree"),
            file("app/config"), file("app/settings.json"),
        ]
        let kept = Set(SyncGitFilter.apply(files).map(\.path))
        #expect(kept == ["x/HEAD", "app/config", "app/settings.json"])
    }

    @Test("Nombres Unicode que el Mac trata como HEAD/hooks/.git tampoco cuelan")
    func unicodeFolding() {
        // Ancho completo (ＨＥＡＤ / ｈｏｏｋｓ) y mayúsculas mezcladas.
        let files = [
            file("x/\u{FF28}\u{FF25}\u{FF21}\u{FF24}"), file("x/config"), file("x/\u{FF48}\u{FF4F}\u{FF4F}\u{FF4B}\u{FF53}/pre-commit"),
            file(".GiT/hooks/post-checkout"), file("ok.txt"),
        ]
        let kept = Set(SyncGitFilter.apply(files).map(\.path))
        #expect(!kept.contains("x/config"))
        #expect(!kept.contains(".GiT/hooks/post-checkout"))
        #expect(kept.contains("ok.txt"))
        #expect(SyncExclusions.isUploadExcluded(".GIT/Config"))
    }

    @Test("Un enlace sin tocar no se vuelve a subir (fecha y permisos del enlace no cuentan)")
    func symlinkMatchesByTargetOnly() {
        let server = file("link.ts", size: 10, mtime: 100, mode: 0o777, link: "src/app.ts")
        let onMac = file("link.ts", size: 10, mtime: 999, mode: 0o755, link: "src/app.ts")
        #expect(onMac.matches(server))
        #expect(!file("link.ts", link: "src/otro.ts").matches(server))
        #expect(!file("link.ts").matches(server))
        let plan = SyncPlanner.plan(manifest: ["link.ts": server], local: [onMac], server: [server])
        #expect(plan.isEmpty)
    }

    @Test("Resumen de Enviar al Mac: carpeta vacía, singular y plural")
    func toMacSummaryText() {
        #expect(SyncSummaryText.toMac(fileCount: 0, kilobytes: "0 KB").contains("vacía"))
        #expect(SyncSummaryText.toMac(fileCount: 1, kilobytes: "4 KB") == "1 archivo · 4 KB")
        #expect(SyncSummaryText.toMac(fileCount: 126, kilobytes: "45 MB") == "126 archivos · 45 MB")
    }

    @Test("AppleScript de Terminal: ruta con comillas y espacios bien escapada")
    func terminalScriptEscaping() {
        let script = LocalTerminalLauncher.script(folder: "/Users/a/Mis \"proy\" d'Ana")
        #expect(script.contains(#"tell application id "com.apple.Terminal""#))
        // Shell: 'd'\''Ana'; AppleScript: \" y \\ escapados.
        #expect(script.contains(#"do script "cd '/Users/a/Mis \"proy\" d'\\''Ana' && claude""#))
    }
}
