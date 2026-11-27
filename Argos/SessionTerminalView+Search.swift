//
//  SessionTerminalView+Search.swift
//  Argos
//
//  «Buscar en el historial» (⌘F, ⌘G, ⇧⌘G) y «Copiar la salida del último comando» (⌥⌘C)
//  en el terminal del Mac: la barra sobre el terminal, el aviso de copiado, las acciones
//  del menú «Terminal» y el enlace con el «Buscar» del propio `TerminalView`.
//

import AppKit
import SwiftUI

extension SessionTerminalView {

    /// Barra de búsqueda arriba y aviso de copiado abajo.
    @ViewBuilder
    var searchOverlay: some View {
        if search.isPresented {
            VStack {
                HStack {
                    Spacer(minLength: 0)
                    TerminalSearchBar(model: search, copy: Self.copyToPasteboard, onClose: focusTerminal)
                        .frame(maxWidth: 560)
                }
                .padding(.top, 10)
                .padding(.horizontal, 12)
                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        if let message = lastOutput.message {
            VStack {
                Spacer()
                TerminalNoticeCapsule(message: message, isError: lastOutput.isError)
                    .padding(.bottom, 14)
                    .onTapGesture { lastOutput.dismiss() }
            }
            .transition(.opacity)
        }
    }

    /// Acciones del menú «Terminal».
    var findActions: TerminalFindActions? {
        guard isConnected else { return nil }
        return TerminalFindActions(
            identity: AnyHashable(FindIdentity(
                handle: handle,
                window: windowsModel.activeWindow?.index,
                claude: activeAgent == .claude,
                marks: shellMarks.status,
                searching: search.isPresented
            )),
            find: openSearch,
            findNext: { search.isPresented ? search.next() : openSearch() },
            findPrevious: { search.isPresented ? search.previous() : openSearch() },
            copyLastOutput: copyLastOutput,
            marksEnabled: shellMarks.status.map { $0 != .notInstalled },
            setMarks: setShellMarks
        )
    }

    func openSearch() {
        withAnimation(.snappy) { search.present(window: windowsModel.activeWindow?.index) }
    }

    func copyLastOutput() {
        let target = TerminalPaneTarget(session: session.name, window: windowsModel.activeWindow?.index)
        let kind: TerminalLastOutput.Kind = activeAgent == .claude ? .claude : .shell
        let navigate = shellMarks.isEnabled
        let model = lastOutput
        Task { await model.copyLastOutput(target: target, kind: kind, navigateMarks: navigate, copy: Self.copyToPasteboard) }
    }

    /// Instala o quita las marcas de prompt y avisa del resultado.
    func setShellMarks(_ enabled: Bool) {
        let marks = shellMarks
        let notice = lastOutput
        Task {
            await marks.setEnabled(enabled)
            if let error = marks.errorMessage {
                marks.errorMessage = nil
                notice.notify(error, isError: true)
            } else {
                notice.notify(marks.resultMessage(enabled: enabled), isError: enabled && marks.warning != nil)
            }
        }
    }

    /// El «Buscar» del menú Edición con el terminal enfocado abre la barra de Argos.
    func installFindHandler() {
        guard let view = controller?.terminalView else { return }
        let search = self.search
        let open = openSearch
        view.onFindAction = { (action: NSFindPanelAction) in
            switch action {
            case .next: search.isPresented ? search.next() : open()
            case .previous: search.isPresented ? search.previous() : open()
            default: open()
            }
        }
    }

    /// Tras cerrar la barra, el teclado vuelve al terminal.
    func focusTerminal() {
        guard let view = controller?.terminalView else { return }
        view.window?.makeFirstResponder(view)
    }

    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Identidad de `TerminalFindActions`: cambia con la sesión, el estado de las marcas y si
/// la barra está abierta (lo que capturan los closures o muestra el menú).
private struct FindIdentity: Hashable {
    let handle: SessionHandle
    let window: Int?
    let claude: Bool
    let marks: ShellIntegrationStatus?
    let searching: Bool
}
