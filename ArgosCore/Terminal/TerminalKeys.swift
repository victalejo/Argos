//
//  TerminalKeys.swift
//  ArgosCore
//
//  Modelo de la barra de teclas sobre el teclado del terminal (iPhone/iPad), portado de
//  `TerminalKeys.kt` de Android y ampliado con Mayús+Tab (`ESC [ Z`, cambia de modo en
//  Claude Code) y «ocultar teclado». Traducción pura de cada tecla a la secuencia xterm
//  que espera el PTY (`xterm-256color`): sin UIKit, se prueba en los tests del Mac.
//

import Foundation

/// Teclas de la barra extra.
enum ExtraKey: String, CaseIterable, Sendable {
    case esc
    case tab
    case shiftTab
    case ctrl
    case alt
    /// Prefijo de tmux (`Ctrl-b`).
    case tmuxPrefix
    case left, up, down, right
    case home, end, pageUp, pageDown
    case pipe, tilde, slash, dash
    /// Oculta el teclado (no envía nada).
    case hideKeyboard

    /// Se repite al mantenerla pulsada.
    var repeats: Bool {
        switch self {
        case .left, .up, .down, .right, .pageUp, .pageDown: return true
        default: return false
        }
    }

    /// Modificador pegajoso (no envía nada por sí solo).
    var isModifier: Bool { self == .ctrl || self == .alt }

    /// Orden de la barra: lo más usado primero (a la izquierda, sin desplazar).
    static let barOrder: [ExtraKey] = [
        .esc, .tab, .shiftTab, .ctrl, .alt, .tmuxPrefix,
        .up, .down, .left, .right,
        .pipe, .tilde, .slash, .dash,
        .home, .end, .pageUp, .pageDown,
        .hideKeyboard,
    ]

    /// Texto del botón (`nil` si se pinta con un símbolo).
    var label: String? {
        switch self {
        case .esc: return "esc"
        case .tab: return "tab"
        case .shiftTab: return "⇧tab"
        case .ctrl: return "ctrl"
        case .alt: return "alt"
        case .tmuxPrefix: return "^B"
        case .home: return "inicio"
        case .end: return "fin"
        case .pageUp: return "RePág"
        case .pageDown: return "AvPág"
        case .pipe: return "|"
        case .tilde: return "~"
        case .slash: return "/"
        case .dash: return "-"
        case .left, .up, .down, .right, .hideKeyboard: return nil
        }
    }

    /// Símbolo SF de las teclas sin texto.
    var symbolName: String? {
        switch self {
        case .left: return "arrow.left"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .right: return "arrow.right"
        case .hideKeyboard: return "keyboard.chevron.compact.down"
        default: return nil
        }
    }

    /// Nombre para VoiceOver.
    var accessibilityName: String {
        switch self {
        case .esc: return "Escape"
        case .tab: return "Tabulador"
        case .shiftTab: return "Mayúsculas y tabulador"
        case .ctrl: return "Control"
        case .alt: return "Alt"
        case .tmuxPrefix: return "Prefijo de tmux"
        case .left: return "Flecha izquierda"
        case .up: return "Flecha arriba"
        case .down: return "Flecha abajo"
        case .right: return "Flecha derecha"
        case .home: return "Inicio"
        case .end: return "Fin"
        case .pageUp: return "Retroceder página"
        case .pageDown: return "Avanzar página"
        case .pipe: return "Barra vertical"
        case .tilde: return "Virgulilla"
        case .slash: return "Barra"
        case .dash: return "Guion"
        case .hideKeyboard: return "Ocultar teclado"
        }
    }
}

/// Estado de un modificador pegajoso: apagado, para la próxima tecla o fijado.
enum ModifierLatch: Sendable, Equatable {
    case off, once, locked

    var isActive: Bool { self != .off }

    /// Un toque lo activa, el segundo lo fija y el tercero lo apaga.
    var next: ModifierLatch {
        switch self {
        case .off: return .once
        case .once: return .locked
        case .locked: return .off
        }
    }

    /// Tras usarse en una tecla: el de un solo uso se apaga, el fijado sigue.
    var afterUse: ModifierLatch { self == .once ? .off : self }
}

/// Ctrl y Alt pegajosos de la barra. Inmutable: cada cambio devuelve una copia.
struct StickyModifiers: Sendable, Equatable {
    var ctrl: ModifierLatch = .off
    var alt: ModifierLatch = .off

    /// Toque en la tecla de un modificador; las demás no cambian nada.
    func tapped(_ key: ExtraKey) -> StickyModifiers {
        switch key {
        case .ctrl: return StickyModifiers(ctrl: ctrl.next, alt: alt)
        case .alt: return StickyModifiers(ctrl: ctrl, alt: alt.next)
        default: return self
        }
    }

    func consumed() -> StickyModifiers {
        StickyModifiers(ctrl: ctrl.afterUse, alt: alt.afterUse)
    }
}

/// Bytes que enviar y modificadores que quedan tras enviarlos.
struct EncodedKeyInput: Sendable, Equatable {
    let bytes: [UInt8]
    let modifiers: StickyModifiers
}

/// Traducción de teclas a secuencias xterm: flechas `ESC [ A` (o `ESC O A` en modo
/// cursor de aplicación), modificadores `ESC [ 1 ; m A`, Ctrl+letra → código de control
/// y Alt → prefijo ESC.
enum TerminalKeyEncoder {
    private static let esc: UInt8 = 0x1B
    private static let del: UInt8 = 0x7F
    private static let tmuxPrefix: UInt8 = 0x02

