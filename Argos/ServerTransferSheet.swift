//
//  ServerTransferSheet.swift
//  Argos
//
//  «Enviar al iPhone»: crea una clave Ed25519 solo para el iPhone, la autoriza en el
//  servidor (`authorized_keys`, por la conexión SSH que ya tiene el Mac) y muestra un
//  QR con todo lo necesario para conectarse. El QR caduca a los 5 minutos; «Cancelar»
//  retira la clave del servidor, «Hecho» la conserva. También contiene
//  `AuthorizedDevicesSheet`, que lista esas claves y permite revocarlas.
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
                Text("La clave del iPhone se añadió a ~/.ssh/authorized_keys del servidor como «\(authorizedComment)». Puedes revocarla cuando quieras en el menú del servidor → «Dispositivos autorizados…». Tu clave del Mac no sale de este equipo.")
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

// MARK: - Dispositivos autorizados

/// «Dispositivos autorizados»: lista las claves que «Enviar al iPhone» añadió al
/// `authorized_keys` del servidor y permite revocarlas (p. ej. un iPhone perdido).
struct AuthorizedDevicesSheet: View {
    let server: Server
    let service: any SSHServicing
    let onClose: () -> Void

    private enum Phase {
        case loading
        case loaded([AuthorizedDeviceKey])
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var pendingRevocation: AuthorizedDeviceKey?
    @State private var revoking: AuthorizedDeviceKey.ID?
    @State private var revokeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dispositivos autorizados")
                    .font(.title3.weight(.semibold))
                Text("iPhone y iPad que acceden a «\(server.name)» con una clave creada por «Enviar al iPhone». Revocar una quita su acceso al momento.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
                .frame(minHeight: 180, maxHeight: 320)
            if let revokeError {
                Text(revokeError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Actualizar", systemImage: "arrow.clockwise") { Task { await load() } }
                    .disabled(revoking != nil)
                Spacer()
                Button("Cerrar") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .task { await load() }
        .confirmationDialog(
            "¿Revocar el acceso de este dispositivo?",
            isPresented: Binding(
                get: { pendingRevocation != nil },
                set: { if !$0 { pendingRevocation = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRevocation
        ) { key in
            Button("Revocar", role: .destructive) { Task { await revoke(key) } }
            Button("Cancelar", role: .cancel) {}
        } message: { key in
            Text("Se quitará la clave \(key.shortID) de ~/.ssh/authorized_keys del servidor. Ese dispositivo dejará de poder conectarse; para volver a usarlo, envíale el servidor de nuevo.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Leyendo authorized_keys…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("No se pudo leer la lista", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Reintentar") { Task { await load() } }
            }
        case .loaded(let keys) where keys.isEmpty:
            ContentUnavailableView {
                Label("Ningún dispositivo autorizado", systemImage: "iphone.slash")
            } description: {
                Text("Usa «Enviar al iPhone…» en el menú del servidor para añadir uno.")
            }
        case .loaded(let keys):
            List(keys) { key in
                row(for: key)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }

    private func row(for key: AuthorizedDeviceKey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: key))
                    .font(.body.weight(.medium))
                Text(verbatim: "\(key.shortID) · \(key.fingerprint)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(key.fingerprint)
            }
            Spacer(minLength: 8)
            if revoking == key.id {
                ProgressView().controlSize(.small)
            } else {
                Button("Revocar", role: .destructive) { pendingRevocation = key }
                    .disabled(revoking != nil)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func title(for key: AuthorizedDeviceKey) -> String {
        guard let date = key.authorizedOn else { return "Dispositivo (fecha desconocida)" }
        return "Autorizado el \(date.formatted(date: .long, time: .omitted))"
    }

    // MARK: - Acciones

    private func load() async {
        phase = .loading
        do {
            phase = .loaded(try await service.listAuthorizedDeviceKeys())
        } catch {
            Log.ssh.error("No se pudieron listar los dispositivos autorizados: \(error.userMessage, privacy: .public)")
            phase = .failed(error.userMessage)
        }
    }

    private func revoke(_ key: AuthorizedDeviceKey) async {
        revoking = key.id
        revokeError = nil
        defer { revoking = nil }
        do {
            try await service.revokeKey(comment: key.comment)
            Log.ssh.notice("Clave de dispositivo revocada: \(key.comment, privacy: .public)")
        } catch {
            Log.ssh.error("No se pudo revocar \(key.comment, privacy: .public): \(error.userMessage, privacy: .public)")
            revokeError = "No se pudo revocar: \(error.userMessage)"
        }
        await load()
    }
}
