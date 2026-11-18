package com.iaportafolio.argos.core

/** Por qué falló abrir una conexión (port de `SSHFailureKind`). */
enum class SSHFailureKind {
    /** El servidor rechazó la contraseña o la clave (o no hay credencial utilizable). */
    AUTHENTICATION,

    /** La huella del servidor cambió o no se pudo leer el registro de huellas. */
    HOST_KEY,

    /** Red, servidor caído, tiempo agotado… (transitorio). */
    NETWORK,
}

/**
 * Salud de la conexión de un servidor (port de `ArgosCore/ConnectionHealth.swift`, lógica pura e
 * inmutable). Decide si se puede intentar abrir una conexión SSH nueva:
 * - Contraseña/clave rechazada o host key cambiada: el FONDO no reintenta hasta que el usuario
 *   actúe (insistir con una contraseña mala es lo que hace que fail2ban banee la IP). En Android
 *   cualquier intento del usuario cuenta como esa acción (no hay un «Reintentar» por pantalla).
 * - Fallo de red: los sondeos de fondo esperan 1, 2, 4… hasta 60 s entre intentos; una acción del
 *   usuario se lo salta. Un éxito lo reinicia todo.
 *
 * Los instantes son milisegundos de un reloj monótono (`System.nanoTime() / 1e6`).
 */
data class ConnectionHealth(
    val status: Status = Status.Healthy,
    /** Mensaje del último fallo (para explicar por qué se espera). */
    val lastFailureMessage: String? = null,
) {
    sealed interface Status {
        data object Healthy : Status

        /** Hasta una acción explícita del usuario. */
        data class Blocked(val kind: SSHFailureKind) : Status

        /** [failures] fallos de red seguidos; el fondo no reintenta antes de [retryAtMillis]. */
        data class BackingOff(val failures: Int, val retryAtMillis: Long) : Status
    }

    /** Resultado de pedir permiso para conectar. */
    sealed interface Admission {
        data object Allowed : Admission

        data class Blocked(val kind: SSHFailureKind) : Admission

        /** Aún no: faltan [remainingMillis] para el próximo intento de fondo. */
        data class Deferred(val remainingMillis: Long) : Admission
    }

    val isBlocked: Boolean get() = status is Status.Blocked

    fun admission(priority: ConnectionPriority, nowMillis: Long): Admission = when (val current = status) {
        Status.Healthy -> Admission.Allowed
        // Un intento del usuario es la acción que levanta el bloqueo (ver la cabecera).
        is Status.Blocked -> if (priority == ConnectionPriority.USER) Admission.Allowed else Admission.Blocked(current.kind)
        is Status.BackingOff ->
            if (priority == ConnectionPriority.USER || nowMillis >= current.retryAtMillis) {
                Admission.Allowed
            } else {
                Admission.Deferred(current.retryAtMillis - nowMillis)
            }
    }

    fun recordingFailure(kind: SSHFailureKind, message: String, nowMillis: Long): ConnectionHealth = when (kind) {
        SSHFailureKind.AUTHENTICATION, SSHFailureKind.HOST_KEY -> ConnectionHealth(Status.Blocked(kind), message)
        // Un fallo de red no levanta un bloqueo por credenciales o host key.
        SSHFailureKind.NETWORK -> if (isBlocked) {
            this
        } else {
            val failures = ((status as? Status.BackingOff)?.failures ?: 0) + 1
            ConnectionHealth(Status.BackingOff(failures, nowMillis + backoffMillis(failures)), message)
        }
    }

    fun recordingSuccess(): ConnectionHealth = ConnectionHealth()

    companion object {
        const val INITIAL_BACKOFF_MILLIS = 1_000L
        const val MAX_BACKOFF_MILLIS = 60_000L
        private const val MAX_EXPONENT = 16

        /** Espera tras [failures] fallos seguidos: 1, 2, 4, 8, 16, 32, 60, 60… s. */
        fun backoffMillis(failures: Int): Long {
            val exponent = minOf(maxOf(failures, 1) - 1, MAX_EXPONENT)
            return minOf(INITIAL_BACKOFF_MILLIS shl exponent, MAX_BACKOFF_MILLIS)
        }
    }
}

/** Un sondeo de fondo no reintenta todavía (servidor inaccesible hace poco). */
class SSHBackingOffException(val retryInMillis: Long, val lastFailure: String?) : Exception(
    "El servidor no respondió hace poco; se volverá a intentar en ${maxOf(1, retryInMillis / 1_000)} s." +
        (lastFailure?.let { " Último error: $it" } ?: ""),
)

/** Resultado de un sondeo de la conexión (port de `ProbeOutcome`). */
enum class ProbeOutcome {
    /** El comando corrió. */
    ALIVE,

    /** El servidor rechazó el canal: está vivo, solo que sin canales libres (`MaxSessions`). */
    REJECTED,

    /** No hubo respuesta a tiempo (no concluyente por sí solo: también pasa con el servidor en swap). */
    UNRESPONSIVE,

    /** La conexión ya está cerrada o se cortó. */
    BROKEN,
}

/** Fallos seguidos de una conexión vigilada (port de `LinkLiveness`, inmutable). */
data class LinkLiveness(val consecutiveFailures: Int = 0) {
    fun recording(outcome: ProbeOutcome, threshold: Int): LinkLiveness = when (outcome) {
        ProbeOutcome.ALIVE, ProbeOutcome.REJECTED -> LinkLiveness()
        ProbeOutcome.UNRESPONSIVE -> LinkLiveness(consecutiveFailures + 1)
        ProbeOutcome.BROKEN -> LinkLiveness(maxOf(threshold, consecutiveFailures + 1))
    }

    fun isDead(threshold: Int): Boolean = consecutiveFailures >= maxOf(1, threshold)
}
