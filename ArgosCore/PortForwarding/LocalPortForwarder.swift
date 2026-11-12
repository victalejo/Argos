//
//  LocalPortForwarder.swift
//  ArgosCore
//
//  Reenvío de puertos local (como `ssh -L`): escucha en 127.0.0.1 del dispositivo y
//  cada conexión entrante abre un canal `direct-tcpip` por SSH hacia `host:puerto` del
//  servidor; los bytes se copian en ambos sentidos con `GlueHandler`.
//
//  El listener se crea en el MISMO event loop que la conexión SSH: así el socket local
//  y el canal SSH comparten hilo y el pegado no necesita sincronización.
//

import Foundation
import NIOCore
import NIOPosix
import NIOConcurrencyHelpers
@preconcurrency import NIOSSH   // SSHChannelType.DirectTCPIP
@preconcurrency import Citadel

/// Un túnel activo.
struct ActivePortForward: Identifiable, Hashable, Sendable {
    let id: UUID
    let remotePort: Int
    let targetHost: String
    let localPort: Int
    /// Su conexión se cayó y aún no se ha podido reabrir (se reintenta sola).
    var isReconnecting = false

    /// Copia marcada como caída a la espera de reabrirse.
    func reconnecting() -> ActivePortForward {
        var copy = self
        copy.isReconnecting = true
        return copy
    }

    var localURL: URL? { URL(string: "http://localhost:\(localPort)") }
    var localAddress: String { "localhost:\(localPort)" }
}

enum PortForwardError: LocalizedError, Equatable {
    case invalidPort(Int)
    case alreadyForwarded(Int)
    case bindFailed(String)
    case unsupportedEventLoop

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "El puerto \(port) no es válido (debe estar entre 1 y 65535)."
        case .alreadyForwarded(let port):
            return "El puerto \(port) ya se está reenviando."
        case .bindFailed(let detail):
            return "No se pudo abrir el puerto en este dispositivo: \(detail)"
        case .unsupportedEventLoop:
            return "La conexión SSH no admite reenviar puertos."
        }
    }
}

/// Conexión SSH actual del túnel. Se puede sustituir al reconectar sin cerrar el
/// listener (las conexiones nuevas usan la nueva).
final class ForwardConnection: Sendable {
    private let box: NIOLockedValueBox<SSHClient>

    init(_ client: SSHClient) { box = NIOLockedValueBox(client) }

    var client: SSHClient { box.withLockedValue { $0 } }
    func replace(with client: SSHClient) { box.withLockedValue { $0 = client } }
}

enum LocalPortForwarder {

    /// Abre el listener en 127.0.0.1 (nunca en todas las interfaces: el túnel no debe
    /// quedar expuesto a la red local). Prueba `preferredLocalPort` y, si está ocupado,
    /// deja que el sistema elija uno libre.
    static func listen(
        connection: ForwardConnection,
        activity: PortForwardActivity,
        targetHost: String,
        remotePort: Int,
        preferredLocalPort: Int
    ) async throws -> (channel: Channel, localPort: Int) {
        guard (1...65535).contains(remotePort) else { throw PortForwardError.invalidPort(remotePort) }
        let loop = connection.client.eventLoop
        guard let bootstrap = ServerBootstrap(validatingGroup: loop) else {
            throw PortForwardError.unsupportedEventLoop
        }
        let configured = bootstrap
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            // Reabrir el mismo puerto justo después de cerrarlo (al reconectar).
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Sin auto-lectura hasta que el canal SSH esté listo (no se pierde nada).
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { child in
                pipe(child: child, connection: connection, activity: activity,
                     targetHost: targetHost, remotePort: remotePort)
            }

        var lastError: Error?
        let candidates = preferredLocalPort > 0 && preferredLocalPort < 65536 ? [preferredLocalPort, 0] : [0]
        for port in candidates {
            do {
                let channel = try await configured.bind(host: "127.0.0.1", port: port).get()
                let bound = channel.localAddress?.port ?? port
                return (channel, bound)
            } catch {
                lastError = error
            }
        }
        throw PortForwardError.bindFailed(lastError.map { "\($0)" } ?? "error desconocido")
    }

    /// Conecta una conexión local entrante con un canal `direct-tcpip` nuevo.
    private static func pipe(
        child: Channel,
        connection: ForwardConnection,
        activity: PortForwardActivity,
        targetHost: String,
        remotePort: Int
    ) -> EventLoopFuture<Void> {
        // Cuenta la conexión mientras siga abierta (para el cierre por inactividad).
        activity.connectionOpened()
        child.closeFuture.whenComplete { _ in activity.connectionClosed() }
        let (local, remote) = GlueHandler.matchedPair()
        do {
            try child.pipeline.syncOperations.addHandler(local)
        } catch {
            return child.eventLoop.makeFailedFuture(error)
        }
        let originator = child.remoteAddress
            ?? (try? SocketAddress(ipAddress: "127.0.0.1", port: 0))
        let client = connection.client
        Task {
            do {
                guard client.isConnected, let originator else { throw PortForwardError.unsupportedEventLoop }
                _ = try await client.createDirectTCPIPChannel(
                    using: SSHChannelType.DirectTCPIP(
                        targetHost: targetHost,
                        targetPort: remotePort,
                        originatorAddress: originator
                    )
                ) { channel in
                    channel.pipeline.addHandler(remote)
                }
                try await child.setOption(ChannelOptions.autoRead, value: true).get()
            } catch {
                // Puerto cerrado en el servidor o conexión SSH caída: el navegador ve
                // un cierre de conexión, igual que con `ssh -L`.
                Log.ssh.notice("Túnel a \(targetHost, privacy: .public):\(remotePort) rechazado: \(error.localizedDescription, privacy: .public)")
                child.close(promise: nil)
            }
        }
        return child.eventLoop.makeSucceededVoidFuture()
    }
}

/// Copia bytes entre dos canales del MISMO event loop, respetando la contrapresión
/// (solo lee de un lado si el otro puede escribir). Patrón de los ejemplos de SwiftNIO.
/// `@unchecked Sendable`: solo se usa desde el event loop de sus canales.
final class GlueHandler: @unchecked Sendable {
    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private func partnerWrite(_ data: NIOAny) { context?.write(data, promise: nil) }
    private func partnerFlush() { context?.flush() }
    private func partnerWriteEOF() { context?.close(mode: .output, promise: nil) }
    private func partnerCloseFull() { context?.close(promise: nil) }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    private var partnerWritable: Bool { context?.channel.isWritable ?? false }
}

extension GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.partnerWriteEOF()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.partnerCloseFull()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}
