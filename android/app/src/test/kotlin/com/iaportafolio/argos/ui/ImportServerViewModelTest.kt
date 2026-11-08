@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import com.iaportafolio.argos.R
import com.iaportafolio.argos.data.SecretKind
import com.iaportafolio.argos.data.ServerImporter
import com.iaportafolio.argos.testing.IMPORT_NOW
import com.iaportafolio.argos.testing.InMemorySecretStore
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.InMemoryTrustStore
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.QR_FINGERPRINT
import com.iaportafolio.argos.testing.RacingTrustStore
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.testing.transfer
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.importer.ImportLink
import com.iaportafolio.argos.ui.importer.ImportServerViewModel
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import java.io.IOException
import java.time.Duration
import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ImportServerViewModelTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val repository = InMemoryServerRepository()
    private val secrets = InMemorySecretStore()
    private val hostKeys = InMemoryTrustStore()
    private var now: Instant = IMPORT_NOW

    private fun TestScope.viewModel(importer: ServerImporter = ServerImporter(repository, secrets, hostKeys, newId = { "NEW" })) =
        ImportServerViewModel(repository, importer, main.dispatcher, clock = { now }).also { advanceUntilIdle() }

    private fun TestScope.paste(vm: ImportServerViewModel, text: String) {
        vm.onLinkTextChange(text)
        vm.submitLink()
        advanceUntilIdle()
    }

    @Test
    fun `pegar un enlace válido enseña la confirmación sin guardar nada`() = runTest(main.dispatcher) {
        val vm = viewModel()
        paste(vm, "  " + transfer(port = 2222).urlString() + "\n")

        val state = vm.state.value
        val preview = assertNotNull(state.preview)
        assertEquals("dev", preview.name)
        assertEquals("victor@dev.example.com:2222", preview.address)
        assertEquals(QR_FINGERPRINT, preview.hostKeyFingerprint)
        assertFalse(preview.isDuplicate)
        assertFalse(preview.conflictsWithTrustedHostKey)
        assertTrue(state.canImport)
        assertNull(state.inputError)
        // El enlace (con la semilla) no se queda en el estado.
        assertEquals("", state.linkText)
        assertTrue(repository.servers.value.isEmpty())
        assertTrue(secrets.values.isEmpty())
        assertTrue(hostKeys.known.isEmpty())
    }

    @Test
    fun `el puerto 22 no se muestra`() = runTest(main.dispatcher) {
        val vm = viewModel()
        paste(vm, transfer().urlString())
        assertEquals("victor@dev.example.com", vm.state.value.preview?.address)
    }

    @Test
    fun `pegar vacío pide el enlace`() = runTest(main.dispatcher) {
        val vm = viewModel()
        paste(vm, "   ")
        assertEquals(UiText.res(R.string.import_error_empty), vm.state.value.inputError)
    }

    @Test
    fun `pegar algo que no es de Argos lo explica`() = runTest(main.dispatcher) {
        val vm = viewModel()
        paste(vm, "https://example.com")
        assertEquals(UiText.res(R.string.import_error_not_argos), vm.state.value.inputError)
        assertNull(vm.state.value.preview)
    }

    @Test
    fun `pegar un enlace dañado lo explica`() = runTest(main.dispatcher) {
        val vm = viewModel()
        paste(vm, "argos://add-server?d=bm8tZXMtanNvbg")
        assertEquals(UiText.res(R.string.import_error_malformed), vm.state.value.inputError)
    }

    @Test
    fun `un texto enorme se rechaza sin decodificarlo`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.onLinkTextChange("argos://add-server?d=" + "A".repeat(ImportLink.MAX_LENGTH * 4))
        assertEquals(ImportLink.MAX_LENGTH + 1, vm.state.value.linkText.length)
        vm.submitLink()
        advanceUntilIdle()
        assertEquals(UiText.res(R.string.import_error_too_long), vm.state.value.inputError)
    }

    @Test
    fun `un código caducado avisa con el motivo`() = runTest(main.dispatcher) {
        val vm = viewModel()
        paste(vm, transfer(createdAt = IMPORT_NOW - Duration.ofMinutes(6)).urlString())
        assertEquals(UiText.res(R.string.import_error_expired), vm.state.value.inputError)
        assertNull(vm.state.value.preview)
    }

    @Test
    fun `si caduca mientras se lee la confirmación no se importa`() = runTest(main.dispatcher) {
        val vm = viewModel()
        paste(vm, transfer().urlString())
        now = IMPORT_NOW + Duration.ofMinutes(6)
        vm.confirmImport()
        advanceUntilIdle()

        assertNull(vm.state.value.preview)
        assertEquals(UiText.res(R.string.import_error_expired), vm.state.value.inputError)
        assertTrue(repository.servers.value.isEmpty())
        assertTrue(secrets.values.isEmpty())
    }

    @Test
    fun `avisa del duplicado (mismo host, puerto y usuario)`() = runTest(main.dispatcher) {
        repository.upsert(server(id = "OLD", host = "dev.example.com").copy(username = "victor"))
        val vm = viewModel()
        paste(vm, transfer().urlString())
        assertEquals(true, vm.state.value.preview?.isDuplicate)
        assertTrue(vm.state.value.canImport)

        vm.scanAgain()
        paste(vm, transfer(username = "otro").urlString())
        assertEquals(false, vm.state.value.preview?.isDuplicate)
    }

    @Test
    fun `una huella confiada distinta bloquea la importación`() = runTest(main.dispatcher) {
        hostKeys.known["dev.example.com:22"] = "SHA256:otra"
        val vm = viewModel()
        paste(vm, transfer().urlString())

        assertEquals(true, vm.state.value.preview?.conflictsWithTrustedHostKey)
        assertFalse(vm.state.value.canImport)
        vm.confirmImport()
        advanceUntilIdle()
        assertTrue(repository.servers.value.isEmpty())
        assertNull(vm.state.value.importedServerId)
    }

    @Test
    fun `la misma huella confiada no es conflicto`() = runTest(main.dispatcher) {
        hostKeys.known["dev.example.com:22"] = QR_FINGERPRINT
        val vm = viewModel()
        paste(vm, transfer().urlString())
        assertEquals(false, vm.state.value.preview?.conflictsWithTrustedHostKey)
    }

    @Test
    fun `confirmar importa, guarda la huella y avisa para abrir el servidor`() = runTest(main.dispatcher) {
        val vm = viewModel()
        paste(vm, transfer().urlString())
        vm.confirmImport()
        assertTrue(vm.state.value.isImporting)
        advanceUntilIdle()

        val state = vm.state.value
        assertEquals("NEW", state.importedServerId)
        assertNull(state.preview)
        assertFalse(state.isImporting)
        assertEquals(listOf("NEW"), repository.servers.value.map { it.id })
        assertNotNull(secrets.values["NEW" to SecretKind.PRIVATE_KEY])
        assertEquals(mapOf("dev.example.com:22" to QR_FINGERPRINT), hostKeys.known)

        vm.importHandled()
        assertNull(vm.state.value.importedServerId)
        // Ya no queda nada que importar: confirmar otra vez no hace nada.
        vm.confirmImport()
        advanceUntilIdle()
        assertEquals(1, repository.servers.value.size)
    }

    @Test
    fun `si falla guardar se explica y se puede reintentar`() = runTest(main.dispatcher) {
        repository.failWrites = IOException("sin espacio")
        val vm = viewModel()
        paste(vm, transfer().urlString())
        vm.confirmImport()
        advanceUntilIdle()

        val state = vm.state.value
        assertNotNull(state.preview)
        assertFalse(state.isImporting)
        val error = assertNotNull(state.saveError as? UiText.Resource)
        assertEquals(R.string.import_save_failed, error.id)
        assertTrue(secrets.values.isEmpty())

        repository.failWrites = null
        vm.confirmImport()
        advanceUntilIdle()
        assertEquals("NEW", vm.state.value.importedServerId)
    }

    @Test
    fun `un conflicto que aparece al guardar bloquea la confirmación`() = runTest(main.dispatcher) {
        // La lectura de la vista previa no ve huella; al guardar ya hay otra.
        val racing = RacingTrustStore(afterFirstRead = "dev.example.com:22" to "SHA256:otra")
        val vm = viewModel(ServerImporter(repository, secrets, racing, newId = { "NEW" }))
        paste(vm, transfer().urlString())
        assertEquals(false, vm.state.value.preview?.conflictsWithTrustedHostKey)

        vm.confirmImport()
        advanceUntilIdle()
        assertEquals(true, vm.state.value.preview?.conflictsWithTrustedHostKey)
        assertFalse(vm.state.value.canImport)
        assertTrue(repository.servers.value.isEmpty())
    }

    @Test
    fun `un deep link abre la confirmación y no importa solo`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.onDeepLink(transfer().urlString())
        advanceUntilIdle()
        assertNotNull(vm.state.value.preview)
        assertTrue(repository.servers.value.isEmpty())
        assertNull(vm.state.value.importedServerId)
    }

    @Test
    fun `un deep link nuevo sustituye la confirmación anterior`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.onDeepLink(transfer(host = "a.example.com").urlString())
        advanceUntilIdle()
        vm.onDeepLink(transfer(host = "b.example.com").urlString())
        advanceUntilIdle()
        assertEquals("b.example.com", vm.state.value.preview?.host)
    }

    @Test
    fun `el mismo QR leído muchas veces solo se procesa una`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.onScanned("https://example.com")
        advanceUntilIdle()
        assertEquals(UiText.res(R.string.import_error_not_argos), vm.state.value.inputError)
        vm.onLinkTextChange("x") // limpia el error
        vm.onScanned("https://example.com")
        advanceUntilIdle()
        assertNull(vm.state.value.inputError)
    }

    @Test
    fun `con una confirmación abierta se ignoran más lecturas de la cámara`() = runTest(main.dispatcher) {
        val vm = viewModel()
        vm.onScanned(transfer(host = "a.example.com").urlString())
        advanceUntilIdle()
        vm.onScanned(transfer(host = "b.example.com").urlString())
        advanceUntilIdle()
        assertEquals("a.example.com", vm.state.value.preview?.host)
    }

    @Test
    fun `escanear otro descarta la confirmación y permite releer el mismo código`() = runTest(main.dispatcher) {
        val vm = viewModel()
        val link = transfer().urlString()
        vm.onScanned(link)
        advanceUntilIdle()
        vm.scanAgain()
        assertNull(vm.state.value.preview)
        vm.confirmImport()
        advanceUntilIdle()
        assertTrue(repository.servers.value.isEmpty())

        vm.onScanned(link)
        advanceUntilIdle()
        assertNotNull(vm.state.value.preview)
    }

    @Test
    fun `el estado no muestra el enlace pegado en toString`() = runTest(main.dispatcher) {
        val vm = viewModel()
        val link = transfer().urlString()
        vm.onLinkTextChange(link)
        assertFalse(link in vm.state.value.toString())
        assertFalse(link.substringAfter("d=") in vm.state.value.toString())
    }
}
