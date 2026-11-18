//
//  DiagnosticSecretScrubber.swift
//  ArgosCore
//
//  Eliminación (lógica pura) de SECRETOS en el informe «Copiar diagnóstico», pensado para
//  pegarse en un issue público. Se aplica SIEMPRE, con o sin la opción de incluir datos
//  personales, y ANTES de cualquier recorte por tamaño. Cubre:
//   · bloques de clave privada (PEM/OpenSSH, completos, cortados o sin cabecera),
//   · credenciales dentro de URL (`esquema://usuario:contraseña@host`),
//   · cabeceras `Authorization`, `Bearer`/`Basic`, `Cookie`/`Set-Cookie`, JWT,
//   · tokens con prefijo conocido (Anthropic, GitHub, GitLab, Slack, AWS, npm, OpenAI…),
//   · pares clave/valor (texto, JSON con la clave entre comillas, variables de entorno,
//     opciones de línea de comandos) con nombres como token, password, secret, api key,
//     credential, private key, session id, auth…,
//   · rutas de claves privadas (`~/.ssh/…`, `id_ed25519`, `*.pem`, `*.key`).
//  No toca texto normal: «el token caducó», hashes de commit y huellas SHA256 de host key
//  no son secretos y se conservan.
//

import Foundation

enum DiagnosticSecretScrubber {

    static let marker = "[secreto]"
    static let keyPathMarker = "[ruta-de-clave]"
    static let privateKeyMarker = "[clave-privada]"

    static func scrub(_ text: String) -> String {
        var result = text
        result = replace(pemBlock, in: result, with: privateKeyMarker)
        result = scrubOrphanKeyTails(in: result)
        result = replace(urlPassword, in: result, with: "$1\(marker)@")
        result = replace(urlTokenAsUser, in: result, with: "$1\(marker)@")
        result = replace(authorizationHeader, in: result, with: "$1\(marker)")
        result = replace(bearer, in: result, with: "Bearer \(marker)")
        result = replaceGroups(basic, in: result) { groups in
            hasDigitOrPadding(groups[1]) ? "Basic \(marker)" : groups[0]
        }
        result = replace(jwt, in: result, with: marker)
        for pattern in tokenPrefixes { result = replace(pattern, in: result, with: marker) }
        result = replace(cookie, in: result, with: "$1\(marker)")
        result = replace(commandLineFlag, in: result, with: "$1\(marker)")
        result = replace(strongKeyValue, in: result, with: "$1\(marker)")
        result = replaceGroups(ambiguousKeyValue, in: result) { groups in
            looksLikeOpaqueValue(groups[2]) ? groups[1] + marker : groups[0]
        }
        result = replaceGroups(pathCandidate, in: result) { groups in
            looksLikeKeyPath(groups[0]) ? keyPathMarker : groups[0]
        }
        return result
    }

    // MARK: - Patrones

    private static let pemBlock =
        #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?(?:-----)?[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----|\z)"#
    private static let pemEnd = #"-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----"#

    private static let urlPassword = #"(?i)([a-z][a-z0-9+.\-]*://[^/\s:@"'<>]*:)[^/\s"'<>]+@"#
    private static let urlTokenAsUser = #"(?i)([a-z][a-z0-9+.\-]*://)[A-Za-z0-9_\-.~%]{20,}@"#

    private static let authorizationHeader =
        #"(?i)(authorization["']?\s*[:=]\s*["']?)(?:(?:basic|bearer|token|digest|negotiate)\s+)?(?:\[secreto\]|[^\s"',;}\]]+)"#
    private static let bearer = #"\b[Bb]earer\s+[A-Za-z0-9._~+/=\-]{8,}"#
    private static let basic = #"\b[Bb]asic\s+([A-Za-z0-9+/]{8,}={0,2})"#
    private static let jwt = #"\beyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}(?:\.[A-Za-z0-9_\-]*)?"#

    /// Tokens con prefijo propio (no dependen de que haya una clave delante).
    private static let tokenPrefixes = [
        #"\bsk-ant-[A-Za-z0-9_\-]{6,}"#,                        // Anthropic (API y OAuth `sk-ant-oat…`)
        #"\bsk-[A-Za-z0-9_\-]{20,}"#,                           // `sk-…` genérico (OpenAI y similares)
        #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}"#,         // GitHub
        #"\bgithub_pat_[A-Za-z0-9_]{16,}"#,
        #"\bglpat-[A-Za-z0-9_\-]{12,}"#,                        // GitLab
        #"\bxox[abprs]-[A-Za-z0-9\-]{8,}"#,                     // Slack
        #"\b(?:AKIA|ASIA|AGPA|AIDA|AROA)[A-Z0-9]{16}\b"#,       // AWS
        #"\bnpm_[A-Za-z0-9]{20,}"#,
        #"\bAIza[A-Za-z0-9_\-]{30,}"#,                          // Google
        #"\b[sr]k_(?:live|test)_[A-Za-z0-9]{10,}"#,             // Stripe
    ]

