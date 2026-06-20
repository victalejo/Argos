//
//  QuickSwitcher.swift
//  Argos
//
//  Cambiador rápido (⌘K): un buscador difuso para saltar a cualquier sesión de
//  cualquier servidor sin tocar el mouse.
//

import Observation
import SwiftUI

// MARK: - Coincidencia difusa (lógica pura, testeable)

enum FuzzyMatcher {
    /// Puntuación (mayor = mejor) si `query` hace subsequence-match en `text`
    /// (sin distinguir mayúsculas ni acentos). `nil` si no coincide.
    /// Query vacía siempre coincide (score 0).
    static func score(_ query: String, in text: String) -> Int? {
        let q = Array(normalize(query))
        guard !q.isEmpty else { return 0 }
        let t = Array(normalize(text))
        guard !t.isEmpty else { return nil }

        var score = 0
        var ti = 0
        var lastMatch = -2
        for qc in q {
            var found = -1
            var i = ti
            while i < t.count {
                if t[i] == qc { found = i; break }
                i += 1
            }
            guard found >= 0 else { return nil }
            if found == lastMatch + 1 { score += 5 }                 // contiguo
            if found == 0 || t[found - 1] == " " || t[found - 1] == "/" || t[found - 1] == "-" {
                score += 3                                            // inicio de palabra
            }
            score += 1
            lastMatch = found
            ti = found + 1
        }
        return score
    }

    private static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }
}

// MARK: - Modelo de presentación

struct QuickSwitchItem: Identifiable, Hashable {
    let handle: SessionHandle
    let serverName: String
    let sessionName: String
    var id: SessionHandle { handle }
}

@MainActor
@Observable
final class QuickSwitcher {
    static let shared = QuickSwitcher()
    var isPresented = false

    func present() { isPresented = true }
}

// MARK: - Vista del switcher

struct QuickSwitcherView: View {
    let items: [QuickSwitchItem]
    let onSelect: (SessionHandle) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    private var filtered: [QuickSwitchItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items
            .compactMap { item -> (QuickSwitchItem, Int)? in
                let scores = [
                    FuzzyMatcher.score(q, in: item.sessionName),
                    FuzzyMatcher.score(q, in: item.serverName),
                ].compactMap { $0 }
                guard let best = scores.max() else { return nil }
                return (item, best)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar sesión…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.return) { commit(); return .handled }
                    .onKeyPress(.escape) { onCancel(); return .handled }
            }
            .padding(14)

            Divider()

            if filtered.isEmpty {
                ContentUnavailableView("Sin coincidencias", systemImage: "magnifyingglass")
                    .frame(height: 220)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == clampedSelection)
                                    .id(index)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onSelect(item.handle) }
                            }
                        }
                    }
                    .frame(height: 300)
                    .onChange(of: clampedSelection) { _, new in
                        withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: 540)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private var clampedSelection: Int {
        guard !filtered.isEmpty else { return 0 }
        return min(max(0, selection), filtered.count - 1)
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selection = (clampedSelection + delta + filtered.count) % filtered.count
    }

    private func commit() {
        guard filtered.indices.contains(clampedSelection) else { return }
        onSelect(filtered[clampedSelection].handle)
    }

    /// Texto sobre el fondo de selección (accent). El color del sistema para texto en
    /// ítems de menú seleccionados se adapta al accent actual y al modo claro/oscuro,
    /// a diferencia de un `.white` hardcodeado (ilegible con accents claros).
    private var selectedForeground: Color { Color(nsColor: .selectedMenuItemTextColor) }

    @ViewBuilder
    private func row(_ item: QuickSwitchItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(selected ? selectedForeground : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.sessionName)
                    .font(.headline)
                    .foregroundStyle(selected ? selectedForeground : .primary)
                Text(item.serverName)
                    .font(.caption)
                    .foregroundStyle(selected ? selectedForeground.opacity(0.8) : .secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor : .clear)
    }
}
