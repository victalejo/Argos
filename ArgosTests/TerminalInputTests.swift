//
//  TerminalInputTests.swift
//  ArgosTests
//
//  «Seleccionar texto» (capture-pane) y adjuntos del terminal en iPhone/iPad.
//

import Foundation
import Testing
@testable import Argos

@Suite("Terminal iOS: texto y adjuntos")
struct TerminalInputTests {

    @Test func capturaElPanelActivoConTargetExactoYEntrecomillado() {
        let command = SSHService.capturePaneCommand(session: "web/api", lines: 3000)
        #expect(command == "tmux capture-pane -p -J -S -3000 -t '=web/api:'")
        let hostile = SSHService.capturePaneCommand(session: "x'; rm -rf ~; '", lines: 10)
        #expect(hostile.hasSuffix("-t '=x'\\''; rm -rf ~; '\\'':'"))
        #expect(SSHService.capturePaneCommand(session: "a", lines: -5).contains("-S -0 "))
    }

    @Test func quitaLasLineasVaciasDelFinal() {
        #expect(SSHService.trimmingTrailingBlankLines("hola\n  \nmundo\n\n   \n") == "hola\n  \nmundo")
        #expect(SSHService.trimmingTrailingBlankLines("\n\n") == "")
    }

    @Test func nombreDeFotoConFechaYExtensionSaneada() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let utc = TimeZone(identifier: "UTC")!
        #expect(TerminalAttachment.photoFileName(fileExtension: "HEIC", date: date, timeZone: utc) == "foto-20270115-080000.heic")
        #expect(TerminalAttachment.photoFileName(fileExtension: nil, date: date, timeZone: utc) == "foto-20270115-080000.jpg")
        #expect(TerminalAttachment.photoFileName(fileExtension: "../x", date: date, timeZone: utc) == "foto-20270115-080000.x")
    }

    @Test func avisaDeArchivosDemasiadoGrandes() {
        #expect(TerminalAttachment.tooLargeMessage(fileName: "video.mov").contains("100 MB"))
    }
}
