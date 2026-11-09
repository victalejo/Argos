package com.iaportafolio.argos.ui.form

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.AuthMethod
import com.iaportafolio.argos.core.Server
import com.iaportafolio.argos.core.keys.ImportedKeyValidation
import com.iaportafolio.argos.data.ArgosLog
import com.iaportafolio.argos.data.DocumentReader
import com.iaportafolio.argos.data.SecretKind
import com.iaportafolio.argos.data.SecretStore
import com.iaportafolio.argos.data.ServerRepository
import com.iaportafolio.argos.data.ServiceProvider
import com.iaportafolio.argos.ui.common.UiText
import com.iaportafolio.argos.ui.common.logFailures
import com.iaportafolio.argos.ui.common.toUiText
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Situación de la clave privada en el formulario. */
enum class KeyState {
    /** No hay clave (ni guardada ni importada). */
    MISSING,

    /** Hay una clave guardada cifrada de antes (editar sin cambiarla). */
    STORED,

    /** Se acaba de importar una clave válida; se guardará al pulsar «Guardar». */
    IMPORTED,
}

/** Estado inmutable del formulario. Los secretos tecleados se ocultan en [toString]. */
data class ServerFormState(
    val isNew: Boolean = true,
    /** Editando un servidor que ya no existe (borrado desde otra pantalla). */
    val notFound: Boolean = false,
    val name: String = "",
    val host: String = "",
    val port: String = Server.DEFAULT_PORT.toString(),
    val username: String = "",
    val authMethod: AuthMethod = AuthMethod.PASSWORD,
    val password: String = "",
    val hasStoredPassword: Boolean = false,
    val keyState: KeyState = KeyState.MISSING,
    val requiresPassphrase: Boolean = false,
    val passphrase: String = "",
    val hasStoredPassphrase: Boolean = false,
    /** Errores de campo; solo se muestran tras el primer intento de guardar. */
    val errors: Map<FormField, FieldError> = emptyMap(),
    val showErrors: Boolean = false,
    val isImportingKey: Boolean = false,
    val isSaving: Boolean = false,
    /** Guardado con éxito: la UI cierra el formulario. */
    val saved: Boolean = false,
    val message: UiText? = null,
) {
    val visibleErrors: Map<FormField, FieldError> get() = if (showErrors) errors else emptyMap()

    override fun toString(): String =
        "ServerFormState(isNew=$isNew, name=$name, host=$host, port=$port, username=$username, " +
            "authMethod=$authMethod, keyState=$keyState, requiresPassphrase=$requiresPassphrase, " +
            "errors=$errors, isSaving=$isSaving, saved=$saved, secrets=***)"
}

/**
 * Alta/edición de un servidor (equivale a `ServerFormView` de Apple). Los secretos van al
 * [SecretStore] (cifrados con el Keystore), nunca al `servers.json`.
 */
