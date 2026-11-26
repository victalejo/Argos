//
//  ServerSidebar.swift
//  Argos
//
//  Columna 1: los servidores (con su estado de conexión), sus acciones y los botones de
//  añadir, importar de ~/.ssh/config y cambiar de sesión (⌘K).
//

import SwiftUI

/// Lo que se pide desde la barra lateral (lo resuelve `ContentView` con sus hojas).
enum ServerSidebarRequest {
    case add
    case importSSHConfig
    case edit(Server)
    case transfer(Server)
    case devices(Server)
    case claudeHooks(Server)
    case claudeLimits(Server)
    case doctor(Server)
    case forgetHostKey(Server)
    case delete(Server)
}

struct ServerSidebar: View {
    @Bindable var model: ArgosAppModel
    let onRequest: (ServerSidebarRequest) -> Void

    @State private var quickSwitcher = QuickSwitcher.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 16)
            serverList
            actions
        }
        .background(ArgosTheme.canvas.opacity(0.6))
        .navigationTitle("Argos")
        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 320)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                WorkspaceIcon(symbol: "square.stack.3d.up.fill", size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Argos").font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("Tu espacio de trabajo remoto")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("SERVIDORES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.3)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.store.servers.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.primary.opacity(0.05), in: Capsule())
            }
        }
        .padding(16)
    }

    private var serverList: some View {
        List(selection: $model.selectedServerID) {
            ForEach(model.store.servers) { server in
                HStack(spacing: 2) {
                    ServerRow(server: server, connectionState: model.vms[server.id]?.state)
                    Menu {
                        serverActions(for: server)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 22, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Opciones de \(server.name)")
                    .accessibilityLabel("Opciones del servidor \(server.name)")
                }
                .tag(server.id)
                .contextMenu { serverActions(for: server) }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay {
            if model.store.servers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack").font(.title2).foregroundStyle(.tertiary)
                    Text("Tus servidores aparecerán aquí")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(20)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func serverActions(for server: Server) -> some View {
        let connected = model.vms[server.id] != nil
        Button("Editar servidor…", systemImage: "pencil") { onRequest(.edit(server)) }
        Divider()
        Button("Enviar al iPhone…", systemImage: "qrcode") { onRequest(.transfer(server)) }
            .disabled(!connected)
            .help("Muestra un QR para añadir este servidor en Argos para iPhone/iPad")
        Button("Dispositivos autorizados…", systemImage: "lock.iphone") { onRequest(.devices(server)) }
            .disabled(!connected)
            .help("Ver y revocar los iPhone/iPad con acceso a este servidor")
        Button("Activar indicador de Claude Code…") { onRequest(.claudeHooks(server)) }
            .disabled(!connected)
        Button("Uso y límites de Claude…", systemImage: "gauge.with.dots.needle.33percent") { onRequest(.claudeLimits(server)) }
            .disabled(!connected)
            .help("Tokens y coste por proyecto y día, y cuánto llevas de la ventana de 5 h y de la semanal")
        Button("Doctor del servidor…", systemImage: "stethoscope") { onRequest(.doctor(server)) }
            .disabled(!connected)
            .help("Comprueba tmux, Claude Code, git y la conexión con este servidor")
        Divider()
        Button("Olvidar host key…") { onRequest(.forgetHostKey(server)) }
        Divider()
        Button("Eliminar servidor…", role: .destructive) { onRequest(.delete(server)) }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button { onRequest(.add) } label: {
                Label("Añadir servidor", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button { onRequest(.importSSHConfig) } label: {
                Label("Importar configuración SSH", systemImage: "square.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .help("Importar servidores de ~/.ssh/config")
            Divider().padding(.vertical, 3)
            Button { quickSwitcher.present() } label: {
                HStack {
                    Label("Cambiar de sesión", systemImage: "magnifyingglass")
                        .font(.caption)
                    Spacer(minLength: 2)
                    KeyboardHint(keys: "⌘ K")
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Buscar una sesión en todos tus servidores (⌘K)")
        }
        .padding(14)
        .background(.bar)
    }
}

// MARK: - Fila de servidor

struct ServerRow: View {
    let server: Server
    var connectionState: SessionsLoadState? = nil

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .font(.system(size: 17, weight: .medium))
                .frame(width: 36, height: 36)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(accessibilityStateText.capitalized)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .help("\(server.username)@\(server.host):\(String(server.port))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(server.name), \(server.username) en \(server.host) puerto \(String(server.port)), \(accessibilityStateText)")
    }

    /// Estado de conexión en texto, para VoiceOver (refuerza el color del icono).
    private var accessibilityStateText: String {
        switch connectionState {
        case .failed: return String(localized: "error de conexión")
        case .hostKeyChanged: return String(localized: "identidad del servidor cambiada")
        case .tmuxMissing: return String(localized: "tmux no instalado")
        case .loaded: return String(localized: "conectado")
        case .idle, nil: return String(localized: "sin conectar")
        case .some: return String(localized: "conectando")
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch connectionState {
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .hostKeyChanged:
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red)
        case .tmuxMissing:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .loaded:
            Image(systemName: "server.rack").foregroundStyle(.green)
        case .idle, nil:
            Image(systemName: "server.rack").foregroundStyle(.secondary)
        case .some:
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
        }
    }
}

#if DEBUG
#Preview("Fila de servidor") {
    List {
        ServerRow(server: Server(name: "dev", host: "dev.example.com", port: 2222, username: "dev", privateKeyPath: "~/.ssh/id_ed25519"))
        ServerRow(server: Server(name: "prod", host: "prod.example.com", port: 22, username: "deploy", privateKeyPath: "~/.ssh/id_ed25519"), connectionState: .failed("Timeout"))
    }
    .frame(width: 240, height: 160)
}
#endif
