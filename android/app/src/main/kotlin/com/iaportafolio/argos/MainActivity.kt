package com.iaportafolio.argos

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iaportafolio.argos.background.AgentChatLink
import com.iaportafolio.argos.background.AgentChatTarget
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.ui.importer.ImportLink
import com.iaportafolio.argos.ui.navigation.ArgosNavHost
import com.iaportafolio.argos.ui.theme.ArgosTheme
import kotlinx.coroutines.flow.MutableStateFlow

class MainActivity : ComponentActivity() {

    private val container: AppContainer get() = (application as ArgosApplication).container

    /** Chat que pidió abrir un aviso, hasta que la navegación lo atiende. */
    private val chatTarget = MutableStateFlow<AgentChatTarget?>(null)

    /** Enlace `argos://add-server` de un deep link, hasta que la navegación abre la confirmación. */
    private val importLink = MutableStateFlow<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Al recrearse o volver desde recientes llega el mismo Intent: el aviso ya se atendió.
        if (savedInstanceState == null) handle(intent)
        setContent {
            val target by chatTarget.collectAsStateWithLifecycle()
            val link by importLink.collectAsStateWithLifecycle()
            ArgosTheme {
                ArgosNavHost(
                    container,
                    target,
                    onChatTargetConsumed = { chatTarget.value = null },
                    importLink = link,
                    onImportLinkConsumed = { importLink.value = null },
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent) {
        openChatFrom(intent)
        openImportFrom(intent)
    }

    /** Deep link del QR del Mac: solo abre la confirmación (nunca importa por su cuenta). */
    private fun openImportFrom(intent: Intent) {
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        // Otra app puede mandarnos cualquier cosa: se filtra antes de decodificar.
        val link = try {
            ImportLink.fromIntent(intent.action, intent.dataString)
        } catch (error: RuntimeException) {
            ArgosLog.warn(ArgosLog.TAG_UI, "Intent de importación ilegible (${error::class.java.simpleName})")
            null
        }
        if (link != null) {
            importLink.value = link
        } else if (intent.action == Intent.ACTION_VIEW) {
            ArgosLog.warn(ArgosLog.TAG_UI, "Enlace de importación rechazado antes de decodificarlo")
        }
    }

    private fun openChatFrom(intent: Intent) {
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        if (intent.action != AgentChatLink.ACTION_OPEN_CHAT) return
        // Otra app puede lanzarnos con un Bundle malformado: leerlo puede lanzar, y se ignora.
        val target = try {
            AgentChatLink.parse(
                intent.action,
                intent.getStringExtra(AgentChatLink.EXTRA_SERVER_ID),
                intent.getStringExtra(AgentChatLink.EXTRA_AGENT_ID),
                container.servers,
            )
        } catch (error: RuntimeException) {
            ArgosLog.warn(ArgosLog.TAG_UI, "Intent de aviso ilegible (${error::class.java.simpleName})")
            null
        }
        if (target != null) chatTarget.value = target
    }
}
