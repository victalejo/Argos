package com.iaportafolio.argos.ui.common

import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect

/** Muestra [message] en un snackbar una sola vez y avisa al ViewModel con [onShown]. */
@Composable
fun MessageEffect(message: UiText?, snackbar: SnackbarHostState, onShown: () -> Unit) {
    val text = message?.asString()
    LaunchedEffect(message) {
        if (text != null) {
            onShown()
            snackbar.showSnackbar(text)
        }
    }
}
