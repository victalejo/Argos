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
                            Text(verbatim: "→ puerto \(forward.remotePort) de \(serverName)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "safari")
                    }
                }
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

private struct BrowsingTarget: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Navegador dentro de la app.
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
