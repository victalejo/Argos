@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.iaportafolio.argos.ui

import com.iaportafolio.argos.core.projects.Project
import com.iaportafolio.argos.data.AttachmentSource
import com.iaportafolio.argos.data.PickedAttachment
import com.iaportafolio.argos.testing.FakeServiceProvider
import com.iaportafolio.argos.testing.InMemoryServerRepository
import com.iaportafolio.argos.testing.MainDispatcherExtension
import com.iaportafolio.argos.testing.server
import com.iaportafolio.argos.testing.session
import com.iaportafolio.argos.ui.share.ShareDestination
import com.iaportafolio.argos.ui.share.ShareEvent
import com.iaportafolio.argos.ui.share.ShareIntent
import com.iaportafolio.argos.ui.share.ShareLoad
import com.iaportafolio.argos.ui.share.ShareTargetViewModel
import com.iaportafolio.argos.ui.terminal.PendingShares
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.extension.RegisterExtension
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

class ShareTargetTest {

    @JvmField
    @RegisterExtension
    val main = MainDispatcherExtension()

    private val web = Project(id = "6F1C2A3B-0000-4000-8000-000000000001", name = "web", group = "ia", path = "/srv/web")
    private val api = Project(id = "6F1C2A3B-0000-4000-8000-000000000002", name = "api", path = "/srv/api")

    private object NamedSource : AttachmentSource {
        override fun describe(uri: String) = PickedAttachment(uri, uri.substringAfterLast('/'), "image/png", 10)
        override suspend fun read(uri: String, maxBytes: Int) = ByteArray(0)
    }

    @Test
    fun `solo se aceptan content y como mucho diez`() {
        assertEquals(listOf("content://a/1"), ShareIntent.accepted(ShareIntent.ACTION_SEND, listOf("content://a/1", null, "file:///data/data/x", "content://")))
        assertTrue(ShareIntent.accepted("android.intent.action.VIEW", listOf("content://a/1")).isEmpty())
        assertEquals(10, ShareIntent.accepted(ShareIntent.ACTION_SEND_MULTIPLE, (1..20).map { "CONTENT://a/$it" }).size)
    }

    @Test
    fun `en marcha primero, luego sesiones sueltas y despues los detenidos`() {
        val destinations = ShareTargetViewModel.destinations(listOf(api, web), listOf(session("ia/web"), session("suelta")))
        assertEquals(listOf("ia/web", "suelta", "api"), destinations.map { it.sessionName })
    }

    @Test
    fun `elegir proyecto deja lo compartido para su terminal y navega`() = runTest(main.dispatcher) {
        val provider = FakeServiceProvider().apply {
            service.projects = listOf(web)
            service.sessions = listOf(session("ia/web"))
        }
        val pending = PendingShares()
        val viewModel = ShareTargetViewModel(InMemoryServerRepository(listOf(server())), provider, NamedSource, pending, main.dispatcher)
        viewModel.setShared(listOf("content://fotos/captura.png", "content://fotos/captura.png"))
        advanceUntilIdle()
        viewModel.selectServer(server())
        advanceUntilIdle()
        val loaded = assertIs<ShareLoad.Loaded>(viewModel.state.value.load)
        viewModel.choose(loaded.destinations.single() as ShareDestination.ProjectTarget)

        assertEquals(ShareEvent.OpenProject("S1", web.id), viewModel.events.first())
        assertEquals(listOf("captura.png"), pending.take("S1", "ia/web").map { it.displayName })
        assertTrue(pending.take("S1", "ia/web").isEmpty())
    }
}
