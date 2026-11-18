package com.iaportafolio.argos.core

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.withContext
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/**
 * Quién pide la red (port de `ArgosCore/ConnectionPriority.swift`): el usuario (una acción
 * explícita, que no debe esperar) o un sondeo de fondo (avisos, estado de git, puertos…, que puede
 * esperar y no debe insistir contra un servidor caído). Viaja en el contexto de la corrutina:
 * marcar un punto de entrada con [ConnectionPriority.background] basta para que TODO lo que hace
 * por debajo —conexión y turno de canal incluidos— cuente como fondo. Lo no marcado es del usuario.
 */
enum class ConnectionPriority {
    /** Acción del usuario: se salta la espera entre reintentos y tiene turno preferente. */
    USER,

    /** Sondeo de fondo: respeta la espera exponencial y tiene un cupo de canales menor. */
    BACKGROUND,
    ;

    /** Elemento del contexto que la lleva. */
    class Element(val priority: ConnectionPriority) : AbstractCoroutineContextElement(Key) {
        companion object Key : CoroutineContext.Key<Element>
    }

    companion object {
        /** Prioridad de la corrutina actual ([USER] si nadie la marcó). */
        suspend fun current(): ConnectionPriority = currentCoroutineContext()[Element]?.priority ?: USER

        /** Ejecuta [block] como trabajo de fondo. */
        suspend fun <T> background(block: suspend () -> T): T = withContext(Element(BACKGROUND)) { block() }
    }
}
