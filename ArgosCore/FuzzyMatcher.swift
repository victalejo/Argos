//
//  FuzzyMatcher.swift
//  ArgosCore
//
//  Coincidencia difusa para el selector rápido y el filtro de archivos (lógica pura).
//

import Foundation

// MARK: - Coincidencia difusa (lógica pura, testeable)

enum FuzzyMatcher {
    /// Puntuación (mayor = mejor) si `query` hace subsequence-match en `text`
    /// (sin distinguir mayúsculas ni acentos). `nil` si no coincide.
    /// Query vacía siempre coincide (score 0).
    static func score(_ query: String, in text: String) -> Int? {
        let q = Array(normalize(query))
        guard !q.isEmpty else { return 0 }
        let t = Array(normalize(text))
        guard !t.isEmpty else { return nil }

        var score = 0
        var ti = 0
        var lastMatch = -2
        for qc in q {
            var found = -1
            var i = ti
            while i < t.count {
                if t[i] == qc { found = i; break }
                i += 1
            }
            guard found >= 0 else { return nil }
            if found == lastMatch + 1 { score += 5 }                 // contiguo
            if found == 0 || t[found - 1] == " " || t[found - 1] == "/" || t[found - 1] == "-" {
                score += 3                                            // inicio de palabra
            }
            score += 1
            lastMatch = found
            ti = found + 1
        }
        return score
    }

    private static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }
}
