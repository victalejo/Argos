package com.iaportafolio.argos.ui.form

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.iaportafolio.argos.R
import com.iaportafolio.argos.core.AuthMethod
import com.iaportafolio.argos.ui.common.MessageEffect
import com.iaportafolio.argos.ui.common.StatusMessage

/** Acciones del formulario (agrupadas para no arrastrar diez lambdas por la jerarquía). */
interface ServerFormActions {
    fun onNameChange(value: String)
    fun onHostChange(value: String)
    fun onPortChange(value: String)
    fun onUsernameChange(value: String)
    fun onAuthMethodChange(value: AuthMethod)
    fun onPasswordChange(value: String)
    fun onRequiresPassphraseChange(value: Boolean)
    fun onPassphraseChange(value: String)
    fun onKeyFilePicked(uri: String?)
    fun save()
    fun messageShown()
}

/** Alta/edición de un servidor (equivale a `ServerFormView` de Apple). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ServerFormScreen(
    state: ServerFormState,
    actions: ServerFormActions,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val snackbar = remember { SnackbarHostState() }
    MessageEffect(state.message, snackbar, actions::messageShown)
    LaunchedEffect(state.saved) { if (state.saved) onClose() }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(if (state.isNew) R.string.form_title_new else R.string.form_title_edit)) },
                navigationIcon = {
                    IconButton(onClick = onClose) {
                        Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.action_cancel))
                    }
                },
                actions = {
                    if (state.isSaving) {
                        val saving = stringResource(R.string.form_saving)
                        CircularProgressIndicator(
                            modifier = Modifier
                                .padding(horizontal = 16.dp)
                                .size(24.dp)
                                .semantics { contentDescription = saving },
                        )
                    } else if (!state.notFound) {
                        TextButton(onClick = actions::save) { Text(stringResource(R.string.action_save)) }
                    }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        if (state.notFound) {
            StatusMessage(
                icon = painterResource(R.drawable.ic_server),
                title = stringResource(R.string.form_not_found),
                modifier = Modifier.padding(padding),
            )
        } else {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.TopCenter) {
                FormContent(state, actions)
            }
        }
    }
}

@Composable
private fun FormContent(state: ServerFormState, actions: ServerFormActions) {
    val errors = state.visibleErrors
    Column(
        modifier = Modifier
            .widthIn(max = 600.dp)
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .imePadding()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        SectionTitle(R.string.form_section_server)
        FormTextField(state.name, actions::onNameChange, R.string.form_name, errors[FormField.NAME])
        FormTextField(
            state.host, actions::onHostChange, R.string.form_host, errors[FormField.HOST],
            keyboard = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false, imeAction = ImeAction.Next),
        )
        FormTextField(
            state.port, actions::onPortChange, R.string.form_port, errors[FormField.PORT],
            keyboard = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Next),
        )
        FormTextField(
            state.username, actions::onUsernameChange, R.string.form_username, errors[FormField.USERNAME],
            keyboard = KeyboardOptions(keyboardType = KeyboardType.Ascii, autoCorrectEnabled = false, imeAction = ImeAction.Next),
        )

        Spacer(Modifier.size(8.dp))
        SectionTitle(R.string.form_section_auth)
        AuthMethodPicker(state.authMethod, actions::onAuthMethodChange)
        when (state.authMethod) {
            AuthMethod.PASSWORD -> {
                SecretField(
                    state.password, actions::onPasswordChange,
                    if (state.hasStoredPassword) R.string.form_password_keep else R.string.form_password,
                    errors[FormField.PASSWORD],
                )
                FooterText(R.string.form_footer_password)
            }
            AuthMethod.KEY -> KeySection(state, actions)
        }
    }
}

@Composable
private fun KeySection(state: ServerFormState, actions: ServerFormActions) {
    val errors = state.visibleErrors
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        actions.onKeyFilePicked(uri?.toString())
    }
    OutlinedButton(
        onClick = { picker.launch(arrayOf("*/*")) },
        enabled = !state.isImportingKey,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Icon(painterResource(R.drawable.ic_key), contentDescription = null)
        Spacer(Modifier.size(8.dp))
        Text(
            stringResource(
                when {
                    state.isImportingKey -> R.string.form_key_importing
                    state.keyState == KeyState.IMPORTED -> R.string.form_key_change
                    state.keyState == KeyState.STORED -> R.string.form_key_stored
                    else -> R.string.form_key_import
                },
            ),
        )
    }
    errors[FormField.KEY]?.let { ErrorText(it) }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .toggleable(value = state.requiresPassphrase, role = Role.Switch, onValueChange = actions::onRequiresPassphraseChange)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(stringResource(R.string.form_requires_passphrase), modifier = Modifier.weight(1f))
        // El Row ya es el control accesible (toggleable): el Switch no repite la acción.
        Switch(checked = state.requiresPassphrase, onCheckedChange = null)
    }
    if (state.requiresPassphrase) {
        SecretField(
            state.passphrase, actions::onPassphraseChange,
            if (state.hasStoredPassphrase) R.string.form_passphrase_keep else R.string.form_passphrase,
            errors[FormField.PASSPHRASE],
        )
    }
    FooterText(R.string.form_footer_key)
}

