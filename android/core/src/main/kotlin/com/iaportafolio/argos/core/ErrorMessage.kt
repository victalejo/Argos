package com.iaportafolio.argos.core

/**
 * Punto único para convertir un error en texto de UI (port de `ArgosCore/ErrorMessage.swift`).
 *
 * Los errores tipados de Argos llevan su mensaje accionable en `message` (equivalente a
 * `errorDescription` de `LocalizedError`); si no hay mensaje se cae al nombre del tipo.
 */
val Throwable.userMessage: String
    get() = localizedMessage?.takeIf { it.isNotBlank() } ?: (this::class.simpleName ?: "Error desconocido")
