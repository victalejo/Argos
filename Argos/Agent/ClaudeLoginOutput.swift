//
//  ClaudeLoginOutput.swift
//  Argos
//
//  Interpreta la salida de `claude auth login --claudeai` (corre en un PTY del
//  servidor) para guiar el login con UI nativa: detecta el enlace de autorización y
//  el momento en que el CLI pide el código. Formato real observado (CLI 2026):
//
//      Opening browser to sign in…
//      If the browser didn't open, visit: ESC]8;;<URL>BEL<URL>ESC]8;;BEL
//      Paste code here if prompted >
//
//  Lógica pura y tolerante: si el texto cambia, la UI cae al terminal embebido.
//

import Foundation

struct ClaudeLoginOutput: Equatable, Sendable {
    /// Enlace de autorización OAuth (para abrirlo en el navegador del Mac).
    let authorizationURL: URL?
    /// El CLI ya espera que se pegue el código.
    let isAwaitingCode: Bool

    /// Analiza TODA la salida acumulada hasta ahora.
    static func parse(_ raw: String) -> ClaudeLoginOutput {
        let text = stripEscapes(raw)
        return ClaudeLoginOutput(
            authorizationURL: firstAuthorizationURL(in: text),
            isAwaitingCode: text.range(of: "paste code", options: .caseInsensitive) != nil
        )
    }

    /// Quita secuencias de escape de terminal: OSC (`ESC ] … BEL` o `ESC ] … ESC \`),
    /// CSI (`ESC [ … letra`) y retornos de carro, dejando el texto visible.
    static func stripEscapes(_ raw: String) -> String {
        var result = ""
        var iterator = raw.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        func next() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let scalar = next() {
            switch scalar {
            case "\u{1B}":
                guard let kind = next() else { break }
                if kind == "]" {
                    // OSC: hasta BEL o ESC \ (pero conservamos el destino si es un enlace:
                    // el propio texto visible repite la URL, así que basta con saltarlo).
                    while let c = next() {
                        if c == "\u{07}" { break }
                        if c == "\u{1B}" { _ = next(); break }
                    }
                } else if kind == "[" {
                    while let c = next(), !(("@"..."~").contains(c)) {}
                }
            case "\r":
                continue
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func firstAuthorizationURL(in text: String) -> URL? {
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            let candidate = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'()[]"))
            guard candidate.hasPrefix("https://"),
                  candidate.contains("oauth"),
                  let url = URL(string: candidate),
                  let host = url.host?.lowercased(),
                  Self.trustedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
            else { continue }
            return url
        }
        return nil
    }

    /// Solo se abren enlaces de Anthropic (la salida viene del servidor: no confiar).
    static let trustedHosts = ["claude.com", "claude.ai", "anthropic.com"]
}
