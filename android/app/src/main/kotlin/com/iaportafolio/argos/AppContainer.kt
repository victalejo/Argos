package com.iaportafolio.argos

import android.content.Context
import com.iaportafolio.argos.background.ActiveTerminalRegistry
import com.iaportafolio.argos.background.AppVisibilityCoordinator
import com.iaportafolio.argos.background.BackgroundCheckSchedule
import com.iaportafolio.argos.background.BackgroundDiagnosticsStore
import com.iaportafolio.argos.background.BackgroundServiceProvider
import com.iaportafolio.argos.background.CIWatchStore
import com.iaportafolio.argos.background.CheckTrigger
import com.iaportafolio.argos.background.LocalNetworkPermission
import com.iaportafolio.argos.background.PortForwardTracker
import com.iaportafolio.argos.background.SharedConnections
import com.iaportafolio.argos.background.SystemNetworkMonitor
import com.iaportafolio.argos.background.AgentNotifier
import com.iaportafolio.argos.background.AgentWatchStore
import com.iaportafolio.argos.background.CIWatchService
import com.iaportafolio.argos.background.ClaudeActivityMonitor
import com.iaportafolio.argos.background.ClaudeBackgroundCheck
import com.iaportafolio.argos.background.ClaudeWatchStore
import com.iaportafolio.argos.background.SystemClaudeAlerts
import com.iaportafolio.argos.background.SharedPreferencesAgentWatch
import com.iaportafolio.argos.background.SystemAgentAlerts
import com.iaportafolio.argos.background.SystemCIAlerts
import com.iaportafolio.argos.background.TerminalKeepAliveService
import com.iaportafolio.argos.background.VisibilityTimings
import com.iaportafolio.argos.background.WorkManagerAgentCheckScheduler
import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.SSHConnector
import com.iaportafolio.argos.data.AgentPermissionStore
import com.iaportafolio.argos.data.AttachmentSource
import com.iaportafolio.argos.data.ClaudeTokenStore
import com.iaportafolio.argos.data.ContentResolverAttachmentSource
import com.iaportafolio.argos.ui.terminal.PendingShares
import com.iaportafolio.argos.data.ContentResolverDocumentReader
import com.iaportafolio.argos.data.ContentResolverDocumentWriter
import com.iaportafolio.argos.data.DocumentReader
import com.iaportafolio.argos.data.DocumentWriter
import com.iaportafolio.argos.data.EncryptedSecretStore
import com.iaportafolio.argos.data.FileHostKeyTrustStore
import com.iaportafolio.argos.data.FileServerRepository
import com.iaportafolio.argos.data.KeystoreSecretCipher
import com.iaportafolio.argos.data.LocalNetworkGate
import com.iaportafolio.argos.data.PortForwardSettingsStore
import com.iaportafolio.argos.data.ProjectPreferencesStore
import com.iaportafolio.argos.data.SecretStore
import com.iaportafolio.argos.data.SecretStoreClaudeTokens
import com.iaportafolio.argos.data.ServerImporter
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceHub
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.data.SharedPreferencesAgentPermissions
import com.iaportafolio.argos.data.SharedPreferencesPortForwardSettings
import com.iaportafolio.argos.data.SharedPreferencesProjectPreferences
import com.iaportafolio.argos.data.SharedPreferencesTerminalSettings
import com.iaportafolio.argos.data.TerminalSettingsStore
import java.io.File
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * Inyección de dependencias manual (por constructor): un único grafo por proceso, creado en
 * [ArgosApplication]. Todo es perezoso para no tocar disco ni Keystore en el arranque.
 */
