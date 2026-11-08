package com.iaportafolio.argos.ui.common

import com.iaportafolio.argos.core.userMessage
import com.iaportafolio.argos.data.ArgosLog
import kotlinx.coroutines.CancellationException

/**
 * Ejecuta [block] y convierte cualquier error (salvo la cancelación, que se relanza siempre)
 * en un [Result] fallido, registrándolo SIN secretos (solo tipo y mensaje).
 */
internal suspend inline fun <T> logFailures(tag: String, what: String, block: () -> T): Result<T> = try {
    Result.success(block())
} catch (cancel: CancellationException) {
    throw cancel
} catch (error: Exception) {
    ArgosLog.error(tag, what, error)
    Result.failure(error)
}

internal fun Throwable.toUiText(): UiText = UiText.Plain(userMessage)
