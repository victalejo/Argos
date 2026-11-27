//
//  TerminalFindCommands.swift
//  Argos
//
//  Menú «Terminal» de la barra de menús: «Buscar en el historial…» (⌘F), siguiente y
//  anterior (⌘G / ⇧⌘G), «Copiar la salida del último comando» (⌥⌘C) y las marcas de
//  prompt del servidor. El terminal a la vista publica sus acciones con
//  `focusedSceneValue(\.terminalFindActions, …)`.
//
//  Si el foco está en un editor de texto con su propia barra de búsqueda (el visor de
//  archivos), ⌘F/⌘G se le reenvían: este menú no se las quita.
//

import AppKit
import SwiftUI

/// Acciones de búsqueda del terminal a la vista. `Equatable` por `identity` (ver
/// `TabActions`): sin ello la barra de menús se reconstruiría en cada redibujado.
struct TerminalFindActions: Equatable {
    var identity: AnyHashable
    var find: () -> Void
    var findNext: () -> Void
    var findPrevious: () -> Void
    var copyLastOutput: () -> Void
    /// `nil` mientras no se sabe si las marcas están instaladas.
    var marksEnabled: Bool?
    var setMarks: (Bool) -> Void

    static func == (lhs: TerminalFindActions, rhs: TerminalFindActions) -> Bool {
        lhs.identity == rhs.identity
    }
}

extension FocusedValues {
    @Entry var terminalFindActions: TerminalFindActions?
}

struct TerminalFindCommands: Commands {
    @FocusedValue(\.terminalFindActions) private var actions

    var body: some Commands {
        CommandMenu("Terminal") {
            Button("Buscar en el historial…") { perform(NSFindPanelAction.showFindPanel) { $0.find() } }
                .keyboardShortcut("f", modifiers: .command)
            Button("Buscar siguiente") { perform(NSFindPanelAction.next) { $0.findNext() } }
                .keyboardShortcut("g", modifiers: .command)
            Button("Buscar anterior") { perform(NSFindPanelAction.previous) { $0.findPrevious() } }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Copiar la salida del último comando") { actions?.copyLastOutput() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(actions == nil)
            Toggle("Marcas de prompt en el servidor (OSC 133)", isOn: marksBinding)
                .disabled(actions?.marksEnabled == nil)
        }
    }

    private var marksBinding: Binding<Bool> {
        Binding<Bool>(
            get: { actions?.marksEnabled ?? false },
            set: { (enabled: Bool) in actions?.setMarks(enabled) }
        )
    }

    /// Con un editor de texto con barra de búsqueda enfocado, le reenvía la orden; si no,
    /// la hace el terminal.
    private func perform(_ action: NSFindPanelAction, terminal: (TerminalFindActions) -> Void) {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView, !textView.isFieldEditor, textView.usesFindBar {
            let item = NSMenuItem()
            item.tag = Int(action.rawValue)
            textView.performFindPanelAction(item)
            return
        }
        if let actions {
            terminal(actions)
        } else {
            NSSound.beep()
        }
    }
}
