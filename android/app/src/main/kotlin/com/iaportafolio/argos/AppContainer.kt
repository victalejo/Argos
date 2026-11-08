package com.iaportafolio.argos

import android.content.Context
import com.iaportafolio.argos.core.HostKeyTrustStore
import com.iaportafolio.argos.core.SSHConnector
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
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceHub
import com.iaportafolio.argos.data.ServiceProvider
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
    connector: SSHConnector,
    val io: CoroutineDispatcher = Dispatchers.IO,
) {
    private val appContext = context.applicationContext
    private val filesDir: File = appContext.filesDir

    val servers: ServerRepository by lazy { FileServerRepository(File(filesDir, SERVERS_FILE), io) }

    val secrets: SecretStore by lazy { EncryptedSecretStore(File(filesDir, SECRETS_DIR), KeystoreSecretCipher()) }

    val hostKeys: HostKeyTrustStore by lazy { FileHostKeyTrustStore(File(filesDir, KNOWN_HOSTS_FILE)) }

    val services: ServiceProvider by lazy { ServiceHub(connector, secrets, hostKeys, io) }

    val documents: DocumentReader by lazy { ContentResolverDocumentReader(appContext.contentResolver) }

    val terminalSettings: TerminalSettingsStore by lazy { SharedPreferencesTerminalSettings(appContext) }

    val documentWriter: DocumentWriter by lazy { ContentResolverDocumentWriter(appContext.contentResolver) }

    val projectPreferences: ProjectPreferencesStore by lazy { SharedPreferencesProjectPreferences(appContext) }

    private companion object {
        const val SERVERS_FILE = "servers.json"
        const val KNOWN_HOSTS_FILE = "known_hosts.json"
        const val SECRETS_DIR = "secrets"
    }
}
