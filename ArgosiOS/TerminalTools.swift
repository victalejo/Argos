//
//  TerminalTools.swift
//  ArgosiOS
//
//  «Buscar en el historial» (lupa y ⌘F con teclado físico) y «Copiar la salida del último
//  comando» en el terminal del iPhone/iPad, más las marcas de prompt OSC 133 del servidor.
//  La lógica vive en ArgosCore (`TerminalSearchModel`, `TerminalLastOutputModel`,
//  `ShellIntegrationModel`) y la barra en ArgosUI (`TerminalSearchBar`).
//

import SwiftUI
import UIKit

/// Los modelos de las herramientas del terminal de una sesión.
@MainActor
@Observable
final class TerminalTools {
    let search: TerminalSearchModel
    let lastOutput: TerminalLastOutputModel
    let marks: ShellIntegrationModel
    let sessionName: String

    init(service: any SSHServicing, sessionName: String) {
        let runner: TerminalSearchModel.Runner = { (script: String) in try await service.runTerminalCommand(script) }
        self.sessionName = sessionName
        search = TerminalSearchModel(sessionName: sessionName, run: runner)
        lastOutput = TerminalLastOutputModel(run: runner)
        marks = ShellIntegrationModel(service: service)
    }

    func openSearch(window: Int?) {
        withAnimation(.snappy) { search.present(window: window) }
    }

    func findNext(window: Int?) {
        search.isPresented ? search.next() : openSearch(window: window)
    }

    func findPrevious(window: Int?) {
        search.isPresented ? search.previous() : openSearch(window: window)
    }

    func copyLastOutput(window: Int?, agent: CodingAgent?) {
        let target = TerminalPaneTarget(session: sessionName, window: window)
        let kind: TerminalLastOutput.Kind = agent == .claude ? .claude : .shell
        let navigate = marks.isEnabled
        let model = lastOutput
        Task { await model.copyLastOutput(target: target, kind: kind, navigateMarks: navigate, copy: Self.copyToPasteboard) }
    }

    func setMarks(_ enabled: Bool) {
        let marks = self.marks
        let notice = lastOutput
        Task {
            await marks.setEnabled(enabled)
            if let error = marks.errorMessage {
                marks.errorMessage = nil
                notice.notify(error, isError: true)
            } else {
                notice.notify(ShellIntegrationModel.resultMessage(enabled: enabled), isError: false)
            }
        }
    }

    static func copyToPasteboard(_ text: String) {
        UIPasteboard.general.string = text
    }
}

/// Barra de búsqueda arriba y aviso de copiado abajo, sobre el terminal.
struct TerminalToolsOverlay: View {
    let tools: TerminalTools
    /// Tras cerrar la barra: el teclado vuelve al terminal.
    let onClose: () -> Void

    var body: some View {
        ZStack {
            if tools.search.isPresented {
                VStack {
                    TerminalSearchBar(model: tools.search, copy: TerminalTools.copyToPasteboard, onClose: onClose)
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let message = tools.lastOutput.message {
                VStack {
                    Spacer()
                    TerminalNoticeCapsule(message: message, isError: tools.lastOutput.isError)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .onTapGesture { tools.lastOutput.dismiss() }
                }
                .transition(.opacity)
            }
        }
    }
}

/// Menú de las herramientas en «Opciones»: copiar la última salida y las marcas.
struct TerminalToolsMenuItems: View {
    let tools: TerminalTools
    let window: Int?
    let agent: CodingAgent?

    var body: some View {
        Button("Copiar la salida del último comando", systemImage: "doc.on.doc") {
            tools.copyLastOutput(window: window, agent: agent)
        }
        Toggle("Marcas de prompt (OSC 133)", systemImage: "text.line.first.and.arrowtriangle.forward", isOn: marksBinding)
            .disabled(tools.marks.status == nil || tools.marks.isBusy)
        Text("Instala en .zshrc/.bashrc del servidor (con copia) un bloque que marca prompts y salidas: copiar la última salida es exacto.")
    }

    private var marksBinding: Binding<Bool> {
        Binding<Bool>(
            get: { tools.marks.isEnabled },
            set: { (enabled: Bool) in tools.setMarks(enabled) }
        )
    }
}
