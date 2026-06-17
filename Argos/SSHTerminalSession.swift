//
//  SSHTerminalSession.swift
//  Argos
//
//  Fase 2: abre un PTY sobre SSH (Citadel) y dentro corre `tmux attach -t <sesión>`,
//  conectando el flujo bidireccional entre el PTY remoto y el TerminalView local.
//
//  API REAL de Citadel/NIOSSH utilizada (leída del código fuente de los paquetes):
//   - SSHClient.withPTY(_:environment:perform:)              (Citadel/TTY/Client/TTY.swift)
//        · `inbound: TTYOutput`  -> AsyncSequence de `ExecCommandOutput` (.stdout/.stderr)
//        · `outbound: TTYStdinWriter`
//   - TTYStdinWriter.write(_ buffer: ByteBuffer)             -> escribe en el stdin del PTY
//   - TTYStdinWriter.changeSize(cols:rows:pixelWidth:pixelHeight:)
//        · internamente dispara SSHChannelRequestEvent.WindowChangeRequest (window-change)
//   - SSHChannelRequestEvent.PseudoTerminalRequest(...)      (swift-nio-ssh)
//   - SSHTerminalModes([.ECHO: 1, ...])                      (swift-nio-ssh)
//
//  NOTA macOS 15: `withPTY` y `TTYOutput` están marcados @available(macOS 15.0, *);
//  por eso el deployment target del proyecto es macOS 15.
//

import Foundation
import os
import Citadel
import NIOCore   // ByteBuffer
import NIOSSH    // SSHChannelRequestEvent, SSHTerminalModes

/// Evento que viaja desde el TerminalView (UI) hacia el PTY remoto.
///
/// Es `Sendable` para poder cruzar la frontera del actor `SSHService` a través de
/// un `AsyncStream`.
enum TerminalControlEvent: Sendable {
    /// Bytes tecleados por el usuario que deben escribirse en el stdin del PTY.
    case input([UInt8])
    /// Nuevo tamaño del terminal (window-change) tras redimensionar el NSView.
    case resize(cols: Int, rows: Int)
}

extension SSHService {

    /// Abre un PTY interactivo sobre SSH y corre `tmux attach -t <sesión>` dentro.
    ///
    /// Conecta el flujo bidireccional:
    ///  - salida del PTY (stdout/stderr) -> `output` (la consume el TerminalView con `feed`)
    ///  - eventos de `control` (teclas / resize) -> stdin del PTY / window-change
    ///
    /// Ciclo de vida (detach, NO kill):
    ///  - Cuando la `Task` que invoca este método se cancela (cambio de sesión / cierre
    ///    del detail), el bucle de lectura termina cooperativamente, el closure de
    ///    `withPTY` retorna y Citadel **cierra el canal**. Al cerrarse el PTY, el
    ///    `tmux attach` remoto recibe SIGHUP y tmux **desengancha a este cliente**; la
    ///    sesión de tmux sigue viva en el servidor (solo `tmux kill-session` la mataría).
    ///  - Si el usuario hace detach desde dentro de tmux, `tmux attach` termina, el shell
    ///    `exec`-utado sale, el PTY emite EOF y el bucle de lectura finaliza igualmente.
    ///
    /// - Parameters:
    ///   - name: nombre de la sesión tmux a la que adjuntarse.
    ///   - initialCols/initialRows: tamaño inicial del PTY (se corrige luego con resize).
    ///   - control: stream de teclas y cambios de tamaño provenientes del TerminalView.
    ///   - output: continuación a la que se entregan los bytes de salida del PTY.
    func attachTerminal(
        session name: String,
        initialCols: Int,
        initialRows: Int,
        control: AsyncStream<TerminalControlEvent>,
        output: AsyncStream<[UInt8]>.Continuation
    ) async throws {
        let client = try await connectedClient()

        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: max(initialCols, 1),
            terminalRowHeight: max(initialRows, 1),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([.ECHO: 1, .ICRNL: 1])
        )

        // Garantiza que el consumidor de salida (el feeder del TerminalView) termine
        // pase lo que pase con la conexión.
        defer { output.finish() }

        try await client.withPTY(request) { inbound, outbound in
            // Lanzamos `tmux attach` dentro del shell del PTY. `exec` reemplaza el shell
            // por tmux para que, al desengancharse, el canal se cierre limpiamente.
            // El nombre va entrecomillado para resistir espacios/caracteres especiales.
            let command = "exec tmux attach -t \(ShellQuoting.singleQuoted(name))\n"
            try await outbound.write(ByteBuffer(string: command))

            try await withThrowingTaskGroup(of: Void.self) { group in
                // PTY -> TerminalView: reenvía cada chunk de salida.
                group.addTask {
                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buffer), .stderr(let buffer):
                            if let bytes = buffer.getBytes(
                                at: buffer.readerIndex,
                                length: buffer.readableBytes
                            ), !bytes.isEmpty {
                                output.yield(bytes)
                            }
                        }
                    }
                }

                // TerminalView -> PTY: teclas a stdin y resize a window-change.
                // Tragamos errores aquí: si el canal se está cerrando perdiendo la
                // carrera, no queremos enmascarar la causa real (EOF del lector).
                group.addTask {
                    do {
                        for await event in control {
                            switch event {
                            case .input(let bytes):
                                try await outbound.write(ByteBuffer(bytes: bytes))
                            case .resize(let cols, let rows):
                                guard cols > 0, rows > 0 else { continue }
                                try await outbound.changeSize(
                                    cols: cols,
                                    rows: rows,
                                    pixelWidth: 0,
                                    pixelHeight: 0
                                )
                            }
                        }
                    } catch is CancellationError {
                        // Cancelación cooperativa: fin normal del trabajo de escritura.
                    } catch {
                        // El canal suele estar cerrándose (lo habitual), pero podría ser
                        // un error real de protocolo/backpressure: lo registramos en vez
                        // de tragarlo en silencio para poder diagnosticar un PTY mudo.
                        Log.terminal.debug("Fin de escritura al PTY: \(String(describing: error), privacy: .public)")
                    }
                }

                // En cuanto una rama termina (EOF del PTY, o cancelación), paramos la otra.
                // `withPTY` cerrará el canal al retornar -> detach (la sesión tmux persiste).
                _ = try await group.next()
                group.cancelAll()
            }
        }
    }

}
