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
//  Las órdenes al servidor van EN FILA (`send`): cancelar una tarea no detiene un exec que
//  ya corre en el servidor, así que salir del modo copia espera a la búsqueda en curso y una
//  búsqueda que ya no toca (otra más nueva, o la barra cerrada) no llega a enviarse.
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

    private(set) var isPresented = false
    /// Al cambiar (también desde el campo de la barra), busca tras una pausa corta.
    var query = "" {
        didSet { if query != oldValue { queryDidChange() } }
    }
    var options = TerminalSearchOptions() {
        didSet { if options != oldValue && !silencingChanges { queryDidChange() } }
    }
    private(set) var status: Status = .idle
    /// Con «Todas las ventanas».
    private(set) var windowResults: [TerminalWindowSearchResult] = []
    /// Ventana en la que se busca (la activa cuando se abrió la barra o la elegida).
    private(set) var target: TerminalPaneTarget

    @ObservationIgnored private var silencingChanges = false
    @ObservationIgnored private var version: TmuxVersion?
    @ObservationIgnored private var versionLoaded = false
    /// Búsqueda o salto en marcha (con su pausa); se cancela al cambiar de idea.
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// Última orden de la fila al servidor (nunca se cancela).
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var matches: [TerminalSearchMatch] = []
    @ObservationIgnored private var firstLine = 0
    @ObservationIgnored private var partial = false
    /// Panel que se dejó en modo copia (al cerrar o cambiar de ventana hay que sacarlo).
    @ObservationIgnored private var copyModeTarget: TerminalPaneTarget?
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
        retarget(TerminalPaneTarget(session: sessionName, window: window))
        isPresented = true
        if !query.isEmpty { searchNow() }
    }

    /// Cierra la barra y saca al panel del modo copia (quita el resaltado). Sin efecto si
    /// ya estaba cerrada.
    func dismiss() {
        guard isPresented || copyModeTarget != nil else { return }
        isPresented = false
        pending?.cancel()
        generation += 1
        status = .idle
        windowResults = []
        leaveCopyMode()
    }

    /// Cambia de panel; el anterior sale del modo copia.
    private func retarget(_ newTarget: TerminalPaneTarget) {
        if let copyModeTarget, copyModeTarget != newTarget { leaveCopyMode() }
        target = newTarget
    }

    /// Encola `cancel` (después de lo que esté en curso; nunca se cancela).
    private func leaveCopyMode() {
        guard let previous = copyModeTarget else { return }
        copyModeTarget = nil
        let command = TerminalSearchCommands.cancel(target: previous)
        let before = tail
        let run = self.run
        tail = Task {
            await before?.value
            do { _ = try await run(command) } catch {
                Log.terminal.notice("No se pudo salir del modo copia: \(error.userMessage, privacy: .public)")
            }
        }
    }

    // MARK: - Fila de órdenes

    /// Envía `command` cuando acaben las anteriores. Con `ticket`, no lo envía (devuelve
    /// `nil`) si entretanto llegó otra búsqueda o se cerró la barra.
    private func send(_ command: String, ticket: Int?) async throws -> String? {
        let previous = tail
        let task = Task { [weak self] () async throws -> String? in
            await previous?.value
            guard let self else { return nil }
            if let ticket, ticket != self.generation { return nil }
            return try await self.run(command)
        }
        tail = Task { _ = await task.result }
        return try await task.value
    }

    // MARK: - Buscar

    /// El texto o las opciones cambiaron: busca tras una pausa corta (resaltado en vivo
    /// sin un comando por tecla).
    func queryDidChange() {
        pending?.cancel()
        generation += 1
        guard isPresented else { return }
        guard pattern != nil else {
            status = .idle
            windowResults = []
            return
        }
        let delay = debounce
        let ticket = generation
        pending = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.performSearch(ticket: ticket)
        }
    }

    /// Busca ya (Intro en el campo, o al reabrir).
    func searchNow() {
        pending?.cancel()
        generation += 1
        let ticket = generation
        pending = Task { [weak self] in await self?.performSearch(ticket: ticket) }
    }

    var pattern: TerminalSearchPattern? {
        TerminalSearchPattern(text: query, options: options)
    }

    /// `ticket`: la generación en la que se pidió (si entretanto se cerró la barra o llegó
    /// otra búsqueda, no hace nada).
    private func performSearch(ticket: Int) async {
        guard ticket == generation, let pattern else { return }
        let regex: NSRegularExpression
        do {
            regex = try pattern.matcher()
        } catch {
            status = .invalidPattern
            windowResults = []
            return
        }
        status = .searching
        if pattern.options.allWindows {
            await searchAllWindows(regex: regex, ticket: ticket)
        } else {
            windowResults = []
            await searchPane(pattern, regex: regex, ticket: ticket)
        }
    }

    private func searchPane(_ pattern: TerminalSearchPattern, regex: NSRegularExpression, ticket: Int) async {
        do {
            try await pinTargetWindow(ticket: ticket)
            let supportsRegex = await tmuxVersion()?.supportsRegexSearch ?? true
            let nonce = TerminalSearchCommands.nonce()
            let searched = target
            let command = TerminalSearchCommands.start(target: searched, search: pattern.tmuxSearch(supportsRegex: supportsRegex), nonce: nonce)
            // Antes de enviar: aunque la respuesta falle, el panel pudo entrar en modo copia.
            copyModeTarget = searched
            guard let output = try await send(command, ticket: ticket), ticket == generation else { return }
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

    /// Fija el número de la ventana activa: «la activa» cambiaría si el usuario cambia de
    /// ventana con la barra abierta, y el modo copia quedaría en la anterior.
    private func pinTargetWindow(ticket: Int) async throws {
        guard target.window == nil else { return }
        guard let output = try await send(TerminalSearchCommands.activeWindowCommand(session: sessionName), ticket: ticket),
              let index = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        retarget(TerminalPaneTarget(session: sessionName, window: index))
    }

    private func searchAllWindows(regex: NSRegularExpression, ticket: Int) async {
        let nonce = TerminalSearchCommands.nonce()
        do {
            guard let output = try await send(TerminalWindowSearch.command(session: sessionName, nonce: nonce), ticket: ticket),
                  ticket == generation else { return }
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
            let command = TerminalSearchCommands.step(target: target, older: older, count: count, nonce: nonce)
            guard let output = try await send(command, ticket: ticket), ticket == generation,
                  let snapshot = TerminalSearchCommands.parse(output, nonce: nonce) else { return }
            if snapshot.leftCopyMode {
                // Alguien salió del modo copia: se busca de nuevo desde abajo.
                copyModeTarget = nil
                await performSearch(ticket: ticket)
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
        // Sin disparar otra búsqueda (cancelaría este salto).
        silencingChanges = true
        options.allWindows = false
        silencingChanges = false
        windowResults = []
        retarget(TerminalPaneTarget(session: sessionName, window: result.windowIndex))
        pending = Task { [weak self] in await self?.performOpen(line, window: result.windowIndex, ticket: ticket) }
    }

    private func performOpen(_ line: TerminalWindowSearchLine, window: Int, ticket: Int) async {
        do {
            _ = try await send(TerminalSearchCommands.selectWindow(session: sessionName, window: window), ticket: ticket)
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
            guard let output = try await send(TerminalSearchCommands.captureJoined(target: target), ticket: nil) else { return nil }
            let lines = TerminalSearchMatcher.matchingLines(in: output.components(separatedBy: "\n"), regex: regex)
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        } catch {
            status = .failed(error.userMessage)
            return nil
        }
    }

    /// Espera a que acaben la búsqueda en curso y las órdenes encoladas (tests).
    func waitForPendingWork() async {
        await pending?.value
        while let current = tail {
            await current.value
            if tail == current { break }
        }
    }

    // MARK: - Versión de tmux

    private func tmuxVersion() async -> TmuxVersion? {
        if versionLoaded { return version }
        do {
            if let output = try await send(TerminalSearchCommands.versionCommand, ticket: nil) {
                version = TmuxVersion(versionOutput: output)
                versionLoaded = true
            }
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