    private static let cookie = #"(?i)((?:set-)?cookie["']?\s*[:=]\s*)[^\n⏎]+"#
    private static let commandLineFlag =
        #"(?i)(--(?:[a-z0-9]+-)*(?:token|password|passwd|passphrase|secret|api[_-]?key)(?:=|\s+))(?:\[secreto\]|"[^"]*"|'[^']*'|[^\s"']+)"#

    private static let strongWords =
        #"token|password|passwd|passphrase|secret|api[_-]?key|credentials?|private[_-]?key|session[_-]?(?:id|key|token)|sessionid|authorization"#
    /// `clave = valor`, `"clave": "valor"`, `export CLAVE_TOKEN=valor`.
    private static let strongKeyValue =
        #"(?i)(["']?[A-Za-z0-9_.\-]*(?:"# + strongWords
        + #")[A-Za-z0-9_\-]*["']?\s*[=:]\s*)(?:\[secreto\]|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\s,;&"'}\]]+)"#
    /// Claves cortas y ambiguas: solo se oculta un valor con pinta de credencial opaca.
    private static let ambiguousKeyValue =
        #"(?i)(["']?\b(?:auth|session)["']?\s*[=:]\s*)("[^"\n]*"|'[^'\n]*'|[^\s,;"'}\]]+)"#

    private static let pathCandidate = #"(?:~|/)[^\s"'<>]*"#

    // MARK: - Reglas con código

    private static func hasDigitOrPadding(_ text: String) -> Bool {
        text.contains("=") || text.rangeOfCharacter(from: .decimalDigits) != nil
    }

    /// Valor sin espacios de 16+ caracteres, o de 10+ con algún dígito, en alfabeto de token.
    private static func looksLikeOpaqueValue(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard value.count >= 10, value != marker else { return false }
        let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=._~-%")
        guard value.unicodeScalars.allSatisfy(alphabet.contains) else { return false }
        return value.count >= 16 || value.rangeOfCharacter(from: .decimalDigits) != nil
    }

    static func looksLikeKeyPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.contains("/.ssh/") || lower.hasPrefix("~/.ssh") { return true }
        let name = lower.split(separator: "/").last.map(String.init) ?? lower
        let keyPrefixes = ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"]
        if keyPrefixes.contains(where: name.hasPrefix) { return true }
        return [".pem", ".key", ".ppk"].contains { name.hasSuffix($0) }
    }

    /// Cuerpo de una clave privada cuya cabecera se perdió (registro cortado): se retira el
    /// pie `-----END … PRIVATE KEY-----` y las palabras base64 largas que lo preceden. Procede
    /// hacia atrás por palabras (sin expresiones con retroceso: el texto puede ser grande).
    private static func scrubOrphanKeyTails(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pemEnd) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            var start = range.lowerBound
            var cursor = start
            var sawLongWord = false
            var words = 0
            while cursor > result.startIndex {
                // Salta separadores (espacios, saltos de línea y el «⏎» del registro).
                var wordEnd = cursor
                while wordEnd > result.startIndex, isSeparator(result[result.index(before: wordEnd)]) {
                    wordEnd = result.index(before: wordEnd)
                }
                var wordStart = wordEnd
                while wordStart > result.startIndex, isBase64(result[result.index(before: wordStart)]) {
                    wordStart = result.index(before: wordStart)
                }
                let length = result.distance(from: wordStart, to: wordEnd)
                if length >= 16 {
                    sawLongWord = true
                } else if !(words == 0 && length >= 2) {
                    break   // solo la última línea del cuerpo puede ser corta
                }
                start = wordStart
                cursor = wordStart
                words += 1
            }
            // Sin ninguna palabra larga no era un cuerpo de clave: solo se retira el pie.
            if !sawLongWord { start = range.lowerBound }
            result.replaceSubrange(start..<range.upperBound, with: privateKeyMarker)
        }
        return result
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character == "⏎"
    }

    private static func isBase64(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "+/=".contains(character))
    }

    // MARK: - Expresiones regulares

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Sustituye cada coincidencia por `transform(grupos)` (grupo 0 = coincidencia completa).
    private static func replaceGroups(_ pattern: String, in text: String, transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let groups = (0..<match.numberOfRanges).map { index -> String in
                Range(match.range(at: index), in: result).map { String(result[$0]) } ?? ""
            }
            result.replaceSubrange(range, with: transform(groups))
        }
        return result
    }
}
