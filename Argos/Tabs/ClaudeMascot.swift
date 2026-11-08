//
//  ClaudeMascot.swift
//  Argos
//
//  Mascota pixel-art de Claude Code dibujada a partir de una cuadrícula (sin assets):
//  nítida a cualquier tamaño. `ClaudeMascot` es la vista de SwiftUI (pestañas, cabecera
//  del terminal) y `ClaudeMascot.menuImage` la versión NSImage para los menús, donde
//  las vistas de SwiftUI no se pintan.
//

import AppKit
import SwiftUI

struct ClaudeMascot: View {
    /// Alto en puntos; el ancho sale de la proporción de la cuadrícula.
    var height: CGFloat = 14

    /// Cuadrícula: `#` cuerpo, `o` ojo, `.` vacío.
    static let grid: [String] = [
        "..#########..",
        "..##o###o##..",
        "..##o###o##..",
        "#############",
        "#############",
        "..#########..",
        "..#########..",
        "...#.#...#.#.",
        "...#.#...#.#.",
    ]

    static let bodyColor = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    static let eyeColor = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)

    static var columns: Int { grid.first?.count ?? 1 }
    static var rows: Int { grid.count }
    static var aspectRatio: CGFloat { CGFloat(columns) / CGFloat(rows) }

    var body: some View {
        Canvas { context, size in
            let cell = min(size.width / CGFloat(Self.columns), size.height / CGFloat(Self.rows))
            for (row, line) in Self.grid.enumerated() {
                for (column, char) in line.enumerated() {
                    guard let color = Self.color(for: char) else { continue }
                    let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    // Un pelín más grande para que no se vean costuras entre píxeles.
                    context.fill(Path(rect.insetBy(dx: -0.15, dy: -0.15)), with: .color(color))
                }
            }
        }
        .frame(width: height * Self.aspectRatio, height: height)
        .accessibilityHidden(true)
    }

    private static func color(for char: Character) -> Color? {
        switch char {
        case "#": return bodyColor
        case "o": return eyeColor
        default: return nil
        }
    }

    /// Imagen NO-template para los ítems de menú (en NSMenu, los SF Symbols y las
    /// imágenes template se pintan monocromas).
    static func menuImage(height: CGFloat = 13) -> NSImage {
        let cell = height / CGFloat(rows)
        let size = NSSize(width: cell * CGFloat(columns), height: height)
        let image = NSImage(size: size, flipped: true) { _ in
            for (row, line) in grid.enumerated() {
                for (column, char) in line.enumerated() {
                    guard let color = Self.color(for: char) else { continue }
                    NSColor(color).setFill()
                    NSRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Icono de cada agente en pestañas y cabeceras: la mascota para Claude Code y un
/// símbolo para el resto.
struct CodingAgentIcon: View {
    let agent: CodingAgent
    var size: CGFloat = 13

    var body: some View {
        switch agent {
        case .claude:
            ClaudeMascot(height: size)
        case .codex, .grok:
            Image(systemName: agent.symbolName)
                .font(.system(size: size * 0.9, weight: .semibold))
                .foregroundStyle(agent.tint)
                .frame(height: size)
                .accessibilityHidden(true)
        }
    }
}

extension CodingAgent {
    /// SF Symbol de los agentes que no tienen mascota propia.
    var symbolName: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "circle.hexagongrid.fill"
        case .grok: return "slash.circle"
        }
    }

    var tint: Color {
        switch self {
        case .claude: return ClaudeMascot.bodyColor
        case .codex: return .blue
        case .grok: return .primary
        }
    }

    /// Imagen del ítem del menú «+».
    var menuImage: NSImage {
        switch self {
        case .claude:
            return ClaudeMascot.menuImage()
        case .codex, .grok:
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                .applying(.init(paletteColors: [NSColor(tint)]))
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: displayName)?
                .withSymbolConfiguration(config) ?? NSImage()
            image.isTemplate = false
            return image
        }
    }
}
