package com.iaportafolio.argos.data

import android.util.Log

/**
 * Registro centralizado (equivale a `Log` con `os.Logger` en Apple). Regla: NUNCA se pasan
 * secretos (contraseñas, passphrases, claves): solo ids, endpoints y mensajes de error.
 */
object ArgosLog {
    const val TAG_STORE = "Argos.store"
    const val TAG_SECRETS = "Argos.secrets"
    const val TAG_HOST_KEY = "Argos.hostkey"
    const val TAG_SSH = "Argos.ssh"
    const val TAG_UI = "Argos.ui"

    fun info(tag: String, message: String) {
        Log.i(tag, message)
    }

    fun warn(tag: String, message: String, error: Throwable? = null) {
        Log.w(tag, describe(message, error))
    }

    fun error(tag: String, message: String, error: Throwable? = null) {
        Log.e(tag, describe(message, error))
    }

    /**
     * Solo el tipo y el mensaje del error, sin la traza completa: la causa encadenada de una
     * librería SSH podría incluir material sensible en su `toString`.
     */
    private fun describe(message: String, error: Throwable?): String =
        if (error == null) message else "$message (${error::class.java.simpleName}: ${error.message})"
}
