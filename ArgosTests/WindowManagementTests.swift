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
}
