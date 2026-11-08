package com.iaportafolio.argos.ui.common

import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource

/**
 * Texto para la UI que el ViewModel decide sin depender de `Context`: o un recurso de
 * `strings.xml` (con argumentos) o un mensaje ya redactado (los `userMessage` de `core`).
 */
sealed interface UiText {
    data class Plain(val value: String) : UiText

    data class Resource(@param:StringRes val id: Int, val args: List<Any> = emptyList()) : UiText

    companion object {
        fun res(@StringRes id: Int, vararg args: Any): UiText = Resource(id, args.toList())
    }
}

@Composable
fun UiText.asString(): String = when (this) {
    is UiText.Plain -> value
    is UiText.Resource -> stringResource(id, *args.toTypedArray())
}
