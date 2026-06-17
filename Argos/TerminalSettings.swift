//
//  TerminalSettings.swift
//  Argos
//
//  Ajustes de apariencia del terminal (tamaño de fuente y tema), persistidos en
//  UserDefaults y aplicados en vivo a la `TerminalView`.
//

import AppKit
import Observation
import SwiftUI

/// Tema de color del terminal. `system` se adapta a claro/oscuro de macOS.
enum TerminalTheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case dark
    case light
    case solarizedDark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Sistema"
        case .dark: return "Oscuro"
        case .light: return "Claro"
        case .solarizedDark: return "Solarized Dark"
        }
    }

    var foreground: NSColor {
        switch self {
        case .system: return .textColor
        case .dark: return NSColor(white: 0.92, alpha: 1)
        case .light: return NSColor(white: 0.1, alpha: 1)
        case .solarizedDark: return NSColor(srgbRed: 0.51, green: 0.58, blue: 0.59, alpha: 1) // base0
        }
    }

    var background: NSColor {
        switch self {
        case .system: return .textBackgroundColor
        case .dark: return NSColor(white: 0.08, alpha: 1)
        case .light: return NSColor(white: 0.99, alpha: 1)
        case .solarizedDark: return NSColor(srgbRed: 0.0, green: 0.17, blue: 0.21, alpha: 1) // base03
        }
    }
}

/// Ajustes de apariencia compartidos. Singleton observable; los cambios se persisten
/// y las vistas que lo leen se re-renderizan (re-aplicando fuente/colores al terminal).
@MainActor
@Observable
final class TerminalSettings {
    static let shared = TerminalSettings()

    static let minFontSize: Double = 9
    static let maxFontSize: Double = 24

    var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
    }

    var theme: TerminalTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme) }
    }

    private enum Keys {
        static let fontSize = "terminal.fontSize"
        static let theme = "terminal.theme"
    }

    private init() {
        let stored = UserDefaults.standard.double(forKey: Keys.fontSize)
        fontSize = stored == 0 ? 13 : stored
        theme = TerminalTheme(rawValue: UserDefaults.standard.string(forKey: Keys.theme) ?? "") ?? .system
    }
}

// MARK: - Panel de preferencias (Cmd+,)

struct TerminalSettingsView: View {
    @Bindable private var settings = TerminalSettings.shared

    var body: some View {
        Form {
            Section("Terminal") {
                LabeledContent("Tamaño de fuente") {
                    HStack(spacing: 12) {
                        Slider(
                            value: $settings.fontSize,
                            in: TerminalSettings.minFontSize...TerminalSettings.maxFontSize,
                            step: 1
                        )
                        .frame(width: 180)
                        Text("\(Int(settings.fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                Picker("Tema", selection: $settings.theme) {
                    ForEach(TerminalTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.vertical, 8)
    }
}
