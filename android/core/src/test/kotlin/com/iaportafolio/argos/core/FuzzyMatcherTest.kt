package com.iaportafolio.argos.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Paridad con `ArgosTests/FuzzyMatcherTests.swift`. */
class FuzzyMatcherTest {

    @Test
    fun `query vacia coincide con todo con score 0`() {
        assertEquals(0, FuzzyMatcher.score("", "lo que sea"))
    }

    @Test
    fun `subsequence coincide`() {
        assertNotNull(FuzzyMatcher.score("tst", "test"))
        assertNotNull(FuzzyMatcher.score("dpl", "deploy"))
    }

    @Test
    fun `no coincide si falta una letra en orden`() {
        assertNull(FuzzyMatcher.score("xyz", "test"))
        assertNull(FuzzyMatcher.score("tset", "test"))
    }

    @Test
    fun `insensible a mayusculas y acentos`() {
        assertNotNull(FuzzyMatcher.score("SESION", "sesión 6"))
        assertNotNull(FuzzyMatcher.score("produccion", "Producción"))
    }

    @Test
    fun `coincidencia contigua puntua mas que dispersa`() {
        val contiguous = assertNotNull(FuzzyMatcher.score("test", "test"))
        val scattered = assertNotNull(FuzzyMatcher.score("test", "t-e-s-t"))
        assertTrue(contiguous > scattered)
    }

    @Test
    fun `prefijo exacto puntua alto`() {
        assertTrue(assertNotNull(FuzzyMatcher.score("dep", "deploy")) > 0)
    }

    @Test
    fun `la puntuacion coincide con el algoritmo de Apple`() {
        // t(0): inicio +3, +1; e,s,t contiguos: +5 +1 cada uno.
        assertEquals(22, FuzzyMatcher.score("test", "test"))
        // Cada letra tras un '-' cuenta como inicio de palabra (+3 +1) pero no es contigua.
        assertEquals(16, FuzzyMatcher.score("test", "t-e-s-t"))
        assertNull(FuzzyMatcher.score("a", ""))
    }
}
