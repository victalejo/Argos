//
//  SessionContextTests.swift
//  ArgosTests
//
//  Contexto al arrancar Claude: la fusión del hook `SessionStart` en settings.json (aparte
//  del indicador y de los puntos) y la vista previa (lógica pura). El script se prueba
//  ejecutándolo con sh y dash en `SessionContextScriptTests`.
//

import Foundation
import Testing
@testable import Argos

@Suite("Contexto al arrancar Claude: hook y vista previa")
struct SessionContextHookTests {

    private var userSettings: [String: Any] {
        [
            "model": "opus",
            "env": ["TOKEN": "secreto"],
            "hooks": [
                "SessionStart": [["matcher": "startup", "hooks": [["type": "command", "command": "mi-script.sh"]]]],
            ] as [String: Any],
        ]
    }

    private func sessionGroups(_ settings: [String: Any]) -> [[String: Any]] {
        (settings["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]] ?? []
    }

    @Test func seInstalaUnaSolaVezYConservaLoDelUsuario() {
        let once = SessionContextHookInstaller.installing(into: userSettings)
        let twice = SessionContextHookInstaller.installing(into: once)
        #expect(SessionContextHookInstaller.isInstalled(in: twice))
        #expect(sessionGroups(twice).count == 2)
        #expect(sessionGroups(twice).first?["matcher"] as? String == "startup")
        #expect(sessionGroups(twice).last?["matcher"] as? String == "startup|resume|clear|compact")
        #expect(twice["model"] as? String == "opus")
        #expect((twice["env"] as? [String: String])?["TOKEN"] == "secreto")
    }

    @Test func quitarloDejaElDelUsuarioYNadaVacio() {
        let removed = SessionContextHookInstaller.removing(from: SessionContextHookInstaller.installing(into: userSettings))
        #expect(!SessionContextHookInstaller.hasAny(in: removed))
        #expect(sessionGroups(removed).count == 1)
        let fromEmpty = SessionContextHookInstaller.removing(from: SessionContextHookInstaller.installing(into: [:]))
        #expect(fromEmpty["hooks"] == nil)
    }

    @Test func reinstalarOQuitarElIndicadorNoLoToca() {
        let withContext = SessionContextHookInstaller.installing(into: ClaudeHookInstaller.installing(into: userSettings))
        let reinstalled = ClaudeHookInstaller.installing(into: withContext)
        #expect(SessionContextHookInstaller.isInstalled(in: reinstalled))
        #expect(SessionContextHookInstaller.isInstalled(in: ClaudeHookInstaller.removing(from: withContext)))
        #expect(SessionContextHookInstaller.isInstalled(in: CheckpointHookInstaller.removing(from: withContext)))
        // Y al revés: quitar el contexto deja el indicador.
        #expect(ClaudeHookInstaller.isInstalled(in: SessionContextHookInstaller.removing(from: withContext)))
        // Una versión vieja del indicador lo reconoce por su marca, que el contexto no lleva.
        #expect(!SessionContextHookInstaller.command.contains(ClaudeHookInstaller.marker))
        #expect(!SessionContextHookInstaller.command.contains(CheckpointHookInstaller.marker))
    }

    @Test func unaVersionAnteriorDelHookCuentaComoDesactualizada() {
        var settings = SessionContextHookInstaller.installing(into: [:])
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        hooks["SessionStart"] = [["hooks": [["type": "command", "command": "viejo # argos-session-context"]]]]
        settings["hooks"] = hooks
        #expect(SessionContextHookInstaller.hasAny(in: settings))
        #expect(!SessionContextHookInstaller.isInstalled(in: settings))
        #expect(sessionGroups(SessionContextHookInstaller.installing(into: settings)).count == 1)
    }

    @Test func elComandoNuncaFallaNiEnsuciaStderr() {
        let command = SessionContextHookInstaller.command
        #expect(command.hasSuffix("exit 0 # argos-session-context"))
        #expect(command.contains("2>/dev/null"))
        #expect(command.contains(SessionContextScript.installedRelativePath))
    }

    @Test func laVistaPreviaQuitaControlesYRecorta() {
        let raw = "Contexto\u{1B}[31m\n- rama \u{202E}abc\u{0007}\r\n\n" + String(repeating: "x", count: 9000)
        let preview = SessionContextPreview(output: raw)
        #expect(!preview.text.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" && $0 != "\t" })
        #expect(!preview.text.contains("\u{202E}"))
        #expect(preview.text.hasPrefix("Contexto[31m\n- rama abc"))
        #expect(preview.text.count == SessionContextPreview.maxDisplayCharacters)
        #expect(SessionContextPreview(output: " \n\n").isEmpty)
    }

    @Test func laVistaPreviaEntrecomillaLaCarpeta() {
        let command = SessionContextScript.previewCommand(projectPath: "/home/u/a b'; rm -rf ~")
        #expect(command.contains(ShellQuoting.singleQuoted("/home/u/a b'; rm -rf ~")))
        #expect(command.hasSuffix("exit 0"))
    }

    @Test func activadoExigeHookYScriptYQueNoEsteApagado() {
        #expect(SessionContextStatus(hookInstalled: true, scriptPresent: true, turnedOff: false).isEnabled)
        #expect(!SessionContextStatus(hookInstalled: true, scriptPresent: false, turnedOff: false).isEnabled)
        #expect(!SessionContextStatus(hookInstalled: true, scriptPresent: true, turnedOff: true).isEnabled)
        // Sin decidir: ni hook ni marca de apagado (indicador de antes de esta función).
        #expect(SessionContextStatus(hookInstalled: false, scriptPresent: true, turnedOff: false).isUndecided)
        #expect(!SessionContextStatus(hookInstalled: false, scriptPresent: false, turnedOff: true).isUndecided)
        #expect(!SessionContextStatus(hookInstalled: true, scriptPresent: true, turnedOff: false).isUndecided)
    }

    @Test func elHookTienePlazoCortoYLaMarcaSeMiraComoEnElScript() {
        #expect(SessionContextHookInstaller.timeout == 5)
        #expect(SessionContextScript.flagsCommand.contains("[ -e \"$HOME/.config/argos/session-context.off\" ]"))
        #expect(SessionContextScript.source.contains("[ -e \"$cfg/session-context.off\" ] && exit 0"))
    }

    @MainActor
    @Test func elModeloCambiaElEstadoYAvisaDelFallo() async {
        let model = SessionContextModel(service: MockSSHService())
        await model.refresh()
        #expect(model.status?.isEnabled == false)
        #expect(model.status?.isUndecided == true)
        await model.setEnabled(true)
        // El doble no lo admite: se avisa y se vuelve a leer el estado real.
        #expect(model.notice != nil)
        #expect(model.isEnabled == false)
        await model.loadPreview(projectPath: "/p")
        #expect(model.preview?.isEmpty == true)
    }
}
