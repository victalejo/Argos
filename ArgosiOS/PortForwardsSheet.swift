//
//  PortForwardsSheet.swift
//  ArgosiOS
//
//  Hoja «Puertos» en iPhone/iPad: reenvía un puerto del servidor a este dispositivo y
//  abre la web DENTRO de la app (SFSafariViewController). Abrirla en Safari mandaría
//  Argos a segundo plano e iOS cortaría el túnel.
//

import SafariServices
import SwiftUI

struct PortForwardsSheet: View {
    let serverName: String
    @State private var model: PortForwardsModel
    @State private var manualPort = ""
    @State private var browsing: BrowsingTarget?
    @Environment(\.dismiss) private var dismiss

    init(service: any SSHServicing, serverName: String) {
        self.serverName = serverName
        _model = State(initialValue: PortForwardsModel(service: service))
    }

    var body: some View {
        NavigationStack {
            List {
                if !model.forwards.isEmpty { forwardedSection }
                listeningSection
                manualSection
                idleSection
            }
            .navigationTitle("Puertos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
            .refreshable { await model.refresh() }
            .task {
                await model.refresh()
                await model.pollWhileVisible()
            }
            .alert("No se pudo reenviar", isPresented: errorBinding) {
                Button("Aceptar", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .fullScreenCover(item: $browsing) { target in
                SafariView(url: target.url).ignoresSafeArea()
            }
        }
    }

    private var forwardedSection: some View {
        Section {
            ForEach(model.forwards) { forward in
                Button { open(forward) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(forward.localAddress).font(.body.monospaced())
                            Text(verbatim: forward.isReconnecting
                                 ? "Reconectando con el puerto \(forward.remotePort)…"
                                 : "→ puerto \(forward.remotePort) de \(serverName)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: forward.isReconnecting ? "arrow.triangle.2.circlepath" : "safari")
                    }
                }
                .disabled(forward.isReconnecting)
                .swipeActions {
                    Button(role: .destructive) { Task { await model.stop(forward) } } label: {
                        Label("Cerrar", systemImage: "stop.fill")
                    }
                }
                .contextMenu {
                    Button("Copiar dirección", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = forward.localURL?.absoluteString
                    }
                    Button("Dejar de reenviar", systemImage: "stop.fill", role: .destructive) {
                        Task { await model.stop(forward) }
                    }
                }
            }
        } header: {
            Text("Reenviados")
        } footer: {
            Text("Desliza para cerrar. Los túneles se cortan si Argos pasa a segundo plano.")
        }
    }

    private var listeningSection: some View {
        Section {
            if !model.hasLoaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if let error = model.listError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else if model.visiblePorts.isEmpty {
                Text("No hay servidores de desarrollo escuchando.").foregroundStyle(.secondary)
            } else {
                ForEach(model.visiblePorts) { port in
                    listeningRow(port)
                }
            }
            if model.hiddenSystemPortCount > 0 {
                Toggle("Puertos del sistema (\(model.hiddenSystemPortCount))", isOn: $model.showsSystemPorts)
            }
        } header: {
            Text("En escucha en \(serverName)")
        }
    }

    private func listeningRow(_ port: ListeningPort) -> some View {
        Button {
            Task {
                // `start` devuelve el túnel existente si ya estaba abierto.
                if let forward = await model.start(port) { open(forward) }
            }
        } label: {
            HStack {
                Text(verbatim: String(port.port)).font(.body.monospacedDigit().weight(.medium))
                if let name = port.processName {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busyPorts.contains(port.port) {
                    ProgressView()
                } else {
                    Text(model.forward(forRemotePort: port.port) == nil ? "Reenviar y abrir" : "Abrir")
                        .font(.callout)
                }
            }
        }
        .disabled(model.busyPorts.contains(port.port))
    }

    private var manualSection: some View {
        Section {
            HStack {
                TextField("Otro puerto (p. ej. 8080)", text: $manualPort)
                    .keyboardType(.numberPad)
                Button("Reenviar") {
                    let text = manualPort
                    Task { if await model.startManual(text) != nil { manualPort = "" } }
                }
                .disabled(PortForwardsModel.parsePort(manualPort) == nil)
            }
        }
    }

    private var idleSection: some View {
        Section {
            Picker("Cerrar sin uso tras", selection: $model.idleMinutes) {
                ForEach(PortForwardIdlePolicy.options, id: \.self) { minutes in
                    Text(PortForwardIdlePolicy.label(minutes: minutes)).tag(minutes)
                }
            }
        } footer: {
            Text("Sin uso = ninguna conexión abierta. Claude ve los túneles con la skill «argos-puertos».")
        }
    }

    private func open(_ forward: ActivePortForward) {
        if let url = forward.localURL { browsing = BrowsingTarget(url: url) }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

// MARK: - Solicitudes de Claude

extension View {
    /// Vigila las solicitudes de Claude (`argos-ports open`) del servidor mientras esta vista
    /// está en pantalla y pregunta antes de abrir nada.
    func portForwardRequests(service: any SSHServicing, serverName: String) -> some View {
        modifier(PortForwardRequestsModifier(service: service, serverName: serverName))
    }
}

private struct PortForwardRequestsModifier: ViewModifier {
    let serverName: String
    @State private var requests: PortForwardRequestsModel
    @State private var browsing: BrowsingTarget?

    init(service: any SSHServicing, serverName: String) {
        self.serverName = serverName
        _requests = State(initialValue: PortForwardRequestsModel(service: service))
    }

    func body(content: Content) -> some View {
        content
            .task { await requests.pollWhileVisible() }
            .alert(
                requests.current.map(PortForwardRequestsModel.title(for:)) ?? "",
                isPresented: Binding(get: { requests.current != nil && browsing == nil }, set: { _ in }),
                presenting: requests.current
            ) { _ in
                Button("Abrir") {
                    Task {
                        if let url = await requests.accept() { browsing = BrowsingTarget(url: url) }
                    }
                }
                Button("Ahora no", role: .cancel) { Task { await requests.decline() } }
            } message: { request in
                Text(verbatim: PortForwardRequestPrompt.message(for: request, serverName: serverName))
            }
            .alert("No se pudo abrir el puerto", isPresented: Binding(
                get: { requests.errorMessage != nil },
                set: { if !$0 { requests.errorMessage = nil } }
            )) {
                Button("Aceptar", role: .cancel) {}
            } message: {
                Text(requests.errorMessage ?? "")
            }
            .fullScreenCover(item: $browsing) { target in
                SafariView(url: target.url).ignoresSafeArea()
            }
    }
}

private struct BrowsingTarget: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Navegador dentro de la app (también lo usa `ClaudeLoginSheet`).
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
