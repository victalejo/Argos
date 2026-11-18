//
//  IntegrationTmuxTests.swift
//  ArgosTests
//
//  tmux real del servidor de pruebas (socket aislado por `TMUX_TMPDIR`): `~/.tmux.conf`
//  base, ajuste del portapapeles idempotente, sesiones y ventanas, `send-keys`, hooks de
//  estado de Claude (`ClaudeStatus/`) y el plazo remoto de los sondeos con un tmux colgado.
//  Sin tmux en el servidor, las pruebas no hacen nada (el CI de macOS lo instala).
//

import Foundation
import Testing
@testable import Argos

extension IntegrationServerSuites {

@Suite("tmux y estado de Claude")
struct Tmux {

    /// Conexión con tmux disponible (`nil` si el servidor no lo tiene).
    private func tmuxBox(_ label: String) async throws -> RemoteBox? {
        let box = try await RemoteBox.open(label)
        guard try await box.has("tmux") else {
            await box.close()
            return nil
        }
        return box
    }

    private func sessionName() -> String { "it-\(UUID().uuidString.prefix(6).lowercased())" }

    private func overrides(_ box: RemoteBox) async throws -> String {
        try await box.sh("tmux show -g terminal-overrides 2>/dev/null; true")
    }

    @Test("~/.tmux.conf base: se crea si falta y nunca pisa uno existente", .timeLimit(.minutes(1)))
    func defaultConfig() async throws {
        guard let box = try await tmuxBox("tmux-conf") else { return }
        defer { IntegrationCleanup.later { await box.close() } }
        try await box.sh("rm -f \"$HOME/.tmux.conf\"")
        #expect(try await box.service.tmuxConfigExists() == false)
        try await box.service.writeDefaultTmuxConfig()
        #expect(try await box.service.tmuxConfigExists())
        let base = try await box.read("\(box.home)/.tmux.conf")
        #expect(base.contains("set -g mouse on") && base.contains("set -g set-clipboard on"))
        // tmux acepta el archivo tal cual (sin errores de sintaxis).
        let check = try await box.run("tmux -f \"$HOME/.tmux.conf\" -L argos-it-conf new-session -d -s c "
            + "&& tmux -L argos-it-conf show -g mouse; tmux -L argos-it-conf kill-server 2>/dev/null; true")
        #expect(check.stdout.contains("mouse on"), "stderr: \(check.stderr)")

        try await box.write("# mío\n", to: "\(box.home)/.tmux.conf")
        try await box.service.writeDefaultTmuxConfig()
        #expect(try await box.read("\(box.home)/.tmux.conf") == "# mío\n")
        try await box.sh("rm -f \"$HOME/.tmux.conf\"")
    }

    @Test("El ajuste del portapapeles y del color es idempotente", .timeLimit(.minutes(1)))
    func clipboardIdempotent() async throws {
        guard let box = try await tmuxBox("tmux-clip") else { return }
        defer { IntegrationCleanup.later { await box.close() } }
        // Servidor tmux limpio y SIN ~/.tmux.conf: lo añade el ajuste en caliente.
        try await box.sh("tmux kill-server 2>/dev/null; rm -f \"$HOME/.tmux.conf\"; true")
        let name = sessionName()
        try await box.service.createSession(named: name)
        await box.service.enableClipboardForwarding()
        await box.service.enableClipboardForwarding()
        let text = try await overrides(box)
        #expect(text.components(separatedBy: ":Ms=").count - 1 == 1, "Override OSC 52 duplicado: \(text)")
        #expect(text.components(separatedBy: "xterm-256color:Tc").count - 1 == 1, "Override Tc duplicado: \(text)")
        let clipboard = try await box.sh("tmux show -g set-clipboard")
        #expect(clipboard.contains("on"))
        try await box.service.killSession(named: name)
    }

    @Test("Sesiones y ventanas: crear, listar, renombrar, send-keys y cerrar", .timeLimit(.minutes(2)))
    func sessionsAndWindows() async throws {
        guard let box = try await tmuxBox("tmux-crud") else { return }
        defer { IntegrationCleanup.later { await box.close() } }
        let name = sessionName()
        // Espacio y acento: sin `tmux -u`, un servidor sin locale UTF-8 lo listaba «dise_o».
        let renamed = name + " diseño"
        try await box.service.createSession(named: name)
        // Otra sesión cuyo nombre EMPIEZA igual: las acciones no deben tocarla.
        try await box.service.createSession(named: name + "x")
        #expect(try await box.service.listSessions().contains { $0.name == name })
        await #expect(throws: (any Error).self) { try await box.service.createSession(named: name) }

        try await box.service.renameSession(from: name, to: renamed)
        let sessions = try await box.service.listSessions().map(\.name)
        #expect(sessions.contains(renamed) && !sessions.contains(name) && sessions.contains(name + "x"))

        try await box.service.newWindow(session: renamed)
        var windows = try await box.service.listWindows(session: renamed)
        #expect(windows.count == 2)
        let second = try #require(windows.last)
        try await box.service.renameWindow(session: renamed, index: second.index, to: "ventana ñ|rara")
        windows = try await box.service.listWindows(session: renamed)
        #expect(windows.last?.name == "ventana ñ|rara")

        try await box.service.sendKeys(session: renamed, keys: "printf 'hola-%s\\n' mundo", enter: true)
        let shown = try await eventually(seconds: 10) {
            try await box.service.capturePaneText(session: renamed).contains("hola-mundo")
        }
        #expect(shown)

        try await box.service.killWindow(session: renamed, index: second.index)
        #expect(try await box.service.listWindows(session: renamed).count == 1)
        try await box.service.killSession(named: renamed)
        let left = try await box.service.listSessions().map(\.name)
        #expect(!left.contains(renamed) && left.contains(name + "x"))
        try await box.service.killSession(named: name + "x")

        // Proyecto en una carpeta con acentos: arranca en ella y se lee su ruta intacta.
        let folder = box.absolute("carpeta ñandú")
        try await box.sh("mkdir -p \(box.q(folder))")
        let project = name + "-proyecto"
        try await box.service.startProject(sessionName: project, path: folder, startupCommand: "echo arrancado")
        #expect(try await box.service.sessionFirstPanePaths()[project] == folder)
        await #expect(throws: ProjectError.missingFolder(folder + "-no")) {
            try await box.service.startProject(sessionName: project + "2", path: folder + "-no", startupCommand: nil)
        }
        try await box.service.stopSession(named: project)
    }

