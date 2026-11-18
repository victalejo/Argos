//
//  PersistentAgentSession+Adopt.swift
//  Argos
//
//  Crear agentes persistentes desde el Mac: uno nuevo (con la ruta de claude ya conocida)
//  o uno que CONTINÚA una conversación del panel con su mismo id de sesión (`--resume`),
//  con el log inicial de `AgentTranscriptSeed`. Si algo falla a medias, no queda nada en
//  el servidor (ni carpeta ni proceso).
//

import Foundation

extension PersistentAgentSession {

    /// Lanza un agente nuevo con id `id` (por defecto, uno nuevo).
    static func launch(
        service: any SSHServicing,
        id: String = UUID().uuidString.lowercased(),
        workingDirectory: String,
        title: String,
        permissionMode: ClaudeAgentCommand.PermissionMode,
        oauthToken: String?,
        hibernation: PersistentAgentHibernation,
        claudePath: String?
    ) async throws -> PersistentAgentSession {
        let meta = PersistentAgentMeta(
            workingDirectory: workingDirectory, title: title, createdAt: Date(), permissionMode: permissionMode.rawValue
        )
        try await start(
            service: service, id: id, meta: meta, resume: false, oauthToken: oauthToken,
            hibernation: hibernation, claudePath: claudePath
        )
        return PersistentAgentSession(
            service: service,
            info: PersistentAgentInfo(id: id, isAlive: true, logBytes: 0, meta: meta),
            hibernation: { hibernation }
        )
    }

    /// Continúa en el servidor la conversación `sessionID` (cuyo proceso ya debe estar
    /// PARADO: nunca dos claude con el mismo id). Su log empieza con `transcript`; la
    /// sesión devuelta ya lo muestra y sigue el log desde ahí.
    static func adopt(
        service: any SSHServicing,
        sessionID: String,
        workingDirectory: String,
        title: String,
        permissionMode: ClaudeAgentCommand.PermissionMode,
        transcript: AgentConversationState,
        oauthToken: String?,
        hibernation: PersistentAgentHibernation,
        claudePath: String?
    ) async throws -> PersistentAgentSession {
        let id = sessionID.lowercased()
        guard PersistentAgentScript.isValidID(id) else { throw AgentConversionError.nothingToContinue }
        let seed = AgentTranscriptSeed.make(from: transcript)
        guard !seed.lines.isEmpty else { throw AgentConversionError.nothingToContinue }
        let bytes = seed.bytes
        try await writeSeed(service: service, id: id, bytes: bytes)
        let meta = PersistentAgentMeta(
            workingDirectory: workingDirectory, title: title, createdAt: Date(), permissionMode: permissionMode.rawValue
        )
        do {
            try await start(
                service: service, id: id, meta: meta, resume: true, oauthToken: oauthToken,
                hibernation: hibernation, claudePath: claudePath
            )
        } catch {
            // No debe quedar un agente a medias que otro dispositivo pudiera reanudar.
            do {
                _ = try await service.runAgentScript(PersistentAgentScript.stop(id: id, delete: true))
            } catch let cleanup {
                Log.agent.error("No se pudo limpiar el agente a medias: \(cleanup.localizedDescription, privacy: .private)")
            }
            throw error
        }
        return PersistentAgentSession(
            service: service,
            info: PersistentAgentInfo(id: id, isAlive: true, logBytes: bytes.count, meta: meta),
            seededState: seed.replayedState,
            receivedBytes: bytes.count,
            hibernation: { hibernation }
        )
    }

    private static func writeSeed(service: any SSHServicing, id: String, bytes: [UInt8]) async throws {
        let replies = [PersistentAgentScript.seededReply, PersistentAgentScript.existsReply, PersistentAgentScript.shortReply]
        let reply = try await AgentStdinExchange.firstLine(
            service: service,
            command: PersistentAgentScript.seed(id: id, byteCount: bytes.count),
            input: bytes,
            timeout: .seconds(120),
            accept: { replies.contains($0) }
        )
        switch reply {
        case PersistentAgentScript.seededReply: return
        case PersistentAgentScript.existsReply: throw AgentConversionError.alreadyPersistent
        default: throw PersistentAgentError.truncatedSend
        }
    }
}
