//
//  SafeLocalFileTests.swift
//  ArgosTests
//
//  Nombres locales de archivos remotos (anti path traversal) y entradas diferidas con
//  la app bloqueada.
//

import Foundation
import Testing
@testable import Argos

@Suite("Nombre local de archivos remotos")
struct SafeLocalFileTests {
    private let folder = URL(fileURLWithPath: "/tmp/argos-compartir/ABC", isDirectory: true)

    @Test("Los nombres hostiles del servidor no salen de la carpeta",
          arguments: ["../../etc/passwd", "/abs/ruta.txt", "..", ".", "", "a\\b", "x\u{0}y", "sub/../../z", "....", "..\\..\\win.ini"])
    func hostileNames(name: String) throws {
        let url = try SafeLocalFile.url(for: name, in: folder)
        #expect(url.deletingLastPathComponent().path == folder.standardizedFileURL.path)
        #expect(!url.lastPathComponent.isEmpty)
        #expect(![".", ".."].contains(url.lastPathComponent))
        #expect(!url.lastPathComponent.contains("/"))
    }

    @Test("Un nombre normal se conserva, con su extensión")
    func normalName() throws {
        #expect(try SafeLocalFile.url(for: "informe final.pdf", in: folder).lastPathComponent == "informe final.pdf")
        #expect(SafeLocalFile.name(for: "../datos.xlsx") == "datos.xlsx")
        #expect(SafeLocalFile.name(for: String(repeating: "a", count: 500) + ".txt").count <= 200)
    }

    @Test("El respaldo conserva solo extensiones seguras")
    func fallback() {
        #expect(SafeLocalFile.fallbackName(for: "x.pdf") == "archivo.pdf")
        #expect(SafeLocalFile.fallbackName(for: "x.p d f") == "archivo")
        #expect(SafeLocalFile.fallbackName(for: "..") == "archivo")
    }
}

@Suite("Entradas con la app bloqueada")
struct AppLockDeferralTests {
    @Test("Bloqueada se encola el enlace o el aviso; desbloqueada se atiende ya")
    func deferral() {
        #expect(AppLockPolicy.shouldDeferIncoming(enabled: true, isLocked: true))
        #expect(!AppLockPolicy.shouldDeferIncoming(enabled: true, isLocked: false))
        #expect(!AppLockPolicy.shouldDeferIncoming(enabled: false, isLocked: true))
        #expect(AppLockPolicy.deferring("argos://x", enabled: true, isLocked: true) == "argos://x")
        #expect(AppLockPolicy.deferring("argos://x", enabled: true, isLocked: false) == nil)
    }
}