    @Test("Hooks de Claude: instalar, comprobar y leer el estado que escribe un hook", .timeLimit(.minutes(2)))
    func claudeHooks() async throws {
        guard let box = try await tmuxBox("tmux-hooks") else { return }
        defer { IntegrationCleanup.later { await box.close() } }
        try await box.sh("rm -rf \"$HOME/.claude\" && mkdir -p \"$HOME/.claude\" "
            + "&& printf '%s' '{\"model\":\"opus\",\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo ajeno\"}]}]}}' "
            + "> \"$HOME/.claude/settings.json\"")
        #expect(try await box.service.claudeHooksInstalled() == false)
        try await box.service.installClaudeHooks()
        #expect(try await box.service.claudeHooksInstalled())
        #expect(try await box.service.upgradeClaudeHooksIfOutdated() == false)
        let settings = try await box.read("\(box.home)/.claude/settings.json")
        #expect(settings.contains("echo ajeno") && settings.contains("\"model\""), "Se conserva lo del usuario")
        #expect(try await box.exists("\(box.home)/.claude/settings.json.argos-backup"))

        let name = sessionName()
        try await box.service.createSession(named: name)
        let pane = try await box.sh("tmux list-panes -t \(box.q("=" + name)) -F '#{pane_id}'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(pane.hasPrefix("%"))

        // El hook tal como lo ejecutaría Claude Code dentro del panel.
        func hook(_ state: ClaudeActivity?) async throws {
            try await box.sh("TMUX_PANE=\(box.q(pane)) sh -c \(box.q(ClaudeHookInstaller.command(setting: state)))")
        }
        try await hook(.waiting)
        #expect(try await box.service.claudeActivity().activity(forSession: name) == .waiting)

        // «Trabajando» con la pantalla de Claude ocupada; sin ella, el sondeo lo da por terminado.
        try await hook(.working)
        #expect(try await box.service.claudeActivity().activity(forSession: name) == .done)
        try await box.service.sendKeys(session: name, keys: "clear; echo '✻ Pensando… (esc to interrupt)'", enter: true)
        let busy = try await eventually(seconds: 10) {
            try await box.service.claudeActivity().activity(forSession: name) == .working
        }
        #expect(busy)

        try await hook(nil)
        #expect(try await box.service.claudeActivity().activity(forSession: name) == nil)
        try await box.service.killSession(named: name)
        try await box.sh("rm -rf \"$HOME/.claude\"")
    }

    @Test("Un tmux colgado no deja el sondeo esperando: el plazo remoto lo corta",
          .enabled(if: IntegrationRemote.isLinux, IntegrationRemote.linuxOnly), .timeLimit(.minutes(3)))
    func hungTmuxIsCutByRemoteTimeout() async throws {
        guard let box = try await tmuxBox("tmux-hung") else { return }
        defer { IntegrationCleanup.later { await box.close() } }
        // `tmux` colgado en la carpeta propia del PATH (por delante del real).
        let fake = (box.home as NSString).deletingLastPathComponent + "/bin/tmux"
        try await box.write("#!/bin/sh\nsleep 599\n", to: fake)
        try await box.sh("chmod 755 \(box.q(fake))")
        let start = ContinuousClock.now
        var thrown: Error?
        do { _ = try await box.service.listSessions() } catch { thrown = error }
        let elapsed = ContinuousClock.now - start
        try await box.sh("rm -f \(box.q(fake))")

        #expect(elapsed < .seconds(RemoteTimeout.pollSeconds + 20), "Tardó \(elapsed)")
        #expect(thrown as? SSHConnectionError == .commandTimedOut(.seconds(RemoteTimeout.pollSeconds)),
                "Debe informarse como plazo vencido: \(String(describing: thrown))")
        let left = try await box.sh("ps -eo args= | grep -e \(box.q(fake)) -e '^sleep 599' | grep -v grep; true")
        #expect(left.isEmpty, "El tmux colgado sigue vivo: \(left)")
    }
}

}
