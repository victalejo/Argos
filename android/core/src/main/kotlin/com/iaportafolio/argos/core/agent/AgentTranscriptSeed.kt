package com.iaportafolio.argos.core.agent

/**
 * Lo que Android necesita saber de los logs SEMBRADOS (`ArgosCore/Agent/AgentTranscriptSeed.swift`).
 *
 * El Mac puede pasar al servidor una conversación de su panel («Continuar en el servidor»): crea
 * un agente persistente con el MISMO id de sesión y su `out.ndjson` empieza con lo que ya se veía,
 * escrito como los eventos stream-json que emite claude (mensajes `user`/`assistant` con
 * `text`, `thinking`, `tool_use` y `tool_result`). Android no siembra; solo lo lee: el reductor
 * reconstruye la conversación entera como con cualquier otro log.
 *
 * Si la conversación no acababa en un `result`, el log sembrado se cierra con uno cuyo `subtype`
 * es [CLOSING_SUBTYPE]: el agente está quieto, pero no terminó un turno ahora (no se avisa de
 * «terminó» por él; ver [AgentAttention.Finished.seeded]).
 */
object AgentTranscriptSeed {
    const val CLOSING_SUBTYPE = "argos_seed"
}
