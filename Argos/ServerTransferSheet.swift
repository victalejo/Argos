//
//  ServerTransferSheet.swift
//  Argos
//
//  «Enviar al iPhone»: crea una clave Ed25519 solo para el iPhone, la autoriza en el
//  servidor (`authorized_keys`, por la conexión SSH que ya tiene el Mac) y muestra un
//  QR con todo lo necesario para conectarse. El QR caduca a los 5 minutos; «Cancelar»
//  retira la clave del servidor, «Hecho» la conserva.
//

import Crypto
import SwiftUI

struct ServerTransferSheet: View {
    let server: Server
    let service: any SSHServicing
    let onClose: () -> Void

    private enum Phase {
        case preparing
        case ready(ServerTransfer)
        case failed(String)
    }

    @State private var phase: Phase = .preparing
    /// Clave dedicada al iPhone: una por hoja (un reintento no debe cambiarla).
    @State private var key = Curve25519.Signing.PrivateKey()
    /// Comentario de la clave ya autorizada en el servidor (para poder revocarla).
    @State private var authorizedComment: String?
    @State private var isClosing = false

    var body: some View {
        VStack(spacing: 18) {
            header
            content
                .frame(minHeight: 300)
            footer
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled()
        .task { await prepare() }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            Text("Enviar «\(server.name)» al iPhone")
                .font(.title3.weight(.semibold))
            Text(verbatim: "\(server.username)@\(server.host)\(server.port == 22 ? "" : ":\(server.port)")")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .preparing:
            VStack(spacing: 10) {
                ProgressView()
                Text("Creando una clave para el iPhone y autorizándola en el servidor…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Reintentar") { Task { await prepare() } }
            }
        case .ready(let transfer):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = Int(ServerTransfer.lifetime - context.date.timeIntervalSince(transfer.createdAt))
                if remaining > 0 {
                    qrCode(for: transfer, remaining: remaining)
                } else {
                    expired(transfer)
                }
            }
        }
    }

    private func qrCode(for transfer: ServerTransfer, remaining: Int) -> some View {
        VStack(spacing: 12) {
            if let image = QRCodeRenderer.image(for: transfer.urlString()) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Código QR para añadir el servidor en el iPhone")
            }
            Text("Escanéalo con la cámara del iPhone o desde Argos → Servidores → \(Image(systemName: "qrcode.viewfinder")).")
                .font(.callout)
                .multilineTextAlignment(.center)
            Text("El iPhone acepta el código durante \(remaining / 60):\(String(format: "%02d", remaining % 60)) más")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Label("El código contiene la clave de acceso: muéstralo solo a tu iPhone. Si alguien más lo vio, pulsa «Cancelar» para retirarla del servidor.",
                  systemImage: "eye.trianglebadge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func expired(_ transfer: ServerTransfer) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.xmark")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("El código caducó.")
                .font(.callout)
            Button("Mostrar de nuevo") {
                var renewed = transfer
                renewed.createdAt = Date()
                phase = .ready(renewed)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if let authorizedComment {
                Text("La clave del iPhone se añadió a ~/.ssh/authorized_keys del servidor como «\(authorizedComment)». Para revocarla más tarde, borra esa línea. Tu clave del Mac no sale de este equipo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancelar", role: .cancel) { Task { await cancel() } }
                    .keyboardShortcut(.cancelAction)
                    .help("Cierra y retira del servidor la clave creada para el iPhone")
                Spacer()
                if isClosing { ProgressView().controlSize(.small) }
                Button("Hecho") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(authorizedComment == nil || isClosing)
                    .help("Ya lo escaneé: conserva la clave del iPhone en el servidor")
            }
        }
    }

    // MARK: - Acciones

    private func prepare() async {
        phase = .preparing
        let comment = authorizedComment ?? ServerTransfer.makeKeyComment()
        do {
            if authorizedComment == nil {
                let line = OpenSSHKeyWriter.authorizedKeyLine(key.publicKey, comment: comment)
                try await service.authorizeKey(line: line)
                authorizedComment = comment
            }
        } catch {
            Log.ssh.error("No se pudo autorizar la clave del iPhone: \(error.userMessage, privacy: .public)")
            phase = .failed("No se pudo autorizar la clave en el servidor: \(error.userMessage)")
            return
        }
        phase = .ready(ServerTransfer(
            name: server.name,
            host: server.host,
            port: server.port,
            username: server.username,
            keySeed: key.rawRepresentation,
            keyComment: comment,
            hostKeyFingerprint: TOFUHostKeyValidator.trustedFingerprint(host: server.host, port: server.port),
            createdAt: Date()
        ))
    }

    private func cancel() async {
        guard let comment = authorizedComment else { return onClose() }
        isClosing = true
        defer { isClosing = false }
        do {
            try await service.revokeKey(comment: comment)
            onClose()
        } catch {
            Log.ssh.error("No se pudo retirar la clave del iPhone (\(comment, privacy: .public)): \(error.userMessage, privacy: .public)")
            phase = .failed("No se pudo retirar la clave del servidor: \(error.userMessage)\n"
                + "Pulsa «Cancelar» para reintentarlo o borra a mano la línea «\(comment)» de ~/.ssh/authorized_keys.")
        }
    }
}
