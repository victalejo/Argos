package com.iaportafolio.argos

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.core.content.IntentCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iaportafolio.argos.ui.share.ShareIntent
import com.iaportafolio.argos.background.AgentChatLink
import com.iaportafolio.argos.background.AgentChatTarget
import com.iaportafolio.argos.background.ClaudeLink
import com.iaportafolio.argos.background.ClaudeTarget
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

    /** Ventana con Claude que pidió abrir un aviso, hasta que la navegación la atiende. */
    private val claudeTarget = MutableStateFlow<ClaudeTarget?>(null)

    /** `content://` compartidos con Argos desde otra app, hasta que la navegación abre el selector de destino. */
    private val sharedUris = MutableStateFlow<List<String>?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // App de una sola Activity: su ciclo de vida es el «primer plano» de la app.
        lifecycle.addObserver(
            object : DefaultLifecycleObserver {
                override fun onStart(owner: LifecycleOwner) = container.visibility.onAppStarted()

                override fun onStop(owner: LifecycleOwner) = container.visibility.onAppStopped()
            },
        )
        // Al recrearse o volver desde recientes llega el mismo Intent: el aviso ya se atendió.
        if (savedInstanceState == null) handle(intent)
        setContent {
            val target by chatTarget.collectAsStateWithLifecycle()
            val link by importLink.collectAsStateWithLifecycle()
            val claude by claudeTarget.collectAsStateWithLifecycle()
            val shared by sharedUris.collectAsStateWithLifecycle()
            ArgosTheme {
                ArgosNavHost(
                    container,
                    target,
                    onChatTargetConsumed = { chatTarget.value = null },
                    importLink = link,
                    onImportLinkConsumed = { importLink.value = null },
                    claudeTarget = claude,
                    onClaudeTargetConsumed = { claudeTarget.value = null },
                    sharedUris = shared,
                    onSharedUrisConsumed = { sharedUris.value = null },
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
        openClaudeFrom(intent)
        openShareFrom(intent)
        openImportFrom(intent)
    }

    private fun openShareFrom(intent: Intent) {
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        if (!ShareIntent.isShare(intent.action)) return
        val uris = try {
            val streams = if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
                IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
            } else {
                listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
            }
            ShareIntent.accepted(intent.action, streams.map { it.toString() })
        } catch (error: RuntimeException) {
            ArgosLog.warn(ArgosLog.TAG_UI, "Intent de «Compartir» ilegible (${error::class.java.simpleName})")
            emptyList()
        }
        if (uris.isNotEmpty()) sharedUris.value = uris else ArgosLog.warn(ArgosLog.TAG_UI, "«Compartir» sin archivos que subir")
    }

    private fun openClaudeFrom(intent: Intent) {
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        if (intent.action != ClaudeLink.ACTION_OPEN_WINDOW) return
        // Otra app puede lanzarnos con un Bundle malformado: leerlo puede lanzar, y se ignora.
        val target = try {
            ClaudeLink.parse(
                intent.action,
                intent.getStringExtra(ClaudeLink.EXTRA_SERVER_ID),
                intent.getStringExtra(ClaudeLink.EXTRA_SESSION),
                intent.getIntExtra(ClaudeLink.EXTRA_WINDOW, -1),
                container.servers,
            )
        } catch (error: RuntimeException) {
            ArgosLog.warn(ArgosLog.TAG_UI, "Intent de aviso de Claude ilegible (${error::class.java.simpleName})")
            null
        }
        if (target != null) claudeTarget.value = target
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

    /** Solo cadenas y enteros: lo demás que traiga un `Intent` ajeno se ignora. */
    private fun readExtra(extras: Bundle, key: String): Any? =
        extras.getString(key) ?: extras.getInt(key, Int.MIN_VALUE).takeIf { it != Int.MIN_VALUE }

    private fun openChatFrom(intent: Intent) {
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        if (intent.action != AgentChatLink.ACTION_OPEN_CHAT) return
        // Otra app puede lanzarnos con un Bundle malformado: leerlo puede lanzar, y se ignora.
        val target = try {
            val extras = intent.extras
            AgentChatLink.parse(intent.action, { key -> extras?.let { readExtra(it, key) } }, container.servers)
        } catch (error: RuntimeException) {
            ArgosLog.warn(ArgosLog.TAG_UI, "Intent de aviso ilegible (${error::class.java.simpleName})")
            null
        }
        if (target != null) chatTarget.value = target
    }
}
