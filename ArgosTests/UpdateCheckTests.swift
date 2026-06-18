//
//  UpdateCheckTests.swift
//  ArgosTests
//

import Foundation
import Testing
@testable import Argos

@Suite("AppVersion (comparación semántica)")
struct AppVersionTests {

    @Test("Parsea con y sin prefijo v")
    func parsesPrefix() throws {
        #expect(AppVersion("v1.2.3")?.components == [1, 2, 3])
        #expect(AppVersion("1.2.3")?.components == [1, 2, 3])
        #expect(AppVersion("V2.0")?.components == [2, 0])
    }

    @Test("Descarta pre-release y build metadata")
    func stripsMetadata() throws {
        #expect(AppVersion("1.0.2-beta.1")?.components == [1, 0, 2])
        #expect(AppVersion("1.0.2+build99")?.components == [1, 0, 2])
    }

    @Test("Cadenas inválidas devuelven nil", arguments: ["", "  ", "v", "1.x.0", "abc", "..", "1..2"])
    func invalidReturnsNil(raw: String) {
        #expect(AppVersion(raw) == nil)
    }

    @Test("Mayor/menor por componentes numéricos")
    func ordering() throws {
        #expect(try #require(AppVersion("1.0.3")) > #require(AppVersion("1.0.2")))
        #expect(try #require(AppVersion("1.1.0")) > #require(AppVersion("1.0.9")))
        #expect(try #require(AppVersion("2.0.0")) > #require(AppVersion("1.9.9")))
        // Comparación numérica, no lexicográfica: 10 > 2.
        #expect(try #require(AppVersion("1.0.10")) > #require(AppVersion("1.0.2")))
    }

    @Test("Igualdad con padding de componentes (1.0 == 1.0.0)")
    func paddedEquality() throws {
        #expect(try #require(AppVersion("1.0")) == #require(AppVersion("1.0.0")))
        #expect(try !(#require(AppVersion("1.0")) < #require(AppVersion("1.0.0"))))
    }
}

@Suite("UpdateChecker.evaluate")
struct UpdateEvaluateTests {

    private func release(tag: String, dmg: Bool = true, body: String = "notas") -> GitHubRelease {
        GitHubRelease(
            tagName: tag,
            htmlURL: "https://github.com/victalejo/Argos/releases/tag/\(tag)",
            body: body,
            assets: dmg
                ? [GitHubRelease.Asset(name: "Argos-1.0.3.dmg",
                                       browserDownloadURL: "https://github.com/victalejo/Argos/releases/download/\(tag)/Argos-1.0.3.dmg")]
                : []
        )
    }

    @Test("Versión remota mayor => actualización disponible con DMG")
    func newer() {
        let state = UpdateChecker.evaluate(release: release(tag: "v1.0.3"), current: "1.0.2")
        guard case .updateAvailable(let info) = state else {
            Issue.record("Se esperaba updateAvailable, fue \(state)")
            return
        }
        #expect(info.version == "v1.0.3")
        #expect(info.downloadURL?.absoluteString.hasSuffix(".dmg") == true)
        #expect(info.notes == "notas")
    }

    @Test("Versión remota igual => al día")
    func equal() {
        #expect(UpdateChecker.evaluate(release: release(tag: "v1.0.2"), current: "1.0.2") == .upToDate)
    }

    @Test("Versión remota menor => al día (no degrada)")
    func older() {
        #expect(UpdateChecker.evaluate(release: release(tag: "v1.0.1"), current: "1.0.2") == .upToDate)
    }

    @Test("Actualización sin DMG adjunto => disponible pero sin downloadURL")
    func noAsset() {
        let state = UpdateChecker.evaluate(release: release(tag: "v1.1.0", dmg: false), current: "1.0.2")
        guard case .updateAvailable(let info) = state else {
            Issue.record("Se esperaba updateAvailable, fue \(state)")
            return
        }
        #expect(info.downloadURL == nil)
    }

    @Test("Tag no parseable => fallo")
    func unparseableTag() {
        let state = UpdateChecker.evaluate(release: release(tag: "latest"), current: "1.0.2")
        guard case .failed = state else {
            Issue.record("Se esperaba failed, fue \(state)")
            return
        }
    }

    @Test("DMG en dominio no-GitHub => se descarta el downloadURL")
    func untrustedDownloadDropped() {
        let release = GitHubRelease(
            tagName: "v1.0.3",
            htmlURL: "https://github.com/victalejo/Argos/releases/tag/v1.0.3",
            body: "x",
            assets: [.init(name: "Argos.dmg", browserDownloadURL: "https://evil.example.com/Argos.dmg")]
        )
        guard case .updateAvailable(let info) = UpdateChecker.evaluate(release: release, current: "1.0.2") else {
            Issue.record("Se esperaba updateAvailable")
            return
        }
        #expect(info.downloadURL == nil)
    }

    @Test("html_url no-GitHub o no-https => no se surfacea (al día)")
    func untrustedReleaseURLSuppressed() {
        let httpRelease = GitHubRelease(
            tagName: "v1.0.3",
            htmlURL: "http://github.com/victalejo/Argos/releases/tag/v1.0.3", // http, no https
            body: "x", assets: []
        )
        #expect(UpdateChecker.evaluate(release: httpRelease, current: "1.0.2") == .upToDate)

        let foreign = GitHubRelease(
            tagName: "v1.0.3",
            htmlURL: "https://evil.example.com/release",
            body: "x", assets: []
        )
        #expect(UpdateChecker.evaluate(release: foreign, current: "1.0.2") == .upToDate)
    }

    @Test("URLs de confianza", arguments: [
        ("https://github.com/x", true),
        ("https://objects.githubusercontent.com/y", true),
        ("https://release-assets.githubusercontent.com/z", true),
        ("http://github.com/x", false),
        ("https://evil.com", false),
        ("https://notgithub.com.evil.com", false),
    ])
    func trustedURLs(raw: String, expected: Bool) throws {
        let url = try #require(URL(string: raw))
        #expect(UpdateChecker.isTrustedGitHubURL(url) == expected)
    }
}
