//
//  PortForwardsButton.swift
//  Argos
//
//  Botón «Puertos» de la cabecera del detalle: abre el popover para reenviar puertos
//  del servidor a este Mac (p. ej. ver en el navegador la web que el agente levantó en
//  el puerto 3000). Muestra cuántos túneles hay abiertos.
//

import SwiftUI

struct PortForwardsButton: View {
    let service: any SSHServicing
    let serverName: String

    @State private var isPresented = false
    @State private var activeCount = 0

    var body: some View {
        Button { isPresented.toggle() } label: {
            Label(activeCount > 0 ? "Puertos · \(activeCount)" : "Puertos",
                  systemImage: activeCount > 0 ? "network.badge.shield.half.filled" : "network")
        }
        .controlSize(.large)
        .fixedSize()   // nunca «Pu…»: si no cabe, la cabecera pasa a dos filas
        .help("Reenviar puertos del servidor a este Mac")
        .accessibilityLabel(activeCount > 0 ? "Puertos, \(activeCount) reenviados" : "Puertos")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PortForwardsPanel(service: service, serverName: serverName)
        }
        .task(id: isPresented) {
            // El recuento es una consulta local al actor (sin red salvo para reabrir túneles caídos).
            while !Task.isCancelled {
                activeCount = await service.activePortForwards().count
                try? await Task.sleep(for: .seconds(isPresented ? 2 : 10))
            }
        }
    }
}

struct PortForwardsPanel: View {
    let serverName: String
    @State private var model: PortForwardsModel
    @State private var manualPort = ""
    @Environment(\.openURL) private var openURL

    init(service: any SSHServicing, serverName: String) {
        self.serverName = serverName
        _model = State(initialValue: PortForwardsModel(service: service))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.forwards.isEmpty { forwardedSection }
                    listeningSection
                    manualSection
                    idleSection
                }
                .padding(14)
            }
            // Altura fija: un ScrollView en un popover no tiene altura ideal y se encoge.
            .frame(height: 400)
        }
        .frame(width: 380)
        .task {
            await model.refresh()
            await model.pollWhileVisible()
        }
        .alert("No se pudo reenviar", isPresented: errorBinding) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Puertos").font(.headline)
                Text("De \(serverName) a este Mac (solo localhost)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Volver a buscar puertos")
                .accessibilityLabel("Volver a buscar puertos")
        }
        .padding(14)
    }

    // MARK: - Reenviados

    private var forwardedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Reenviados")
            ForEach(model.forwards) { forward in
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.green)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(forward.localAddress).font(.callout.monospaced().weight(.medium))
                        Text(verbatim: "→ puerto \(forward.remotePort) del servidor")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Abrir") { open(forward) }
                    Button { copy(forward.localURL?.absoluteString ?? forward.localAddress) } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copiar dirección")
                    .accessibilityLabel("Copiar dirección")
                    Button(role: .destructive) { Task { await model.stop(forward) } } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Dejar de reenviar")
                    .accessibilityLabel(Text(verbatim: "Dejar de reenviar el puerto \(forward.remotePort)"))
                    .disabled(model.busyPorts.contains(forward.remotePort))
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - En escucha

    @ViewBuilder
    private var listeningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("En escucha en el servidor")
            if !model.hasLoaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else if let error = model.listError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.visiblePorts.isEmpty {
                Text("No hay servidores de desarrollo escuchando. Arranca uno (p. ej. «npm run dev») o escribe el puerto abajo.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.visiblePorts) { port in
                    listeningRow(port)
                }
            }
            if model.hiddenSystemPortCount > 0 {
                Toggle("Mostrar puertos del sistema (\(model.hiddenSystemPortCount))", isOn: $model.showsSystemPorts)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
        }
    }

    private func listeningRow(_ port: ListeningPort) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: String(port.port))
                .font(.callout.monospacedDigit().weight(.medium))
                .frame(minWidth: 48, alignment: .leading)
            Text(port.processName ?? (port.targetHost == "localhost" ? "" : port.targetHost))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if model.busyPorts.contains(port.port) {
                ProgressView().controlSize(.small)
            } else if let forward = model.forward(forRemotePort: port.port) {
                Button("Abrir") { open(forward) }
            } else {
                Button("Reenviar y abrir") {
                    Task { if let forward = await model.start(port) { open(forward) } }
                }
            }
        }
        .controlSize(.small)
    }

    // MARK: - Manual

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Otro puerto")
            HStack {
                TextField("p. ej. 8080", text: $manualPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .onSubmit(startManual)
                Button("Reenviar", action: startManual)
                    .disabled(PortForwardsModel.parsePort(manualPort) == nil)
                Spacer()
            }
            .controlSize(.small)
            Text("Sirve aunque el puerto aún no escuche: el túnel conectará cuando lo haga.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Cierre automático

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Cierre automático")
            Picker("Cerrar los túneles sin uso tras", selection: $model.idleMinutes) {
                ForEach(PortForwardIdlePolicy.options, id: \.self) { minutes in
                    Text(PortForwardIdlePolicy.label(minutes: minutes)).tag(minutes)
                }
            }
            .controlSize(.small)
            Text("Sin uso = ninguna conexión abierta. Claude ve los túneles con la skill «argos-puertos».")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func startManual() {
        let text = manualPort
        Task {
            if await model.startManual(text) != nil { manualPort = "" }
        }
    }

    // MARK: - Utilidades

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }

    private func open(_ forward: ActivePortForward) {
        if let url = forward.localURL { openURL(url) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}
