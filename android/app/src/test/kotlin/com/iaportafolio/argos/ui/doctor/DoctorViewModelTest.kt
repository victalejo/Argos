package com.iaportafolio.argos.ui.doctor

import com.iaportafolio.argos.core.doctor.DiagnosticAppInfo
import com.iaportafolio.argos.core.doctor.DoctorCheckID
import com.iaportafolio.argos.core.doctor.DoctorFix
import com.iaportafolio.argos.core.doctor.DoctorScript
import com.iaportafolio.argos.core.ports.PortForwardServerFiles
import com.iaportafolio.argos.testing.FakeSSHService
import com.iaportafolio.argos.testing.FakeServiceProvider
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.server
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import java.time.Instant
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** Paridad con los tests de `DoctorModel` de `ArgosTests/DoctorScriptTests.swift`. */
@OptIn(ExperimentalCoroutinesApi::class)
class DoctorViewModelTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    /** Responde al script del Doctor con [output]; registra todo lo demás. */
    private class DoctorService(var output: String) : FakeSSHService() {
        val scripts = mutableListOf<String>()

        override suspend fun runAgentScript(command: String): String {
            scripts += command
            return if (command == DoctorScript.command) output else ""
        }
    }

    private val healthy = listOf(
        "os=Linux", "clock=1800000000", "tmux.present=yes", "tmux.version=tmux 3.3a", "git.present=yes",
        "git.version=git version 2.43.0", "hooks.settings=ok", "hooks.marker=9", "skill.ports=current", "done=1", "",
    ).joinToString("\n")

    private val app = DiagnosticAppInfo("1.2.0", "12", "Google Play", "Android 16 (API 36)", "Google Pixel 9")

    private fun viewModel(service: DoctorService) = DoctorViewModel(
        "S1",
        InMemoryServerRepository(listOf(server(name = "Producción", host = "prod.miempresa.com"))),
        FakeServiceProvider(service),
        main.dispatcher,
        app,
        now = { Instant.ofEpochSecond(1_800_000_000) },
    )

    @Test
    fun `una salida cortada es una pantalla de error, no un resultado falso`() = runTest(main.dispatcher) {
        val vm = viewModel(DoctorService("Last login: hoy\nos=Linux\n"))
        advanceUntilIdle()
        val load = assertIs<DoctorLoad.Failed>(vm.state.value.load)
        assertContains(load.message, "comprobación completa")
    }

    @Test
    fun `evalua, consulta los hooks y aplica un arreglo de un toque`() = runTest(main.dispatcher) {
        val service = DoctorService(healthy)
        val vm = viewModel(service)
        advanceUntilIdle()
        // El doble dice que los hooks NO están al día.
        val hooks = vm.state.value.result?.checks?.first { it.id == DoctorCheckID.CLAUDE_HOOKS }
        assertEquals(DoctorFix.InstallClaudeHooks(isUpdate = true), hooks?.fix)

        service.output = healthy.replace("skill.ports=current", "skill.ports=missing")
        vm.run()
        advanceUntilIdle()
        val skill = vm.state.value.result?.checks?.first { it.id == DoctorCheckID.PORTS_SKILL }
        assertEquals(DoctorFix.InstallPortsSkill(isUpdate = false), skill?.fix)

        vm.apply(DoctorFix.InstallPortsSkill(isUpdate = false), DoctorCheckID.PORTS_SKILL)
        advanceUntilIdle()
        assertTrue(PortForwardServerFiles.installCommand in service.scripts)
        assertEquals(null, vm.state.value.fixError)

        vm.apply(DoctorFix.InstallClaudeHooks(isUpdate = true), DoctorCheckID.CLAUDE_HOOKS)
        advanceUntilIdle()
        assertTrue("installHooks" in service.calls)
    }

    @Test
    fun `copiar diagnostico oculta servidores y explica que no hay registro`() = runTest(main.dispatcher) {
        val vm = viewModel(DoctorService(healthy))
        advanceUntilIdle()
        val report = vm.report()
        assertContains(report, "Versión: 1.2.0 (build 12)")
        assertContains(report, "Dispositivo: Google Pixel 9")
        assertContains(report, "Doctor del servidor: servidor-1")
        assertContains(report, "no guarda un registro propio")
        assertContains(report, "Revisa este texto antes de publicarlo")
        assertFalse(report.contains("Producción") || report.contains("prod.miempresa.com"))

        vm.setIncludePersonalData(true)
        assertContains(vm.report(), "Doctor del servidor: Producción")
    }
}