class ServerFormViewModel(
    private val serverId: String?,
    private val repository: ServerRepository,
    private val secrets: SecretStore,
    private val services: ServiceProvider,
    private val documents: DocumentReader,
    private val io: CoroutineDispatcher,
) : ViewModel(), ServerFormActions {

    private val original: Server? = serverId?.let(repository::server)
    private val targetId: String = original?.id ?: serverId ?: Server.newId()

    /** Clave recién importada y validada (fuera del estado para que no viaje en logs/toString). */
    private var importedKey: String? = null

    private val mutableState = MutableStateFlow(initialState())
    val state: StateFlow<ServerFormState> = mutableState.asStateFlow()

    init {
        original?.let { server -> viewModelScope.launch { loadStoredSecrets(server) } }
    }

    private fun initialState(): ServerFormState {
        val server = original ?: return ServerFormState(isNew = serverId == null, notFound = serverId != null).revalidated()
        return ServerFormState(
            isNew = false,
            name = server.name,
            host = server.host,
            port = server.port.toString(),
            username = server.username,
            authMethod = server.authMethod,
            requiresPassphrase = server.requiresPassphrase,
        ).revalidated()
    }

    private suspend fun loadStoredSecrets(server: Server) {
        logFailures(ArgosLog.TAG_SECRETS, "No se pudo consultar los secretos de ${server.id}") {
            withContext(io) {
                Triple(
                    secrets.contains(server.id, SecretKind.PASSWORD),
                    secrets.contains(server.id, SecretKind.PRIVATE_KEY),
                    secrets.contains(server.id, SecretKind.PASSPHRASE),
                )
            }
        }.onSuccess { (password, key, passphrase) ->
            mutableState.update { state ->
                state.copy(
                    hasStoredPassword = server.authMethod == AuthMethod.PASSWORD && password,
                    keyState = if (state.keyState == KeyState.IMPORTED) state.keyState else if (key) KeyState.STORED else KeyState.MISSING,
                    hasStoredPassphrase = server.authMethod == AuthMethod.KEY && server.requiresPassphrase && passphrase,
                ).revalidated()
            }
        }.onFailure { error -> mutableState.update { it.copy(message = error.toUiText()) } }
    }

    // MARK: - Edición de campos

    override fun onNameChange(value: String) = edit { copy(name = value) }

    override fun onHostChange(value: String) = edit { copy(host = value) }

    override fun onPortChange(value: String) = edit { copy(port = value.filter(Char::isDigit).take(PORT_MAX_DIGITS)) }

    override fun onUsernameChange(value: String) = edit { copy(username = value) }

    override fun onAuthMethodChange(value: AuthMethod) = edit { copy(authMethod = value) }

    override fun onPasswordChange(value: String) = edit { copy(password = value) }

    override fun onRequiresPassphraseChange(value: Boolean) = edit { copy(requiresPassphrase = value) }

    override fun onPassphraseChange(value: String) = edit { copy(passphrase = value) }

    override fun messageShown() = mutableState.update { it.copy(message = null) }

    private inline fun edit(crossinline change: ServerFormState.() -> ServerFormState) =
        mutableState.update { it.change().revalidated() }

    // MARK: - Importar clave

    /** Resultado del selector de documentos (`null` = cancelado). */
    override fun onKeyFilePicked(uri: String?) {
        if (uri == null) return
        importKey { ImportedKeyValidation.validate(documents.read(uri, ImportedKeyValidation.MAX_BYTES)) }
    }

    /** Clave pegada como texto (la UI no la guarda en su estado restaurable). */
    override fun onKeyPasted(text: String) {
        if (text.isBlank()) return
        importKey { ImportedKeyValidation.validatePasted(text) }
    }

    private fun importKey(load: suspend () -> String) {
        if (state.value.isImportingKey) return
        mutableState.update { it.copy(isImportingKey = true) }
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_SECRETS, "Clave importada rechazada") {
                withContext(io) { load() }
            }.onSuccess { key ->
                importedKey = key
                mutableState.update { state ->
                    state.copy(
                        isImportingKey = false,
                        keyState = KeyState.IMPORTED,
                        // Una clave nueva tiene su propia passphrase: no vale la guardada.
                        hasStoredPassphrase = false,
                        message = UiText.res(R.string.form_key_imported),
                    ).revalidated()
                }
            }.onFailure { error ->
                mutableState.update { it.copy(isImportingKey = false, message = error.toUiText()) }
            }
        }
    }

    // MARK: - Guardar

    override fun save() {
        val current = state.value.revalidated()
        if (current.isSaving || current.notFound) return
        if (current.errors.isNotEmpty()) {
            mutableState.value = current.copy(showErrors = true)
            return
        }
        mutableState.value = current.copy(isSaving = true, showErrors = true)
        val server = buildServer(current)
        viewModelScope.launch {
            logFailures(ArgosLog.TAG_STORE, "No se pudo guardar el servidor ${server.id}") {
                withContext(io) { persist(server, current) }
                services.invalidate(server.id)
            }.onSuccess {
                ArgosLog.info(ArgosLog.TAG_STORE, "Servidor ${server.id} guardado")
                importedKey = null
                mutableState.update { it.copy(isSaving = false, saved = true) }
            }.onFailure { error ->
                mutableState.update { it.copy(isSaving = false, message = error.toUiText()) }
            }
        }
    }

    private fun buildServer(form: ServerFormState): Server {
        val usesKey = form.authMethod == AuthMethod.KEY
        return Server(
            id = targetId,
            name = form.name.trim(),
            host = form.host.trim(),
            port = ServerFormValidation.parsePort(form.port) ?: Server.DEFAULT_PORT,
            username = form.username.trim(),
            authMethod = form.authMethod,
            // En Android la clave vive cifrada en el SecretStore, no en una ruta.
            privateKeyPath = original?.privateKeyPath?.takeIf { usesKey }.orEmpty(),
            requiresPassphrase = usesKey && form.requiresPassphrase,
        )
    }

    /**
     * Orden seguro: 1) secretos nuevos, 2) `servers.json`, 3) borrar secretos obsoletos. Si
     * falla el paso 2 en un alta, no quedan secretos huérfanos.
     */
    private suspend fun persist(server: Server, form: ServerFormState) {
        val id = server.id
        val obsolete = when (server.authMethod) {
            AuthMethod.PASSWORD -> {
                if (form.password.isNotEmpty()) secrets.write(id, SecretKind.PASSWORD, form.password)
                listOf(SecretKind.PRIVATE_KEY, SecretKind.PASSPHRASE)
            }
            AuthMethod.KEY -> {
                importedKey?.let { secrets.write(id, SecretKind.PRIVATE_KEY, it) }
                if (server.requiresPassphrase && form.passphrase.isNotEmpty()) {
                    secrets.write(id, SecretKind.PASSPHRASE, form.passphrase)
                }
                listOfNotNull(SecretKind.PASSWORD, SecretKind.PASSPHRASE.takeUnless { server.requiresPassphrase })
            }
        }
        try {
            repository.upsert(server)
        } catch (error: Exception) {
            if (original == null) secrets.deleteAll(id)
            throw error
        }
        obsolete.forEach { secrets.delete(id, it) }
    }

    private fun ServerFormState.revalidated(): ServerFormState = copy(
        errors = ServerFormValidation.validate(
            FormInput(
                name = name,
                host = host,
                port = port,
                username = username,
                authMethod = authMethod,
                passwordEntered = password.isNotEmpty(),
                hasStoredPassword = hasStoredPassword,
                hasKey = keyState != KeyState.MISSING,
                requiresPassphrase = requiresPassphrase,
                passphraseEntered = passphrase.isNotEmpty(),
                hasStoredPassphrase = hasStoredPassphrase,
            ),
        ),
    )

    private companion object {
        const val PORT_MAX_DIGITS = 5
    }
}
