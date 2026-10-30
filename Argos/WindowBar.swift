//
//  WindowBar.swift
//  Argos
//
//  Barra de pestañas con las ventanas de la sesión tmux. Cada pestaña cambia de
//  ventana al pulsarla y ofrece, con clic derecho, renombrarla y elegir su color.
//

import AppKit
import SwiftUI

struct WindowBar: View {
    let windows: [TmuxWindow]
    let onSelect: (TmuxWindow) -> Void
    let onNew: () -> Void
    let onRename: (TmuxWindow) -> Void
    let onSetColor: (TmuxWindow, WindowColor?) -> Void

    /// Etiqueta de VoiceOver de una pestaña de ventana: índice, nombre, si está activa
    /// y cuántos paneles tiene (el botón se expone con texto, no solo con color/forma).
    static func accessibilityLabel(for window: TmuxWindow) -> String {
        var parts = ["Ventana \(window.index): \(window.name)"]
        if window.isActive { parts.append("activa") }
        if window.paneCount > 1 { parts.append("\(window.paneCount) paneles") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(windows) { window in
                    tab(for: window)
                }

                Button(action: onNew) {
                    Image(systemName: "plus")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .help("Nueva ventana (en el directorio actual)")
                .accessibilityLabel("Nueva ventana")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func tab(for window: TmuxWindow) -> some View {
        let tint = window.color?.swatch ?? .accentColor
        return Button { onSelect(window) } label: {
            HStack(spacing: 5) {
                if let color = window.color {
                    Circle()
                        .fill(color.swatch)
                        .frame(width: 7, height: 7)
                }
                Text("\(window.index)")
                    .font(.caption.monospaced())
                    .foregroundStyle(window.isActive ? tint : .secondary)
                Text(window.name)
                    .font(.callout)
                    .lineLimit(1)
                if window.paneCount > 1 {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(tabFill(for: window, tint: tint), in: Capsule())
            .overlay(
                Capsule().strokeBorder(window.isActive ? tint.opacity(0.6) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Cambiar a la ventana \(window.index): \(window.name). Clic derecho para renombrar o cambiar el color.")
        .accessibilityLabel(Self.accessibilityLabel(for: window))
        .contextMenu { menu(for: window) }
    }

    private func tabFill(for window: TmuxWindow, tint: Color) -> Color {
        if window.isActive { return tint.opacity(0.18) }
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
