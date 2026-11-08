@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import com.iaportafolio.argos.core.AuthMethod
import com.iaportafolio.argos.core.keys.ImportedKeyValidation
import com.iaportafolio.argos.data.SecretKind
import com.iaportafolio.argos.testing.FakeDocumentReader
import com.iaportafolio.argos.testing.FakeServiceProvider
import com.iaportafolio.argos.testing.InMemorySecretStore
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.form.FieldError
import com.iaportafolio.argos.ui.form.FormField
import com.iaportafolio.argos.ui.form.KeyState
import com.iaportafolio.argos.ui.form.ServerFormViewModel
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import java.io.IOException
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ServerFormViewModelTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val repository = InMemoryServerRepository()
    private val secrets = InMemorySecretStore()
    private val provider = FakeServiceProvider()
    private val documents = FakeDocumentReader()

    private val key = "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----"

    private fun TestScope.viewModel(serverId: String? = null) =
        ServerFormViewModel(serverId, repository, secrets, provider, documents, main.dispatcher).also { advanceUntilIdle() }

    private fun ServerFormViewModel.fillBasics() {
        onNameChange(" dev ")
        onHostChange(" dev.example.com ")
        onPortChange("2222")
        onUsernameChange("victor")
    }

    @Test
    fun `los errores solo se muestran tras intentar guardar`() = runTest(main.dispatcher) {
        val vm = viewModel()
        assertTrue(vm.state.value.errors.isNotEmpty())
        assertTrue(vm.state.value.visibleErrors.isEmpty())

        vm.save()
        advanceUntilIdle()
        val errors = vm.state.value.visibleErrors
        assertEquals(FieldError.NAME_REQUIRED, errors[FormField.NAME])
        assertEquals(FieldError.HOST_REQUIRED, errors[FormField.HOST])
        assertEquals(FieldError.USERNAME_REQUIRED, errors[FormField.USERNAME])
        assertEquals(FieldError.PASSWORD_REQUIRED, errors[FormField.PASSWORD])
        assertTrue(repository.servers.value.isEmpty())
    }

    @Test
    fun `el puerto solo admite dígitos`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.onPortChange("22a33-999")
        assertEquals("22339", vm.state.value.port)
        vm.onPortChange("70000")
        assertEquals(FieldError.PORT_INVALID, vm.state.value.errors[FormField.PORT])
    }

    @Test
    fun `alta con contraseña guarda el servidor sin secretos y la contraseña aparte`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.fillBasics()
        vm.onPasswordChange("s3creta")
        vm.save()
        advanceUntilIdle()

        val saved = repository.servers.value.single()
        assertEquals("dev", saved.name)
        assertEquals("dev.example.com", saved.host)
        assertEquals(2222, saved.port)
        assertEquals(AuthMethod.PASSWORD, saved.authMethod)
        assertEquals("s3creta", secrets.read(saved.id, SecretKind.PASSWORD))
        assertTrue(vm.state.value.saved)
        assertEquals(listOf(saved.id), provider.invalidated)
        assertFalse(vm.state.value.toString().contains("s3creta"))
    }

    @Test
    fun `importar una clave válida y guardar con passphrase`() = runTest(main.dispatcher) {
        documents.bytes = key.encodeToByteArray()
        val vm = viewModel()
        vm.fillBasics()
        vm.onAuthMethodChange(AuthMethod.KEY)
        assertEquals(FieldError.KEY_REQUIRED, vm.state.value.errors[FormField.KEY])

        vm.onKeyFilePicked("content://docs/id_ed25519")
        advanceUntilIdle()
        assertEquals(KeyState.IMPORTED, vm.state.value.keyState)
        assertNull(vm.state.value.errors[FormField.KEY])
        assertFalse(vm.state.value.toString().contains("OPENSSH"))

        vm.onRequiresPassphraseChange(true)
        assertEquals(FieldError.PASSPHRASE_REQUIRED, vm.state.value.errors[FormField.PASSPHRASE])
        vm.onPassphraseChange("frase")
        vm.save()
        advanceUntilIdle()

        val saved = repository.servers.value.single()
        assertEquals(AuthMethod.KEY, saved.authMethod)
        assertTrue(saved.requiresPassphrase)
        assertEquals("$key\n", secrets.read(saved.id, SecretKind.PRIVATE_KEY))
        assertEquals("frase", secrets.read(saved.id, SecretKind.PASSPHRASE))
        assertEquals("", saved.privateKeyPath)
    }

    @Test
    fun `una clave inválida o ilegible se rechaza con su mensaje`() = runTest(main.dispatcher) {
        documents.bytes = "ssh-ed25519 AAAA pública".encodeToByteArray()
        val vm = viewModel()
        vm.onAuthMethodChange(AuthMethod.KEY)
        vm.onKeyFilePicked("content://x")
        advanceUntilIdle()
        assertEquals(KeyState.MISSING, vm.state.value.keyState)
        assertEquals(UiText.Plain(ImportedKeyValidation.Reason.NOT_OPENSSH_KEY.message), vm.state.value.message)
        assertFalse(vm.state.value.isImportingKey)

        documents.error = IOException("No se pudo abrir el archivo elegido.")
        vm.onKeyFilePicked("content://y")
        advanceUntilIdle()
        assertEquals(UiText.Plain("No se pudo abrir el archivo elegido."), vm.state.value.message)
    }

    @Test
    fun `cancelar el selector no hace nada`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.onKeyFilePicked(null)
        advanceUntilIdle()
        assertTrue(documents.requested.isEmpty())
    }

    @Test
    fun `editar sin teclear la contraseña conserva la guardada`() = runTest(main.dispatcher) {
        repository.upsert(server(id = "A"))
        secrets.write("A", SecretKind.PASSWORD, "vieja")
        val vm = viewModel("A")
        assertFalse(vm.state.value.isNew)
        assertTrue(vm.state.value.hasStoredPassword)
        assertNull(vm.state.value.errors[FormField.PASSWORD])

        vm.onNameChange("renombrado")
        vm.save()
        advanceUntilIdle()

        assertEquals("renombrado", repository.server("A")?.name)
        assertEquals("vieja", secrets.read("A", SecretKind.PASSWORD))
        assertEquals(listOf("A"), provider.invalidated)
    }

    @Test
    fun `cambiar de contraseña a clave guardada borra la contraseña obsoleta`() = runTest(main.dispatcher) {
        repository.upsert(server(id = "A"))
        secrets.write("A", SecretKind.PASSWORD, "vieja")
        documents.bytes = key.encodeToByteArray()
        val vm = viewModel("A")
        vm.onAuthMethodChange(AuthMethod.KEY)
        vm.onKeyFilePicked("content://k")
        advanceUntilIdle()
        vm.save()
        advanceUntilIdle()

        assertNull(secrets.read("A", SecretKind.PASSWORD))
        assertNotNull(secrets.read("A", SecretKind.PRIVATE_KEY))
        assertEquals(AuthMethod.KEY, repository.server("A")?.authMethod)
    }

    @Test
    fun `editar una clave con passphrase guardada no la exige de nuevo`() = runTest(main.dispatcher) {
        repository.upsert(server(id = "K", authMethod = AuthMethod.KEY, requiresPassphrase = true))
        secrets.write("K", SecretKind.PRIVATE_KEY, key)
        secrets.write("K", SecretKind.PASSPHRASE, "frase")
        val vm = viewModel("K")

        assertEquals(KeyState.STORED, vm.state.value.keyState)
        assertTrue(vm.state.value.hasStoredPassphrase)
        assertTrue(vm.state.value.errors.isEmpty())

        // Desactivar la passphrase la borra al guardar.
        vm.onRequiresPassphraseChange(false)
        vm.save()
        advanceUntilIdle()
        assertNull(secrets.read("K", SecretKind.PASSPHRASE))
        assertEquals(false, repository.server("K")?.requiresPassphrase)
    }

    @Test
    fun `si falla guardar un alta no quedan secretos huérfanos`() = runTest(main.dispatcher) {
        repository.failWrites = IOException("Disco lleno")
        val vm = viewModel()
        vm.fillBasics()
        vm.onPasswordChange("pw")
        vm.save()
        advanceUntilIdle()

        assertFalse(vm.state.value.saved)
        assertFalse(vm.state.value.isSaving)
        assertEquals(UiText.Plain("Disco lleno"), vm.state.value.message)
        assertTrue(secrets.values.isEmpty())
        assertEquals(1, secrets.deletedAll.size)
    }

    @Test
    fun `editar un servidor inexistente`() = runTest(main.dispatcher) {
        val vm = viewModel("borrado")
        assertTrue(vm.state.value.notFound)
        vm.save()
        advanceUntilIdle()
        assertTrue(repository.servers.value.isEmpty())
    }
}
