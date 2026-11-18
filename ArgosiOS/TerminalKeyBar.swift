//
//  TerminalKeyBar.swift
//  ArgosiOS
//
//  Barra de teclas sobre el teclado del terminal (sustituye a la de SwiftTerm): esc,
//  tab, Mayús+Tab, ctrl y alt pegajosos, prefijo de tmux, flechas, símbolos, Inicio/Fin,
//  RePág/AvPág y ocultar el teclado. Qué envía cada tecla lo decide `TerminalKeyEncoder`
//  (ArgosCore, con tests); aquí solo están los botones.
//
//  Ctrl y Alt: un toque vale para la próxima tecla, dos lo fijan y tres lo apagan. Para
//  el texto del teclado del sistema se apoyan en `controlModifier`/`metaModifier` de
//  SwiftTerm, que los aplica a la siguiente pulsación y avisa al soltarlos.
//

import SwiftTerm
import UIKit

final class TerminalKeyBar: UIInputView {
    /// Bytes que enviar al PTY.
    var onSend: (([UInt8]) -> Void)?

    private weak var terminalView: TerminalView?
    private var modifiers = StickyModifiers() { didSet { syncModifiers() } }
    private var buttons: [ExtraKey: UIButton] = [:]
    private var repeatTimer: Timer?

    private static let repeatDelay: TimeInterval = 0.4
    private static let repeatInterval: TimeInterval = 0.07

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        let compact = UIDevice.current.userInterfaceIdiom == .phone
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: compact ? 40 : 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        buildBar()
        observeModifierResets()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) no se usa") }

    /// Fuera de la ventana (teclado oculto): que no siga repitiendo una flecha.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { stopRepeat() }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: frame.height)
    }

    // MARK: - Construcción

    private func buildBar() {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: scroll.frameLayoutGuide.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: scroll.frameLayoutGuide.bottomAnchor, constant: -5),
        ])
        for key in ExtraKey.barOrder {
            let button = makeButton(for: key)
            buttons[key] = button
            stack.addArrangedSubview(button)
        }
        syncModifiers()
    }

    private func makeButton(for key: ExtraKey) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = UIColor(white: 0.32, alpha: 1)
        config.baseForegroundColor = .white
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        if let symbol = key.symbolName {
            config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        } else if let label = key.label {
            var title = AttributedString(label)
            title.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
            config.attributedTitle = title
        }
        let button = UIButton(configuration: config)
        button.accessibilityLabel = key.accessibilityName
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.tap(key) }, for: .touchUpInside)
        if key.repeats {
            button.addAction(UIAction { [weak self] _ in self?.startRepeat(key) }, for: .touchDown)
            for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit] {
                button.addAction(UIAction { [weak self] _ in self?.stopRepeat() }, for: event)
            }
        }
        return button
    }

    // MARK: - Pulsaciones

    private func tap(_ key: ExtraKey) {
        UIDevice.current.playInputClick()
        if key == .hideKeyboard {
            _ = terminalView?.resignFirstResponder()
            return
        }
        // Las teclas que se repiten ya enviaron su primera pulsación en `touchDown`.
        guard !key.repeats else { return }
        press(key)
    }

    private func press(_ key: ExtraKey) {
        let applicationCursor = terminalView?.getTerminal().applicationCursor ?? false
        let encoded = TerminalKeyEncoder.encode(key, modifiers: modifiers, applicationCursor: applicationCursor)
        modifiers = encoded.modifiers
        if !encoded.bytes.isEmpty { onSend?(encoded.bytes) }
    }

    private func startRepeat(_ key: ExtraKey) {
        stopRepeat()
        press(key)
        repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.press(key) }
                }
            }
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    // MARK: - Modificadores

    /// Refleja Ctrl/Alt en SwiftTerm (para el texto del teclado) y en los botones.
    private func syncModifiers() {
        terminalView?.controlModifier = modifiers.ctrl.isActive
        terminalView?.metaModifier = modifiers.alt.isActive
        paint(.ctrl, latch: modifiers.ctrl)
        paint(.alt, latch: modifiers.alt)
    }

    private func paint(_ key: ExtraKey, latch: ModifierLatch) {
        guard let button = buttons[key] else { return }
        var config = button.configuration
        switch latch {
        case .off: config?.baseBackgroundColor = UIColor(white: 0.32, alpha: 1)
        case .once: config?.baseBackgroundColor = .systemIndigo
        case .locked: config?.baseBackgroundColor = .systemOrange
        }
        button.configuration = config
        button.accessibilityValue = switch latch {
        case .off: String(localized: "Desactivado")
        case .once: String(localized: "Para la próxima tecla")
        case .locked: String(localized: "Fijado")
        }
    }

    /// SwiftTerm suelta el modificador tras aplicarlo a una tecla del teclado: el de un
    /// solo uso se apaga y el fijado se vuelve a armar.
    private func observeModifierResets() {
        // Con selector: el centro de notificaciones deja de avisar solo al liberarse la barra.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(controlWasConsumed),
                           name: .terminalViewControlModifierReset, object: terminalView)
        center.addObserver(self, selector: #selector(metaWasConsumed),
                           name: .terminalViewMetaModifierReset, object: terminalView)
    }

    @objc private func controlWasConsumed() { modifierWasConsumed(.ctrl) }
    @objc private func metaWasConsumed() { modifierWasConsumed(.alt) }

    private func modifierWasConsumed(_ key: ExtraKey) {
        let latch = key == .ctrl ? modifiers.ctrl : modifiers.alt
        guard latch != .off else { return }
        let after = latch.afterUse
        modifiers = key == .ctrl
            ? StickyModifiers(ctrl: after, alt: modifiers.alt)
            : StickyModifiers(ctrl: modifiers.ctrl, alt: after)
    }
}

extension TerminalKeyBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
