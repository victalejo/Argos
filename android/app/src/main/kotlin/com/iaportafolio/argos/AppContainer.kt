package com.iaportafolio.argos

import android.content.Context
import com.iaportafolio.argos.background.ActiveTerminalRegistry
import com.iaportafolio.argos.background.AgentNotifier
import com.iaportafolio.argos.background.AgentWatchStore
import com.iaportafolio.argos.background.SharedPreferencesAgentWatch
import com.iaportafolio.argos.background.SystemAgentAlerts
import com.iaportafolio.argos.background.TerminalKeepAliveService
import com.iaportafolio.argos.background.WorkManagerAgentCheckScheduler
import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.SSHConnector
import com.iaportafolio.argos.data.AgentPermissionStore
import com.iaportafolio.argos.data.ClaudeTokenStore
import com.iaportafolio.argos.data.ContentResolverDocumentReader
import com.iaportafolio.argos.data.ContentResolverDocumentWriter
import com.iaportafolio.argos.data.DocumentReader
import com.iaportafolio.argos.data.DocumentWriter
import com.iaportafolio.argos.data.EncryptedSecretStore
import com.iaportafolio.argos.data.FileHostKeyTrustStore
import com.iaportafolio.argos.data.FileServerRepository
import com.iaportafolio.argos.data.KeystoreSecretCipher
import com.iaportafolio.argos.data.ProjectPreferencesStore
import com.iaportafolio.argos.data.SecretStore
import com.iaportafolio.argos.data.SecretStoreClaudeTokens
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceHub
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.data.SharedPreferencesAgentPermissions
import com.iaportafolio.argos.data.SharedPreferencesProjectPreferences
import com.iaportafolio.argos.data.SharedPreferencesTerminalSettings
import com.iaportafolio.argos.data.TerminalSettingsStore
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import java.io.File

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

    val services: ServiceProvider by lazy { ServiceHub(connector, secrets, hostKeys, io) }

    val documents: DocumentReader by lazy { ContentResolverDocumentReader(appContext.contentResolver) }

    val terminalSettings: TerminalSettingsStore by lazy { SharedPreferencesTerminalSettings(appContext) }

    val documentWriter: DocumentWriter by lazy { ContentResolverDocumentWriter(appContext.contentResolver) }

    val projectPreferences: ProjectPreferencesStore by lazy { SharedPreferencesProjectPreferences(appContext) }

    val agentNotifier: AgentNotifier by lazy {
        AgentNotifier(
            servers = servers,
            secrets = secrets,
            hostKeys = hostKeys,
            connector = connector,
            tokens = claudeTokens,
            store = AgentWatchStore(SharedPreferencesAgentWatch(appContext)),
            alerts = SystemAgentAlerts(appContext),
            scheduler = WorkManagerAgentCheckScheduler(appContext),
            io = io,
        )
    }

    val activeTerminals: ActiveTerminalRegistry by lazy {
        ActiveTerminalRegistry(TerminalKeepAliveService.host(appContext)) {
            terminalSettings.settings.value.keepAliveInBackground
        }
    }

    private companion object {
        const val SERVERS_FILE = "servers.json"
        const val KNOWN_HOSTS_FILE = "known_hosts.json"
        const val SECRETS_DIR = "secrets"
    }
}
