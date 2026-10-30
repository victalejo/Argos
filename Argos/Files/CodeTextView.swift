//
//  CodeTextView.swift
//  Argos
//
//  Visor de código de solo lectura: NSTextView (rinde bien con archivos grandes y
//  permite seleccionar/copiar) con números de línea en el margen y el resaltado de
//  `SyntaxHighlighter` pintado con colores del sistema (claro/oscuro automáticos).
//

import AppKit
import SwiftUI

struct CodeTextView: NSViewRepresentable {
    let text: String
    let language: String?
    var fontSize: CGFloat = 12.5

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 8, height: 10)
        // Sin ajuste de línea: el código se lee mejor con scroll horizontal.
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        apply(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text || context.coordinator.language != language
            || context.coordinator.fontSize != fontSize {
            apply(to: textView)
            textView.scroll(.zero)
        }
        context.coordinator.language = language
        context.coordinator.fontSize = fontSize
        scrollView.verticalRulerView?.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(language: language, fontSize: fontSize) }

    final class Coordinator {
        var language: String?
        var fontSize: CGFloat
        init(language: String?, fontSize: CGFloat) {
            self.language = language
            self.fontSize = fontSize
        }
    }

    private func apply(to textView: NSTextView) {
        textView.textStorage?.setAttributedString(Self.highlighted(text, language: language, fontSize: fontSize))
    }

    /// Texto con atributos: fuente monoespaciada + colores por tipo de token.
    static func highlighted(_ text: String, language: String?, fontSize: CGFloat) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.15
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        for token in SyntaxHighlighter.tokens(in: text, language: language) {
            result.addAttribute(.foregroundColor, value: color(for: token.kind), range: token.range)
            if token.kind == .keyword {
                result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold), range: token.range)
            }
            if token.kind == .comment {
                let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                result.addAttribute(.font, value: italic, range: token.range)
            }
        }
        return result
    }

    private static func color(for kind: SyntaxHighlighter.Token.Kind) -> NSColor {
        switch kind {
        case .keyword: return .systemPink
        case .string: return .systemRed
        case .number: return .systemPurple
        case .comment: return .secondaryLabelColor
        }
    }
}

/// Margen con números de línea para el NSTextView del visor.
private final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentChanged),
            name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentChanged),
            name: NSText.didChangeNotification, object: textView
        )
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) no se usa") }

    @objc private func contentChanged() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Número de la primera línea visible.
        var lineNumber = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: characterRange.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            lineNumber += 1
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let inset = textView.textContainerInset.height
        var index = characterRange.location
        while index <= NSMaxRange(characterRange) && index <= text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyphs = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var lineRect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            lineRect.origin.y += inset - visible.origin.y
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: lineRect.minY + (lineRect.height - size.height) / 2), withAttributes: attributes)
            lineNumber += 1
            let next = NSMaxRange(lineRange)
            if next == index || next >= text.length { break }
            index = next
        }
    }
}