class AppContainer(
    context: Context,
    private val connector: SSHConnector,
    val io: CoroutineDispatcher = Dispatchers.IO,
) {
    private val appContext = context.applicationContext
    private val filesDir: File = appContext.filesDir

    val servers: ServerRepository by lazy { FileServerRepository(File(filesDir, SERVERS_FILE), io) }

    val secrets: SecretStore by lazy { EncryptedSecretStore(File(filesDir, SECRETS_DIR), KeystoreSecretCipher()) }

    val claudeTokens: ClaudeTokenStore by lazy { SecretStoreClaudeTokens(secrets) }

    val agentPermissions: AgentPermissionStore by lazy { AgentPermissionStore(SharedPreferencesAgentPermissions(appContext)) }

    val hostKeys: HostKeyTrustStore by lazy { FileHostKeyTrustStore(File(filesDir, KNOWN_HOSTS_FILE)) }

    val serverImporter: ServerImporter by lazy { ServerImporter(servers, secrets, hostKeys) }

    /** Permiso de red local de Android 17: se consulta en cada conexión nueva. */
    val localNetwork: LocalNetworkGate by lazy { LocalNetworkPermission.gate(appContext) }

    private val hub: ServiceHub by lazy {
        ServiceHub(connector, secrets, hostKeys, io, localNetwork) { serverId -> portForwards.serverDisconnected(serverId) }
    }

    val services: ServiceProvider get() = hub

    val documents: DocumentReader by lazy { ContentResolverDocumentReader(appContext.contentResolver) }

    val terminalSettings: TerminalSettingsStore by lazy { SharedPreferencesTerminalSettings(appContext) }

    /** Fotos y archivos adjuntados al terminal (selector, portapapeles o «Compartir»). */
    val attachments: AttachmentSource by lazy { ContentResolverAttachmentSource(appContext.contentResolver) }

    /** Lo compartido desde otra app, a la espera del terminal de su sesión. */
    val pendingShares: PendingShares by lazy { PendingShares() }

    val documentWriter: DocumentWriter by lazy { ContentResolverDocumentWriter(appContext.contentResolver) }

    val projectPreferences: ProjectPreferencesStore by lazy { SharedPreferencesProjectPreferences(appContext) }

    /** Límite del cierre automático de túneles e identidad del teléfono para la skill de Claude. */
    val portForwardSettings: PortForwardSettingsStore by lazy { SharedPreferencesPortForwardSettings(appContext) }

    /** Estado local de avisos (agentes, diagnóstico, CI vigilado): un solo `SharedPreferences`. */
    private val watchBackend by lazy { SharedPreferencesAgentWatch(appContext) }

    /** Última comprobación en segundo plano (pantalla de diagnóstico). */
    val diagnostics: BackgroundDiagnosticsStore by lazy { BackgroundDiagnosticsStore(watchBackend) }

    /** Un único trabajo de WorkManager para agentes y CI. */
    val backgroundSchedule: BackgroundCheckSchedule by lazy {
        BackgroundCheckSchedule(
            WorkManagerAgentCheckScheduler(appContext),
            listOf({ agentNotifier.hasWatchedServers() }, { ciWatches.isWatching }),
        )
    }

    val agentNotifier: AgentNotifier by lazy {
        AgentNotifier(
            servers = servers,
            secrets = secrets,
            hostKeys = hostKeys,
            connector = connector,
            tokens = claudeTokens,
            store = AgentWatchStore(watchBackend),
            alerts = SystemAgentAlerts(appContext),
            scheduler = backgroundSchedule.asScheduler,
            io = io,
            live = { server -> hub.cached(server) },
            localNetwork = localNetwork,
            diagnostics = diagnostics,
            claude = ClaudeBackgroundCheck(claudeWatch, claudeAlerts, isAppVisible = { visibility.visible.value }),
        )
    }

    /** Claude Code en las ventanas tmux: servidores donde se vio y su última lectura. */
    val claudeWatch: ClaudeWatchStore by lazy { ClaudeWatchStore(watchBackend) }

    private val claudeAlerts by lazy { SystemClaudeAlerts(appContext) }

    /** Insignias y avisos de Claude con la app a la vista (solo conexiones ya abiertas). */
    val claudeActivity: ClaudeActivityMonitor by lazy {
        ClaudeActivityMonitor(
            servers = servers,
            live = { server -> hub.cached(server) },
            store = claudeWatch,
            alerts = claudeAlerts,
            notificationsEnabled = { agentNotifier.notificationsEnabled.value },
            io = io,
            onServerWatched = { backgroundSchedule.sync() },
        )
    }

    /** Ámbito de la aplicación (vive lo que el proceso) para CI, túneles y primer plano. */
    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    val ciWatches: CIWatchService by lazy {
        CIWatchService(
            servers,
            services,
            SystemCIAlerts(appContext),
            appScope,
            io,
            store = CIWatchStore(watchBackend),
            isVisible = { visibility.visible.value },
            onWatchesChanged = { backgroundSchedule.sync() },
        )
    }

    val activeTerminals: ActiveTerminalRegistry by lazy {
        ActiveTerminalRegistry(TerminalKeepAliveService.host(appContext)) {
            terminalSettings.settings.value.keepAliveInBackground
        }
    }

    /** Túneles abiertos, para el servicio en primer plano. */
    val portForwards: PortForwardTracker by lazy { PortForwardTracker(activeTerminals, servers, hub, io) }

    /** Entrar y salir de primer plano (lo marca [MainActivity]). */
    val visibility: AppVisibilityCoordinator by lazy {
        AppVisibilityCoordinator(
            scope = appScope,
            connections = object : SharedConnections {
                override suspend fun probeAll(timeoutMillis: Long) = hub.probeAll(timeoutMillis)
                override suspend fun closeAll() = hub.closeAll()
            },
            checkAgents = { full -> agentNotifier.check(CheckTrigger.FOREGROUND, liveOnly = !full) },
            onVisible = { ciWatches.resume() },
            isKeepingAlive = { activeTerminals.isServiceRunning || activeTerminals.tunnelCount.value > 0 },
        )
    }

    /** Conexiones para una pasada del worker (cerrarlas con `closeAll`). */
    fun backgroundServices() = BackgroundServiceProvider(hub, connector, secrets, hostKeys, localNetwork, io)

    /** «Cerrar todo» o la app cerrada desde recientes: en el ámbito de la app, no del servicio. */
    fun closeAllPortForwards() {
        appScope.launch { portForwards.closeAll() }
    }

    /** Al arrancar el proceso: primer plano y cambios de red. */
    fun startMonitors() {
        visibility.start()
        appScope.launch { visibility.visible.collectLatest { visible -> if (visible) claudeActivity.runWhileVisible() } }
        // Red nueva: se sondean las conexiones (las que siguen vivas, p. ej. con VPN, conservan
        // terminales y túneles); las muertas se sueltan y los terminales reenganchan solos.
        SystemNetworkMonitor(appContext) { appScope.launch { hub.probeAll(VisibilityTimings().probeTimeoutMillis) } }.start()
    }

    private companion object {
        const val SERVERS_FILE = "servers.json"
        const val KNOWN_HOSTS_FILE = "known_hosts.json"
        const val SECRETS_DIR = "secrets"
    }
}
