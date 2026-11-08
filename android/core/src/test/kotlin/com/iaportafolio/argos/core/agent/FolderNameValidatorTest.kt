package com.iaportafolio.argos.core.agent

import com.iaportafolio.argos.core.agent.FolderNameValidator.Failure
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.Arguments
import org.junit.jupiter.params.provider.MethodSource
import kotlin.test.assertEquals

/** Paridad con `ArgosTests/FolderNameValidatorTests.swift`. */
class FolderNameValidatorTest {

    @ParameterizedTest
    @MethodSource("validos")
    fun `nombres validos (se recortan espacios)`(raw: String, expected: String) {
        assertEquals(FolderNameValidator.Result.Valid(expected), FolderNameValidator.validate(raw))
    }

    @ParameterizedTest
    @MethodSource("invalidos")
    fun `nombres invalidos`(raw: String, failure: Failure) {
        assertEquals(FolderNameValidator.Result.Invalid(failure), FolderNameValidator.validate(raw))
    }

    companion object {
        @JvmStatic
        fun validos() = listOf(
            Arguments.of("proyecto", "proyecto"),
            Arguments.of("  mi app  ", "mi app"),
            Arguments.of("-raro", "-raro"),
            Arguments.of(".config", ".config"),
            Arguments.of("ñandú 2", "ñandú 2"),
        )

        @JvmStatic
        fun invalidos() = listOf(
            Arguments.of("", Failure.EMPTY),
            Arguments.of("   ", Failure.EMPTY),
            Arguments.of(".", Failure.RESERVED),
            Arguments.of("..", Failure.RESERVED),
            Arguments.of("a/b", Failure.CONTAINS_SLASH),
            Arguments.of("../fuera", Failure.CONTAINS_SLASH),
            Arguments.of("tab\tname", Failure.CONTROL_CHARACTER),
            Arguments.of("x".repeat(256), Failure.TOO_LONG),
        )
    }
}
