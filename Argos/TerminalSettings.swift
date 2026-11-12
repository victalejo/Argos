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
    static let defaultFontSize: Double = 13
    static let fontSizeStep: Double = 1

    var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
    }

    // MARK: - Zoom de fuente (⌘+ / ⌘- / ⌘0)

    func increaseFontSize() { setFontSize(fontSize + Self.fontSizeStep) }
    func decreaseFontSize() { setFontSize(fontSize - Self.fontSizeStep) }
    func resetFontSize() { setFontSize(Self.defaultFontSize) }

    /// Fija el tamaño de fuente acotado a `[min, max]`.
    func setFontSize(_ value: Double) { fontSize = Self.clampFontSize(value) }

    /// Acota un tamaño de fuente al rango válido (lógica pura, testeable).
    static func clampFontSize(_ value: Double) -> Double {
        min(max(value, minFontSize), maxFontSize)
    }

    var theme: TerminalTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme) }
    }

    // MARK: - Terminales vivos a la vez

    /// Cuántos terminales se mantienen conectados a la vez. Al superarlo, el menos usado
    /// se desengancha y queda "dormido" (su sesión tmux sigue en el servidor). El
    /// historial largo vive en tmux, así que cada terminal cuesta pocos MB en el Mac.
    static let minLiveTerminals = 4
    static let maxLiveTerminals = 64
    static let defaultLiveTerminals = 24

    var maxLiveTerminals: Int {
        didSet { UserDefaults.standard.set(maxLiveTerminals, forKey: Keys.maxLiveTerminals) }
    }

    /// Acota el tope al rango válido (lógica pura, testeable).
    static func clampLiveTerminalLimit(_ value: Int) -> Int {
        min(max(value, minLiveTerminals), maxLiveTerminals)
    }

    /// Interpreta el valor guardado: 0 (sin guardar) es el valor por defecto.
    static func liveTerminalLimit(fromStored stored: Int) -> Int {
        stored == 0 ? defaultLiveTerminals : clampLiveTerminalLimit(stored)
    }

    private enum Keys {
        static let fontSize = "terminal.fontSize"
        static let theme = "terminal.theme"
        static let maxLiveTerminals = "terminal.maxLiveTerminals"
    }

    private init() {
        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: Keys.fontSize)
        fontSize = stored == 0 ? Self.defaultFontSize : stored
        theme = TerminalTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        maxLiveTerminals = Self.liveTerminalLimit(fromStored: defaults.integer(forKey: Keys.maxLiveTerminals))
    }
}

// MARK: - Panel de preferencias (Cmd+,)

struct TerminalSettingsView: View {
    @Bindable private var settings = TerminalSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    WorkspaceIcon(symbol: "terminal", size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Un terminal a tu medida").font(.headline)
                        Text("Los cambios se aplican al instante.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        ForEach([Color.red, .orange, .green], id: \.self) { color in
                            Circle().fill(color.opacity(0.8)).frame(width: 7, height: 7)
                        }
                        Spacer()
                        Text("VISTA PREVIA").font(.system(size: 8, weight: .semibold)).tracking(1)
                    }
                    .foregroundStyle(Color(nsColor: settings.theme.foreground).opacity(0.6))
                    Text("~/proyectos ❯ git status")
                        .foregroundStyle(Color(nsColor: settings.theme.foreground))
                    Text("✓ Tu espacio de trabajo está listo")
                        .foregroundStyle(settings.theme == .light ? Color.teal : Color(nsColor: settings.theme.foreground).opacity(0.75))
                }
                .font(.system(size: settings.fontSize, design: .monospaced))
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: settings.theme.background), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(ArgosTheme.border) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Vista previa del terminal con tema \(settings.theme.label) y fuente de \(Int(settings.fontSize)) puntos")
            }
            .padding(.horizontal, 22).padding(.top, 20)
        Form {
            Section("Apariencia") {
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
            Section {
                HStack {
                    Text("Zoom del terminal").foregroundStyle(.secondary)
                    Spacer()
                    KeyboardHint(keys: "⌘ +")
                    KeyboardHint(keys: "⌘ −")
                    KeyboardHint(keys: "⌘ 0")
                }
                Button("Restablecer tamaño de fuente") { settings.resetFontSize() }
                    .disabled(settings.fontSize == TerminalSettings.defaultFontSize)
            }
            Section {
                Stepper(
                    value: $settings.maxLiveTerminals,
                    in: TerminalSettings.minLiveTerminals...TerminalSettings.maxLiveTerminals,
                    step: 2
                ) {
                    LabeledContent("Terminales abiertos a la vez") {
                        Text("\(settings.maxLiveTerminals)").monospacedDigit()
                    }
                }
            } header: {
                Text("Sesiones")
            } footer: {
                Text("Al superar el tope, la sesión que llevas más tiempo sin usar se duerme: sigue corriendo en el servidor y se reconecta al abrirla. El cambio se aplica al abrir el próximo terminal.")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        }
    }
}
