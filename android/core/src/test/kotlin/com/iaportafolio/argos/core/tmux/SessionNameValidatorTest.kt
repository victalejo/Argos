package com.iaportafolio.argos.core.tmux

import com.iaportafolio.argos.core.tmux.SessionNameValidator.ValidationError
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Paridad con `ArgosTests/SessionNameValidatorTests.swift`. */
class SessionNameValidatorTest {

    @Test
    fun `nombre simple valido se devuelve recortado`() {
        assertEquals("main", SessionNameValidator.validate("  main  "))
    }

    @Test
    fun `se permite la barra para agrupar`() {
        assertEquals("magic-agents/backend", SessionNameValidator.validate("magic-agents/backend"))
    }

    @Test
    fun `vacio o solo espacios lanza Empty`() {
        assertEquals(ValidationError.Empty, assertFailsWith<ValidationError> { SessionNameValidator.validate("   ") })
    }

    @ParameterizedTest
    @ValueSource(chars = [':', '.'])
    fun `caracteres prohibidos de tmux lanzan ForbiddenCharacter`(char: Char) {
        val error = assertFailsWith<ValidationError> { SessionNameValidator.validate("a${char}b") }
        assertEquals(ValidationError.ForbiddenCharacter(char), error)
    }

    @ParameterizedTest
    @ValueSource(strings = ["a\nb", "a\tb", "a\u0007b"])
    fun `caracteres de control embebidos lanzan ControlCharacter`(input: String) {
        assertEquals(ValidationError.ControlCharacter, assertFailsWith<ValidationError> { SessionNameValidator.validate(input) })
    }

    @Test
    fun `prefijo guion lanza LeadingDash`() {
        assertEquals(ValidationError.LeadingDash, assertFailsWith<ValidationError> { SessionNameValidator.validate("-X") })
    }

    @Test
    fun `isValid refleja validez sin lanzar`() {
        assertTrue(SessionNameValidator.isValid("ok"))
        assertFalse(SessionNameValidator.isValid(""))
        assertFalse(SessionNameValidator.isValid("a:b"))
        assertFalse(SessionNameValidator.isValid("-x"))
    }

    @Test
    fun `liveValidationMessage no reporta el vacio pero si los invalidos`() {
        assertNull(SessionNameValidator.liveValidationMessage(""))
        assertNull(SessionNameValidator.liveValidationMessage("ok"))
        assertNotNull(SessionNameValidator.liveValidationMessage("a.b"))
    }

    @Test
    fun `el mensaje del caracter prohibido es el mismo que en Apple`() {
        assertEquals(
            "El nombre no puede contener ':': tmux usa ':' y '.' como separadores de sesión.",
            SessionNameValidator.liveValidationMessage("a:b"),
        )
    }
}
