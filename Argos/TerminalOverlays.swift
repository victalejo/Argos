//
//  TerminalOverlays.swift
//  Argos
//
//  Lo que se pinta encima del terminal: pantalla de conexión, banners de desconexión,
//  reconexión y error, aviso de fallo de una acción de ventana/panel y el indicador de
//  subida.
//

import SwiftUI

/// Capa de estado del terminal según su conexión y la reconexión automática.
struct TerminalStatusOverlay: View {
    let status: LiveTerminalStatus
    let sessionName: String
    let reconnect: TerminalReconnectScheduler
    let onReconnect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch status {
        case .connecting:
            TerminalConnectionProgress(title: "Conectando a la sesión", sessionName: sessionName)
                .transition(.opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.25)))
        case .connected:
            EmptyView()
        case .ended:
            TerminalBanner(
                icon: "bolt.horizontal.circle",
                tint: .secondary,
                title: "Sesión desconectada",
                message: "Se cerró la conexión con la sesión. Si sigue abierta en el servidor, reconecta para continuar.",
                action: ("Reconectar", onReconnect)
            )
        case .failed(let message):
            if reconnect.isReconnecting {
                TerminalBanner(
                    icon: nil,
                    tint: .secondary,
                    title: "Reconectando… (intento \(reconnect.attempt + 1) de \(reconnect.policy.maxAttempts))",
                    message: "Se perdió la conexión. Reintentando automáticamente.",
                    action: nil
                )
            } else {
                TerminalBanner(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: reconnect.gaveUp == .needsUserAction ? "Hace falta que revises la conexión" : "No se pudo abrir el terminal",
                    message: message,
                    action: ("Reconectar", onReconnect)
                )
            }
        }
    }
}

/// Pantalla de carga (antes del controlador o mientras conecta).
struct TerminalConnectionProgress: View {
    let title: String
    let sessionName: String

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 22) {
                Image(systemName: "terminal")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 76, height: 76)
                    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 22))
                VStack(spacing: 8) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(sessionName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
                ProgressView().controlSize(.small)
                Text("Tu espacio de trabajo estará listo en un momento.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(28)
        }
    }
}

/// Banner inferior con acción opcional (sin icono = spinner).
struct TerminalBanner: View {
    let icon: String?
    let tint: Color
    let title: String
    let message: String
    let action: (title: String, run: () -> Void)?

    var body: some View {
        VStack {
            Spacer()
            HStack(alignment: .top, spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                        .font(.title3)
                } else {
                    ProgressView().controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let action {
                    Button(action.title, action: action.run)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.18)))
            .shadow(color: .black.opacity(0.08), radius: 16, y: 5)
            .padding(16)
        }
    }
}

/// Fallo de una acción de ventana o panel (dividir, cerrar, cambiar de ventana…).
struct TerminalActionErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Cerrar", action: onDismiss)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.25)))
            .padding(12)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

/// «Subiendo al servidor…» (imagen pegada o archivos soltados).
struct TerminalUploadIndicator: View {
    var body: some View {
        VStack {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Subiendo al servidor…").font(.callout)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 12)
            Spacer()
        }
    }
}
