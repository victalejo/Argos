//
//  WindowBar.swift
//  Argos
//
//  Barra de pestañas con las ventanas de la sesión tmux. Cada pestaña cambia de
//  ventana al pulsarla y ofrece, con clic derecho, renombrarla, elegir su color o
//  cerrarla (también con la "×" que aparece al pasar el ratón o en la activa).
//

import AppKit
import SwiftUI

struct WindowBar: View {
    let windows: [TmuxWindow]
    /// Estado de Claude Code por índice de ventana.
    var claudeByWindow: [Int: ClaudeActivity] = [:]
    let onSelect: (TmuxWindow) -> Void
    let onNew: () -> Void
    let onRename: (TmuxWindow) -> Void
    let onSetColor: (TmuxWindow, WindowColor?) -> Void
    let onClose: (TmuxWindow) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredWindow: TmuxWindow.ID?

    /// Etiqueta de VoiceOver de una pestaña de ventana: índice, nombre, si está activa
    /// y cuántos paneles tiene (el botón se expone con texto, no solo con color/forma).
    static func accessibilityLabel(for window: TmuxWindow) -> String {
        var parts = ["Ventana \(window.index): \(window.name)"]
        if window.isActive { parts.append("activa") }
        if window.paneCount > 1 { parts.append("\(window.paneCount) paneles") }
        return parts.joined(separator: ", ")
    }

    /// Cerrar la última ventana mataría la sesión entera: solo se ofrece si hay más.
    private var canClose: Bool { windows.count > 1 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(windows) { window in
                    tab(for: window)
                }

                Button(action: onNew) {
                    Label("Ventana", systemImage: "plus")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Nueva ventana (en el directorio actual)")
                .accessibilityLabel("Nueva ventana")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .background(.bar)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: windows)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveredWindow)
    }

    private func tab(for window: TmuxWindow) -> some View {
        let tint = window.color?.swatch ?? .accentColor
        return Button { onSelect(window) } label: {
            HStack(spacing: 7) {
                if let color = window.color {
                    Circle()
                        .fill(color.swatch)
                        .frame(width: 7, height: 7)
                }
                Text("\(window.index)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(window.isActive ? tint : .secondary)
                    .frame(width: 17, height: 17)
                    .background(tint.opacity(window.isActive ? 0.13 : 0.05), in: RoundedRectangle(cornerRadius: 4))
                Text(window.name)
                    .font(.callout.weight(window.isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: 180)
                if let claude = claudeByWindow[window.index] {
                    ClaudeActivityBadge(activity: claude, size: 10)
                }
                if window.paneCount > 1 {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                closeButton(for: window)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(tabFill(for: window, tint: tint), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(window.isActive ? tint.opacity(0.35) : Color.primary.opacity(0.04), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Cambiar a la ventana \(window.index): \(window.name). Clic derecho para renombrar, cambiar el color o cerrarla.")
        .accessibilityLabel(Self.accessibilityLabel(for: window))
        .accessibilityAddTraits(window.isActive ? .isSelected : [])
        .onHover { hoveredWindow = $0 ? window.id : nil }
        .contextMenu { menu(for: window) }
    }

    /// "×" para cerrar la ventana. Ocupa siempre su hueco (para que la pestaña no
    /// cambie de ancho al pasar el ratón) y solo se ve en la activa o la señalada.
    @ViewBuilder
    private func closeButton(for window: TmuxWindow) -> some View {
        if canClose {
            let visible = window.isActive || hoveredWindow == window.id
            Button { onClose(window) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .help("Cerrar la ventana \(window.index)")
            .accessibilityLabel("Cerrar ventana \(window.index): \(window.name)")
        }
    }

    private func tabFill(for window: TmuxWindow, tint: Color) -> Color {
        if window.isActive { return tint.opacity(0.18) }
        if hoveredWindow == window.id { return tint.opacity(0.10) }
        if window.color != nil { return tint.opacity(0.10) }
        return Color.secondary.opacity(0.08)
    }

    @ViewBuilder
    private func menu(for window: TmuxWindow) -> some View {
        Button("Renombrar…") { onRename(window) }
        Picker("Color", selection: Binding(
            get: { window.color },
            set: { onSetColor(window, $0) }
        )) {
            Text("Sin color").tag(WindowColor?.none)
            Divider()
            ForEach(WindowColor.allCases) { color in
                Label {
                    Text(color.displayName)
                } icon: {
                    Image(nsImage: color.menuSwatch)
                }
                .tag(WindowColor?.some(color))
            }
        }
        .pickerStyle(.menu)
        Divider()
        Button("Cerrar ventana…", role: .destructive) { onClose(window) }
            .disabled(!canClose)
    }
}

extension WindowColor {
    /// Color de SwiftUI con el que se pinta la pestaña.
    var swatch: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .mint: return .mint
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .gray: return .gray
        }
    }

    /// Círculo de color NO-template para los menús (en NSMenu los SF Symbols se
    /// pintan monocromos y el color no se vería).
    var menuSwatch: NSImage {
        let color = NSColor(swatch)
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}
