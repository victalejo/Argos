package com.iaportafolio.argos.ui

import com.iaportafolio.argos.core.AuthMethod
import com.iaportafolio.argos.ui.form.FieldError
import com.iaportafolio.argos.ui.form.FormField
import com.iaportafolio.argos.ui.form.FormInput
import com.iaportafolio.argos.ui.form.ServerFormValidation
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ServerFormValidationTest {

    private val valid = FormInput(
        name = "dev", host = "dev.example.com", port = "22", username = "victor",
        authMethod = AuthMethod.PASSWORD, passwordEntered = true, hasStoredPassword = false,
        hasKey = false, requiresPassphrase = false, passphraseEntered = false, hasStoredPassphrase = false,
    )

    @Test
    fun `un formulario completo es válido`() {
        assertTrue(ServerFormValidation.validate(valid).isEmpty())
    }

    @ParameterizedTest
    @ValueSource(strings = ["192.168.1.10", "fe80::1", "servidor-1.lan", "[::1]"])
    fun `hosts válidos`(host: String) {
        assertNull(ServerFormValidation.validate(valid.copy(host = host))[FormField.HOST])
    }

    @ParameterizedTest
    @ValueSource(strings = ["mi host", "user@host", "-oProxyCommand=x", "host/ruta", "a\tb"])
    fun `hosts inválidos`(host: String) {
        assertEquals(FieldError.HOST_INVALID, ServerFormValidation.validate(valid.copy(host = host))[FormField.HOST])
    }

    @ParameterizedTest
    @ValueSource(strings = ["0", "65536", "", "abc", "-1"])
    fun `puertos inválidos`(port: String) {
        assertEquals(FieldError.PORT_INVALID, ServerFormValidation.validate(valid.copy(port = port))[FormField.PORT])
    }

    @Test
    fun `puertos en los extremos del rango`() {
        assertEquals(1, ServerFormValidation.parsePort("1"))
        assertEquals(65_535, ServerFormValidation.parsePort("65535"))
    }

    @Test
    fun `usuario vacío o con espacios`() {
        assertEquals(FieldError.USERNAME_REQUIRED, ServerFormValidation.validate(valid.copy(username = "  "))[FormField.USERNAME])
        assertEquals(FieldError.USERNAME_INVALID, ServerFormValidation.validate(valid.copy(username = "a b"))[FormField.USERNAME])
        assertEquals(FieldError.USERNAME_INVALID, ServerFormValidation.validate(valid.copy(username = "-l"))[FormField.USERNAME])
    }

    @Test
    fun `contraseña guardada cuenta como contraseña`() {
        val noPassword = valid.copy(passwordEntered = false)
        assertEquals(FieldError.PASSWORD_REQUIRED, ServerFormValidation.validate(noPassword)[FormField.PASSWORD])
        assertTrue(ServerFormValidation.validate(noPassword.copy(hasStoredPassword = true)).isEmpty())
    }

    @Test
    fun `método clave exige clave y, si procede, passphrase`() {
        val keyForm = valid.copy(authMethod = AuthMethod.KEY, passwordEntered = false)
        assertEquals(mapOf(FormField.KEY to FieldError.KEY_REQUIRED), ServerFormValidation.validate(keyForm))

        val withKey = keyForm.copy(hasKey = true, requiresPassphrase = true)
        assertEquals(mapOf(FormField.PASSPHRASE to FieldError.PASSPHRASE_REQUIRED), ServerFormValidation.validate(withKey))
        assertTrue(ServerFormValidation.validate(withKey.copy(hasStoredPassphrase = true)).isEmpty())
        assertTrue(ServerFormValidation.validate(withKey.copy(passphraseEntered = true)).isEmpty())
    }
}
