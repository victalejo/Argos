//
//  WindowManagementTests.swift
//  ArgosTests
//
//  Comandos tmux de gestión de ventanas (nueva en el mismo directorio, renombrar,
//  color) y validación de nombres de ventana. Lógica pura: fija el contrato del
//  comando exacto que se envía al servidor.
//

import Testing
@testable import Argos

@Suite("Gestión de ventanas tmux")
struct WindowManagementTests {

    @Test("Nueva ventana hereda el directorio del panel activo")
    func newWindowInheritsDirectory() {
        #expect(
            SSHService.newWindowCommand(session: "roomies")
                == "tmux new-window -t 'roomies' -c '#{pane_current_path}'"
        )
    }

    @Test("Renombrar apunta a sesión:índice y entrecomilla el nombre")
    func renameWindow() {
        #expect(
            SSHService.renameWindowCommand(session: "a b", index: 2, name: "it's")
                == "tmux rename-window -t 'a b':2 'it'\\''s'"
        )
    }

    @Test("Cerrar ventana apunta a sesión:índice")
    func killWindow() {
        #expect(
            SSHService.killWindowCommand(session: "a b", index: 3)
                == "tmux kill-window -t 'a b':3"
        )
    }

    @Test("Fijar color guarda la opción de usuario @argos_color en la ventana")
    func setColor() {
        #expect(
            SSHService.windowColorCommand(session: "dev", index: 1, color: .green)
                == "tmux set-option -w -t 'dev':1 @argos_color 'green'"
        )
    }

    @Test("Quitar color borra la opción (-u)")
    func clearColor() {
        #expect(
            SSHService.windowColorCommand(session: "dev", index: 1, color: nil)
                == "tmux set-option -wu -t 'dev':1 @argos_color"
        )
    }

    @Test("El formato de list-windows lleva el nombre al final")
    func listFormatNameLast() {
        #expect(SSHService.listWindowsFormat.hasSuffix("|#{window_name}"))
        #expect(SSHService.listWindowsFormat.contains("#{@argos_color}"))
    }

    @Test("El formato de list-windows incluye el proceso en primer plano")
    func listFormatIncludesCommand() {
        #expect(SSHService.listWindowsFormat.contains("|#{pane_current_command}|"))
    }

    @Test("Ventana con agente: nombre fijo, carpeta del proyecto y teclea el binario")
    func newAgentWindowInProject() {
        #expect(
            SSHService.newAgentWindowCommand(session: "roomies", agent: .claude, directory: "/srv/it's")
                == "idx=$(tmux new-window -P -F '#{window_index}' -t 'roomies' -c '/srv/it'\\''s' "
                + "-n 'Claude Code') && tmux send-keys -t 'roomies':\"$idx\" 'claude' Enter"
        )
    }

    @Test("Ventana con agente sin carpeta usa la del panel activo")
    func newAgentWindowInheritsDirectory() {
        let command = SSHService.newAgentWindowCommand(session: "dev", agent: .codex, directory: nil)
        #expect(command.contains("-c '#{pane_current_path}'"))
        #expect(command.contains("-n 'Codex'"))
        #expect(command.hasSuffix("'codex' Enter"))
    }

    @Test("Rama git entrecomilla la ruta")
    func gitBranchCommand() {
        #expect(
            SSHService.gitBranchCommand(path: "/srv/a b")
                == "git -C '/srv/a b' rev-parse --abbrev-ref HEAD 2>/dev/null"
        )
    }

    @Test("Nombres de ventana válidos", arguments: ["claude", "api: logs", "v1.2", "a|b"])
    func validNames(name: String) {
        #expect(WindowNameValidator.isValid(name))
    }

    @Test("Nombres de ventana inválidos", arguments: ["", "   ", "-x", "a\nb", "a\tb"])
    func invalidNames(name: String) {
        #expect(!WindowNameValidator.isValid(name))
    }

    @Test("Todos los colores se identifican por su rawValue")
    func colorsRoundTrip() {
        for color in WindowColor.allCases {
            #expect(WindowColor(rawValue: color.rawValue) == color)
        }
    }

    @Test("Rama git: última línea; HEAD desacoplado o vacío => nil")
    func parseGitBranch() {
        #expect(SSHService.parseGitBranch("motd\nfeat/x\n") == "feat/x")
        #expect(SSHService.parseGitBranch("HEAD\n") == nil)
        #expect(SSHService.parseGitBranch("") == nil)
    }
}
