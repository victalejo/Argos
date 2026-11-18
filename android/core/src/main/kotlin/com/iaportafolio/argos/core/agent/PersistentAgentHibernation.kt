package com.iaportafolio.argos.core.agent

/**
 * Hibernación de agentes persistentes (port de `ArgosCore/Agent/PersistentAgentHibernation.swift`):
 * cuánto tiempo sin actividad se aguanta antes de parar un agente quieto (se reanuda solo al
 * escribirle).
 *
 * Hibernar para el proceso de claude Y TODO SU GRUPO: también lo que lanzó en segundo plano. El
 * vigilante no hiberna si el grupo ha gastado CPU apreciable desde la vuelta anterior, pero un
 * servidor ocioso no gasta CPU: la interfaz lo avisa donde se elige el plazo
 * ([BACKGROUND_WORK_WARNING]).
 */
class PersistentAgentHibernation private constructor(
    /** Segundos sin actividad antes de hibernar; 0 = nunca. */
    val idleSeconds: Int,
    /** Cada cuánto mira el vigilante (segundos). */
    val checkSeconds: Int,
) {
    val isEnabled: Boolean get() = idleSeconds > 0
    val idleHours: Int get() = idleSeconds / SECONDS_PER_HOUR

    override fun equals(other: Any?): Boolean =
        other is PersistentAgentHibernation && other.idleSeconds == idleSeconds && other.checkSeconds == checkSeconds

    override fun hashCode(): Int = 31 * idleSeconds + checkSeconds

    override fun toString(): String = "PersistentAgentHibernation(idleSeconds=$idleSeconds, checkSeconds=$checkSeconds)"

    companion object {
        const val DEFAULT_IDLE_HOURS = 4
        const val DEFAULT_CHECK_SECONDS = 300
        val CHOICES: List<Int> = listOf(0, 1, 2, 4, 8, 24)
        private const val SECONDS_PER_HOUR = 3600

        /**
         * Segundos de CPU del grupo entre dos vueltas a partir de los cuales el agente se
         * considera ocupado (algo suyo sigue trabajando aunque el log no cambie).
         */
        const val BUSY_CPU_SECONDS = 3

        /** Aviso para la interfaz, junto al selector del plazo (mismo texto que Apple). */
        const val BACKGROUND_WORK_WARNING = "En reposo se detiene el agente y todo lo que lanzó en segundo plano " +
            "(servidores de desarrollo, compilaciones). Si algo suyo sigue usando la CPU, no se pone en reposo."

        val STANDARD: PersistentAgentHibernation = ofHours(DEFAULT_IDLE_HOURS)

        fun ofHours(idleHours: Int): PersistentAgentHibernation =
            of(maxOf(0, idleHours) * SECONDS_PER_HOUR, DEFAULT_CHECK_SECONDS)

        fun of(idleSeconds: Int, checkSeconds: Int): PersistentAgentHibernation =
            PersistentAgentHibernation(maxOf(0, idleSeconds), maxOf(1, checkSeconds))

        /** Horas guardadas que no son una opción válida vuelven al valor por defecto. */
        fun sanitizedHours(stored: Int?): Int = stored?.takeIf { it in CHOICES } ?: DEFAULT_IDLE_HOURS

        fun title(hours: Int): String = when (hours) {
            0 -> "Nunca"
            1 -> "1 hora"
            else -> "$hours horas"
        }
    }
}