@Composable
private fun AuthMethodPicker(selected: AuthMethod, onSelect: (AuthMethod) -> Unit) {
    val options = listOf(AuthMethod.PASSWORD to R.string.form_method_password, AuthMethod.KEY to R.string.form_method_key)
    SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
        options.forEachIndexed { index, (method, label) ->
            SegmentedButton(
                selected = method == selected,
                onClick = { onSelect(method) },
                shape = SegmentedButtonDefaults.itemShape(index = index, count = options.size),
            ) { Text(stringResource(label)) }
        }
    }
}

@Composable
private fun FormTextField(
    value: String,
    onChange: (String) -> Unit,
    @StringRes label: Int,
    error: FieldError?,
    keyboard: KeyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(stringResource(label)) },
        isError = error != null,
        supportingText = error?.let { { Text(stringResource(it.messageRes())) } },
        singleLine = true,
        keyboardOptions = keyboard,
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun SecretField(value: String, onChange: (String) -> Unit, @StringRes label: Int, error: FieldError?) {
    var visible by rememberSaveable { mutableStateOf(false) }
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(stringResource(label)) },
        isError = error != null,
        supportingText = error?.let { { Text(stringResource(it.messageRes())) } },
        singleLine = true,
        visualTransformation = if (visible) VisualTransformation.None else PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
        trailingIcon = {
            TextButton(onClick = { visible = !visible }) {
                Text(stringResource(if (visible) R.string.form_hide_secret else R.string.form_show_secret))
            }
        },
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun SectionTitle(@StringRes text: Int) {
    Text(
        stringResource(text),
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.semantics { heading() },
    )
}

@Composable
private fun FooterText(@StringRes text: Int) {
    Text(stringResource(text), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun ErrorText(error: FieldError) {
    Text(stringResource(error.messageRes()), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
}

@StringRes
private fun FieldError.messageRes(): Int = when (this) {
    FieldError.NAME_REQUIRED -> R.string.error_name_required
    FieldError.HOST_REQUIRED -> R.string.error_host_required
    FieldError.HOST_INVALID -> R.string.error_host_invalid
    FieldError.PORT_INVALID -> R.string.error_port_invalid
    FieldError.USERNAME_REQUIRED -> R.string.error_username_required
    FieldError.USERNAME_INVALID -> R.string.error_username_invalid
    FieldError.PASSWORD_REQUIRED -> R.string.error_password_required
    FieldError.KEY_REQUIRED -> R.string.error_key_required
    FieldError.PASSPHRASE_REQUIRED -> R.string.error_passphrase_required
}
