package com.iaportafolio.argos.core

import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.CsvSource
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Paridad con `ArgosTests/PTYSizeTests.swift` (anti-crash de zsh con terminales diminutos). */
class PTYSizeTest {

    // (19, 24) y (80, 4) son MIN_COLS - 1 y MIN_ROWS - 1.
    @ParameterizedTest
    @CsvSource("2,1", "0,0", "-1,10", "80,1", "5,40", "19,24", "80,4")
    fun `tamanos diminutos o invalidos no se propagan`(cols: Int, rows: Int) {
        assertFalse(PTYSize.isUsable(cols, rows))
    }

    @ParameterizedTest
    @CsvSource("20,5", "80,24", "250,70")
    fun `tamanos razonables si se propagan`(cols: Int, rows: Int) {
        assertTrue(PTYSize.isUsable(cols, rows))
    }

    @Test
    fun `los limites coinciden con Apple`() {
        assertEquals(20, PTYSize.MIN_COLS)
        assertEquals(5, PTYSize.MIN_ROWS)
    }

    @Test
    fun `el tamano inicial diminuto cae a 80x24`() {
        assertEquals(PTYSize.Dimensions(PTYSize.FALLBACK_COLS, PTYSize.FALLBACK_ROWS), PTYSize.initial(2, 1))
        assertEquals(PTYSize.Dimensions(80, 24), PTYSize.initial(2, 1))
    }

    @Test
    fun `el tamano inicial razonable se respeta`() {
        assertEquals(PTYSize.Dimensions(132, 40), PTYSize.initial(132, 40))
    }
}
