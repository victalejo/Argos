//
//  TerminalSearchModel.swift
//  ArgosCore
//
//  Estado de la barra «Buscar en el historial» (Mac e iPhone/iPad): el texto, las opciones,
//  «3 de 12» y los resultados por ventana. Conduce el modo copia de tmux con
//  `TerminalSearchCommands` por un canal exec (`run`), nunca por teclas en el PTY.
//
//  Numeración: 1 es la coincidencia MÁS RECIENTE (la búsqueda empieza abajo); «Siguiente»
//  (⌘G, ↑) sube a una más antigua y «Anterior» (⇧⌘G, ↓) baja a una más reciente.
//

import Foundation
import Observation

@MainActor
@Observable
final class TerminalSearchModel {

    enum Status: Equatable, Sendable {
        case idle
        case searching
        /// `current` es `nil` si tmux no dice dónde quedó el cursor (versiones viejas).
        case found(count: Int, current: Int?, partial: Bool)
        case noMatches
        case invalidPattern
        case failed(String)
    }

    let sessionName: String
    /// Ejecuta un comando corto en el servidor (sh POSIX) y devuelve stdout.
    typealias Runner = @Sendable (String) async throws -> String
    @ObservationIgnored private let run: Runner
    @ObservationIgnored private let debounce: Duration

    var isPresented = false
    var query = ""
    var options = TerminalSearchOptions()
    private(set) var status: Status = .idle
    /// Con «Todas las ventanas».
    private(set) var windowResults: [TerminalWindowSearchResult] = []
    /// Ventana en la que se busca (la activa cuando se abrió la barra o la elegida).
    private(set) var target: TerminalPaneTarget

    @ObservationIgnored private var version: TmuxVersion?
    @ObservationIgnored private var versionLoaded = false
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var matches: [TerminalSearchMatch] = []
    @ObservationIgnored private var firstLine = 0
    @ObservationIgnored private var partial = false
    /// Se entró en modo copia (al cerrar hay que salir).
    @ObservationIgnored private var inCopyMode = false
    @ObservationIgnored private var generation = 0

    init(sessionName: String, debounce: Duration = .milliseconds(250), run: @escaping Runner) {
        self.sessionName = sessionName
        self.debounce = debounce
        self.run = run
        self.target = TerminalPaneTarget(session: sessionName, window: nil)
    }

    // MARK: - Abrir y cerrar

    /// Muestra la barra sobre la ventana `window` (la activa). Si ya había texto, vuelve a
    /// buscarlo.
    func present(window: Int?) {
        target = TerminalPaneTarget(session: sessionName, window: window)
        isPresented = true
        if !query.isEmpty { searchNow() }
    }

    /// Cierra la barra y saca al panel del modo copia (quita el resaltado).
    func dismiss() {
        isPresented = false
        pending?.cancel()
        generation += 1
        status = .idle
        windowResults = []
        guard inCopyMode else { return }
        inCopyMode = false
        let command = TerminalSearchCommands.cancel(target: target)
        let run = self.run
        pending = Task {
            do { _ = try await run(command) } catch {
                Log.terminal.notice("No se pudo salir del modo copia: \(error.userMessage, privacy: .public)")
            }
        }
    }

    // MARK: - Buscar

