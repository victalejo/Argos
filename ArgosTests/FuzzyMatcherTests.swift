//
//  FuzzyMatcherTests.swift
//  ArgosTests
//

import Testing
@testable import Argos

@Suite("FuzzyMatcher.score")
struct FuzzyMatcherTests {

    @Test("Query vacía coincide con todo (score 0)")
    func emptyQuery() {
        #expect(FuzzyMatcher.score("", in: "lo que sea") == 0)
    }

    @Test("Subsequence coincide")
    func subsequence() {
        #expect(FuzzyMatcher.score("tst", in: "test") != nil)
        #expect(FuzzyMatcher.score("dpl", in: "deploy") != nil)
    }

    @Test("No coincide si falta una letra en orden")
    func noMatch() {
        #expect(FuzzyMatcher.score("xyz", in: "test") == nil)
        #expect(FuzzyMatcher.score("tset", in: "test") == nil) // orden importa
    }

    @Test("Insensible a mayúsculas y acentos")
    func caseAndDiacritics() {
        #expect(FuzzyMatcher.score("SESION", in: "sesión 6") != nil)
        #expect(FuzzyMatcher.score("produccion", in: "Producción") != nil)
    }

    @Test("Coincidencia contigua puntúa más que dispersa")
    func contiguousScoresHigher() throws {
        let contiguous = try #require(FuzzyMatcher.score("test", in: "test"))
        let scattered = try #require(FuzzyMatcher.score("test", in: "t-e-s-t"))
        #expect(contiguous > scattered)
    }

    @Test("Prefijo exacto puntúa alto")
    func prefix() throws {
        let s = try #require(FuzzyMatcher.score("dep", in: "deploy"))
        #expect(s > 0)
    }
}