    /// Secuencia de una tecla. Ctrl, Alt y «ocultar teclado» no envían nada.
    static func bytes(
        for key: ExtraKey, ctrl: Bool, alt: Bool, applicationCursor: Bool
    ) -> [UInt8] {
        switch key {
        case .ctrl, .alt, .hideKeyboard: return []
        case .esc: return withAlt([esc], alt)
        case .tab: return withAlt([0x09], alt)
        case .shiftTab: return withAlt(Array("\u{1B}[Z".utf8), alt)
        case .tmuxPrefix: return [tmuxPrefix]
        case .up: return cursor("A", ctrl: ctrl, alt: alt, applicationCursor: applicationCursor)
        case .down: return cursor("B", ctrl: ctrl, alt: alt, applicationCursor: applicationCursor)
        case .right: return cursor("C", ctrl: ctrl, alt: alt, applicationCursor: applicationCursor)
        case .left: return cursor("D", ctrl: ctrl, alt: alt, applicationCursor: applicationCursor)
        case .home: return cursor("H", ctrl: ctrl, alt: alt, applicationCursor: applicationCursor)
        case .end: return cursor("F", ctrl: ctrl, alt: alt, applicationCursor: applicationCursor)
        case .pageUp: return tilde(5, ctrl: ctrl, alt: alt)
        case .pageDown: return tilde(6, ctrl: ctrl, alt: alt)
        case .pipe: return character("|", ctrl: ctrl, alt: alt)
        case .tilde: return character("~", ctrl: ctrl, alt: alt)
        case .slash: return character("/", ctrl: ctrl, alt: alt)
        case .dash: return character("-", ctrl: ctrl, alt: alt)
        }
    }

    /// Tecla aplicando los modificadores pegajosos y consumiéndolos.
    static func encode(
        _ key: ExtraKey, modifiers: StickyModifiers, applicationCursor: Bool
    ) -> EncodedKeyInput {
        if key.isModifier { return EncodedKeyInput(bytes: [], modifiers: modifiers.tapped(key)) }
        if key == .hideKeyboard { return EncodedKeyInput(bytes: [], modifiers: modifiers) }
        let bytes = bytes(
            for: key, ctrl: modifiers.ctrl.isActive, alt: modifiers.alt.isActive,
            applicationCursor: applicationCursor
        )
        return EncodedKeyInput(bytes: bytes, modifiers: modifiers.consumed())
    }

    /// Un carácter con modificadores: Ctrl lo convierte en código de control y Alt
    /// antepone ESC. En UTF-8.
    static func character(_ character: Character, ctrl: Bool, alt: Bool) -> [UInt8] {
        let utf8 = Array(String(character).utf8)
        guard ctrl, utf8.count == 1, let code = controlCode(utf8[0]) else { return withAlt(utf8, alt) }
        return withAlt([code], alt)
    }

    /// Código de control de Ctrl+`byte` (tabla de xterm/Termux); `nil` si no tiene.
    static func controlCode(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return byte - UInt8(ascii: "a") + 1
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return byte - UInt8(ascii: "A") + 1
        case UInt8(ascii: " "), UInt8(ascii: "2"), UInt8(ascii: "@"): return 0
        case UInt8(ascii: "["), UInt8(ascii: "3"): return esc
        case UInt8(ascii: "\\"), UInt8(ascii: "4"): return 28
        case UInt8(ascii: "]"), UInt8(ascii: "5"): return 29
        case UInt8(ascii: "^"), UInt8(ascii: "6"): return 30
        case UInt8(ascii: "_"), UInt8(ascii: "7"), UInt8(ascii: "/"), UInt8(ascii: "-"): return 31
        case UInt8(ascii: "8"), UInt8(ascii: "?"): return del
        default: return nil
        }
    }

    private static func cursor(
        _ final: Character, ctrl: Bool, alt: Bool, applicationCursor: Bool
    ) -> [UInt8] {
        let modifier = modifierParameter(ctrl: ctrl, alt: alt)
        let sequence: String
        if modifier > 1 {
            sequence = "\u{1B}[1;\(modifier)\(final)"
        } else if applicationCursor {
            sequence = "\u{1B}O\(final)"
        } else {
            sequence = "\u{1B}[\(final)"
        }
        return Array(sequence.utf8)
    }

    private static func tilde(_ number: Int, ctrl: Bool, alt: Bool) -> [UInt8] {
        let modifier = modifierParameter(ctrl: ctrl, alt: alt)
        let sequence = modifier > 1 ? "\u{1B}[\(number);\(modifier)~" : "\u{1B}[\(number)~"
        return Array(sequence.utf8)
    }

    /// Parámetro de modificadores de xterm: 1 + Alt(2) + Ctrl(4).
    private static func modifierParameter(ctrl: Bool, alt: Bool) -> Int {
        1 + (alt ? 2 : 0) + (ctrl ? 4 : 0)
    }

    private static func withAlt(_ bytes: [UInt8], _ alt: Bool) -> [UInt8] {
        alt ? [esc] + bytes : bytes
    }
}

/// Tamaño de letra del terminal: límites y pellizco.
enum TerminalFontSizing {
    static let minimum: Double = 8
    static let maximum: Double = 24

    static func clamped(_ size: Double) -> Double {
        min(max(size, minimum), maximum)
    }

    /// Tamaño tras pellizcar con escala `scale` desde `start`, redondeado a medio punto
    /// (cambiar la letra en cada fotograma repintaría el terminal sin necesidad).
    static func pinched(from start: Double, scale: Double) -> Double {
        guard scale.isFinite, scale > 0 else { return clamped(start) }
        return clamped((start * scale * 2).rounded() / 2)
    }
}
