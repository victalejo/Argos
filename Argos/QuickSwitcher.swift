//
//  QuickSwitcher.swift
//  Argos
//
//  Cambiador rápido (⌘K): un buscador difuso para saltar a cualquier sesión de
//  cualquier servidor sin tocar el mouse.
//

import Observation
import SwiftUI

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
    @State private var hoveredHandle: SessionHandle?
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            HStack(spacing: 13) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("CAMBIAR DE SESIÓN")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                    TextField("Busca una sesión o un servidor…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($fieldFocused)
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.return) { commit(); return .handled }
                        .onKeyPress(.escape) { onCancel(); return .handled }
                }
                Button(action: onCancel) { QuickSwitchKey(label: "esc") }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Cerrar (Esc)")
                    .accessibilityLabel("Cerrar buscador de sesiones")
            }
            .padding(20)

            Divider()

            HStack {
                Text(query.isEmpty ? "Tus sesiones" : "Resultados")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(filtered.count)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.08), in: Capsule())
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: items.isEmpty ? "terminal" : "text.magnifyingglass")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Color.accentColor.opacity(0.65))
                    Text(items.isEmpty ? "Aún no hay sesiones" : "Sin coincidencias")
                        .font(.headline)
                    Text(items.isEmpty
                         ? "Conecta un servidor y crea una sesión para encontrarla aquí."
                         : "Prueba con otra parte del nombre o con el servidor.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 300)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                                Button { onSelect(item.handle) } label: {
                                    row(item, selected: index == clampedSelection)
                                }
                                .buttonStyle(.plain)
                                .id(index)
                                .onHover { isHovering in
                                    hoveredHandle = isHovering ? item.handle : nil
                                }
                                .accessibilityLabel("\(item.sessionName), servidor \(item.serverName)")
                                .accessibilityAddTraits(index == clampedSelection ? .isSelected : [])
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .frame(height: 300)
                    .onChange(of: query) { _, _ in proxy.scrollTo(0, anchor: .top) }
                    .onChange(of: clampedSelection) { _, new in
                        // Respeta "Reducir movimiento": salta sin animar el scroll.
                        if reduceMotion {
                            proxy.scrollTo(new, anchor: .center)
                        } else {
                            withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) }
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: 6) {
                QuickSwitchKey(label: "↑")
                QuickSwitchKey(label: "↓")
                Text("Navegar")
                Spacer()
                QuickSwitchKey(label: "↩")
                Text("Abrir sesión")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.secondary.opacity(0.035))
        }
        .frame(width: 590)
        .background(Color(nsColor: .windowBackgroundColor))
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
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(selected ? selectedForeground : Color.accentColor)
                .frame(width: 36, height: 36)
                .background(selected ? selectedForeground.opacity(0.12) : Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.sessionName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(selected ? selectedForeground : .primary)
                Label(item.serverName, systemImage: "server.rack")
                    .font(.caption)
                    .foregroundStyle(selected ? selectedForeground.opacity(0.8) : .secondary)
            }
            Spacer()
            if selected {
                Image(systemName: "return")
                    .font(.callout)
                    .foregroundStyle(selectedForeground.opacity(0.8))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .background(selected ? Color.accentColor : hoveredHandle == item.handle ? Color.secondary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveredHandle)
    }
}

private struct QuickSwitchKey: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(minWidth: 23, minHeight: 22)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.12)))
    }
}
