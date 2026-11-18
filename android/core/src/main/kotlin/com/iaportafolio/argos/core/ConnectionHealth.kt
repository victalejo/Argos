package com.iaportafolio.argos.core

/** Resultado de [ConnectionHealthProbing.probeConnection]. */
enum class ConnectionProbeResult {
    /** No había conexión compartida abierta: no hay nada que comprobar (la próxima operación conecta). */
    NOT_CONNECTED,

    /** La conexión respondió dentro del plazo. */
    ALIVE,

    /**
     * Estaba caída o no respondió a tiempo: se soltó y se cerró. Los terminales que fueran por
     * ella terminan con «conexión perdida» (y se reenganchan); la próxima operación reconecta.
     */
    RECYCLED,
}

/**
 * Sonda de salud de la conexión compartida de un servidor, para invalidarla en cuanto deja de
 * servir: al volver a primer plano o al cambiar de red. Una conexión medio abierta no falla por
 * sí sola: sin esto se esperaría al keep-alive (30 s × 3) o al timeout de TCP.
 *
 * Aparte de [SSHServicing] para no obligar a los dobles de prueba a implementarla.
 */
interface ConnectionHealthProbing {
    /** Nunca lanza salvo la cancelación. [timeoutMillis] corto (3–5 s). */
    suspend fun probeConnection(timeoutMillis: Long = DEFAULT_PROBE_TIMEOUT_MILLIS): ConnectionProbeResult

    companion object {
        const val DEFAULT_PROBE_TIMEOUT_MILLIS: Long = 4_000
    }
}
