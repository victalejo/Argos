//
//  CodingAgentMenuImage.swift
//  Argos
//
//  Versión NSImage de los iconos de agentes para los menús de AppKit, donde las vistas
//  de SwiftUI no se pintan y los SF Symbols/plantillas salen monocromos. La mascota y
//  los iconos en SwiftUI viven en `ArgosUI/ClaudeMascot.swift` (compartidos con iOS).
//

import AppKit
import SwiftUI

extension ClaudeMascot {
    /// Imagen NO-template de la mascota para los ítems de menú.
    static func menuImage(height: CGFloat = 13) -> NSImage {
        let cell = height / CGFloat(rows)
        let size = NSSize(width: cell * CGFloat(columns), height: height)
        let image = NSImage(size: size, flipped: true) { _ in
            for (row, line) in grid.enumerated() {
                for (column, char) in line.enumerated() {
                    guard let color = color(for: char) else { continue }
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

extension CodingAgent {
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