    /// El texto o las opciones cambiaron: busca tras una pausa corta (resaltado en vivo
    /// sin un comando por tecla).
    func queryDidChange() {
        pending?.cancel()
        generation += 1
        guard pattern != nil else {
            status = .idle
            windowResults = []
            return
        }
        let delay = debounce
        pending = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.performSearch()
        }
    }

    /// Busca ya (Intro en el campo, o al reabrir).
    func searchNow() {
        pending?.cancel()
        generation += 1
        pending = Task { [weak self] in await self?.performSearch() }
    }

    var pattern: TerminalSearchPattern? {
        TerminalSearchPattern(text: query, options: options)
    }

    private func performSearch() async {
        guard let pattern else { return }
        let regex: NSRegularExpression
        do {
            regex = try pattern.matcher()
        } catch {
            status = .invalidPattern
            windowResults = []
            return
        }
        let ticket = generation
        status = .searching
        if pattern.options.allWindows {
            await searchAllWindows(regex: regex, ticket: ticket)
        } else {
            windowResults = []
            await searchPane(pattern, regex: regex, ticket: ticket)
        }
    }

    private func searchPane(_ pattern: TerminalSearchPattern, regex: NSRegularExpression, ticket: Int) async {
        let supportsRegex = await tmuxVersion()?.supportsRegexSearch ?? true
        let nonce = TerminalSearchCommands.nonce()
        let command = TerminalSearchCommands.start(target: target, search: pattern.tmuxSearch(supportsRegex: supportsRegex), nonce: nonce)
        // Antes de mandar nada: aunque falle la respuesta, el panel pudo entrar en modo copia.
        inCopyMode = true
        do {
            let output = try await run(command)
            guard ticket == generation else { return }
            guard let snapshot = TerminalSearchCommands.parse(output, nonce: nonce) else {
                status = .failed(String(localized: "tmux no respondió a la búsqueda."))
                return
            }
            matches = TerminalSearchMatcher.matches(in: snapshot.lines, regex: regex)
            firstLine = snapshot.firstLine
            partial = snapshot.isPartial
            apply(position: snapshot.position)
        } catch {
            guard ticket == generation else { return }
            status = .failed(error.userMessage)
        }
    }

    private func searchAllWindows(regex: NSRegularExpression, ticket: Int) async {
        let nonce = TerminalSearchCommands.nonce()
        do {
            let output = try await run(TerminalWindowSearch.command(session: sessionName, nonce: nonce))
            guard ticket == generation else { return }
            let results = TerminalWindowSearch.results(output, nonce: nonce, regex: regex)
            windowResults = results
            let total = results.reduce(0) { $0 + $1.matchCount }
            status = total == 0 ? .noMatches : .found(count: total, current: nil, partial: false)
        } catch {
            guard ticket == generation else { return }
            status = .failed(error.userMessage)
        }
    }

    private func apply(position: TerminalSearchPosition?) {
        if matches.isEmpty || position?.searchPresent == false {
            status = matches.isEmpty ? .noMatches : .found(count: matches.count, current: nil, partial: partial)
            return
        }
        let current = TerminalSearchCommands.currentIndex(position: position, matches: matches, firstLine: firstLine)
        status = .found(count: matches.count, current: current, partial: partial)
    }

    // MARK: - Moverse

    /// A una coincidencia más antigua (⌘G).
    func next() { step(older: true) }
    /// A una más reciente (⇧⌘G).
    func previous() { step(older: false) }

    var canStep: Bool {
        guard !options.allWindows, case .found(let count, _, _) = status else { return false }
        return count > 0
    }

    private func step(older: Bool) {
        guard canStep else { return }
        pending?.cancel()
        generation += 1
        let ticket = generation
        pending = Task { [weak self] in await self?.performStep(older: older, count: 1, ticket: ticket) }
    }

    private func performStep(older: Bool, count: Int, ticket: Int, retried: Bool = false) async {
        let before = currentIndex
        let nonce = TerminalSearchCommands.nonce()
        do {
            let output = try await run(TerminalSearchCommands.step(target: target, older: older, count: count, nonce: nonce))
            guard ticket == generation else { return }
            guard let snapshot = TerminalSearchCommands.parse(output, nonce: nonce) else { return }
            if snapshot.leftCopyMode {
                // Alguien salió del modo copia: se busca de nuevo desde abajo.
                inCopyMode = false
                await performSearch()
                return
            }
            apply(position: snapshot.position)
            // Al cambiar de sentido, tmux encuentra primero la coincidencia en la que ya está
            // el cursor (la búsqueda hacia delante empieza en él): un paso más.
            if !retried, let before, currentIndex == before, matches.count > 1 {
                await performStep(older: older, count: 1, ticket: ticket, retried: true)
            }
        } catch {
            guard ticket == generation else { return }
            status = .failed(error.userMessage)
        }
    }

    private var currentIndex: Int? {
        if case .found(_, let current, _) = status { return current }
        return nil
    }

    /// Resultado de «Todas las ventanas»: cambia a esa ventana y salta a la línea.
    func open(_ line: TerminalWindowSearchLine, in result: TerminalWindowSearchResult) {
        pending?.cancel()
        generation += 1
        let ticket = generation
        options.allWindows = false
        windowResults = []
        target = TerminalPaneTarget(session: sessionName, window: result.windowIndex)
        pending = Task { [weak self] in await self?.performOpen(line, window: result.windowIndex, ticket: ticket) }
    }

    private func performOpen(_ line: TerminalWindowSearchLine, window: Int, ticket: Int) async {
        do {
            _ = try await run(TerminalSearchCommands.selectWindow(session: sessionName, window: window))
        } catch {
            guard ticket == generation else { return }
            status = .failed(error.userMessage)
            return
        }
        guard ticket == generation, let pattern, let regex = try? pattern.matcher() else { return }
        status = .searching
        await searchPane(pattern, regex: regex, ticket: ticket)
        guard ticket == generation, line.ordinalFromNewest > 1 else { return }
        await performStep(older: true, count: line.ordinalFromNewest - 1, ticket: ticket)
    }

    // MARK: - Copiar coincidencias

    /// Líneas con coincidencias (las de todas las ventanas, si está esa opción). `nil` si
    /// no hay nada que copiar o falló (queda en `status`).
    func matchingText() async -> String? {
        guard let pattern, let regex = try? pattern.matcher() else { return nil }
        if pattern.options.allWindows {
            return windowResults.isEmpty ? nil : TerminalWindowSearch.copyText(windowResults)
        }
        do {
            let output = try await run(TerminalSearchCommands.captureJoined(target: target))
            let lines = TerminalSearchMatcher.matchingLines(in: output.components(separatedBy: "\n"), regex: regex)
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        } catch {
            status = .failed(error.userMessage)
            return nil
        }
    }

    /// Espera a que acabe la búsqueda o el salto en curso (tests).
    func waitForPendingWork() async {
        await pending?.value
    }

    // MARK: - Versión de tmux

    private func tmuxVersion() async -> TmuxVersion? {
        if versionLoaded { return version }
        do {
            version = TmuxVersion(versionOutput: try await run(TerminalSearchCommands.versionCommand))
            versionLoaded = true
        } catch {
            Log.terminal.notice("No se pudo leer la versión de tmux: \(error.userMessage, privacy: .public)")
        }
        return version
    }

    // MARK: - Texto del contador

    /// «3 de 12», «12 coincidencias», «Sin coincidencias»…
    var statusText: String? {
        switch status {
        case .idle: return nil
        case .searching: return String(localized: "Buscando…")
        case .noMatches: return String(localized: "Sin coincidencias")
        case .invalidPattern: return String(localized: "Expresión no válida")
        case .failed: return String(localized: "Error")
        case .found(let count, let current, let partial):
            let total = partial ? "\(count)+" : "\(count)"
            if let current { return String(localized: "\(String(current)) de \(total)") }
            if count == 1 && !partial { return String(localized: "1 coincidencia") }
            return String(localized: "\(total) coincidencias")
        }
    }
}
