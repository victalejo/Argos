//
//  SendCommandSheet.swift
//  Argos
//
//  Envío de un comando (vía `tmux send-keys`) a una o varias sesiones a la vez
//  (broadcast), p. ej. `git pull` a backend+frontend, sin teclear en cada PTY.
//

import SwiftUI

/// Una sesión candidata a recibir un comando. Lleva su propio servicio SSH porque cada
/// servidor tiene el suyo.
struct BroadcastTarget: Identifiable {
    let handle: SessionHandle
    let serverName: String
    let sessionName: String
    let service: any SSHServicing
    var id: SessionHandle { handle }
}

struct SendCommandSheet: View {
    let targets: [BroadcastTarget]
    /// Sesiones marcadas al abrir (normalmente la sesión activa o sobre la que se invocó).
    let initialSelection: Set<SessionHandle>
    let onClose: () -> Void

    @State private var command = ""
    @State private var appendEnter = true
    @State private var selected: Set<SessionHandle> = []
    @State private var isSending = false
    @FocusState private var commandFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            commandField
            Divider()
            targetList
            Divider()
            footer
        }
        .frame(width: 540, height: 480)
        .onAppear {
            selected = initialSelection
            commandFocused = true
        }
    }

    // MARK: - Secciones

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "paperplane.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Enviar comando").font(.headline)
                Text("Se teclea en el panel activo de cada sesión seleccionada.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }

    private var commandField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Comando a ejecutar (p. ej. git pull)", text: $command)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($commandFocused)
                .onSubmit(send)
            Toggle("Pulsar Enter al final (ejecutar)", isOn: $appendEnter)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
        .padding(14)
    }

    private var targetList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sesiones").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Todas") { selected = Set(targets.map(\.handle)) }
                    .buttonStyle(.borderless).font(.caption)
                Button("Ninguna") { selected.removeAll() }
                    .buttonStyle(.borderless).font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            if targets.isEmpty {
                ContentUnavailableView("Sin sesiones cargadas", systemImage: "moon.zzz")
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(groupedTargets, id: \.server) { group in
                        Section(group.server) {
                            ForEach(group.items) { target in
                                Toggle(isOn: binding(for: target.handle)) {
                                    Text(target.sessionName)
                                        .font(.system(.body, design: .monospaced))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(selected.count) de \(targets.count) seleccionadas")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancelar", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button("Enviar", action: send)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
        }
        .padding(14)
    }

    // MARK: - Lógica

    private var canSend: Bool {
        !command.trimmingCharacters(in: .whitespaces).isEmpty && !selected.isEmpty && !isSending
    }

    /// Agrupa los destinos por servidor preservando el orden (la lista llega ya ordenada).
    private var groupedTargets: [(server: String, items: [BroadcastTarget])] {
        var result: [(String, [BroadcastTarget])] = []
        for target in targets {
            if result.last?.0 == target.serverName {
                result[result.count - 1].1.append(target)
            } else {
                result.append((target.serverName, [target]))
            }
        }
        return result
    }

    private func binding(for handle: SessionHandle) -> Binding<Bool> {
        Binding(
            get: { selected.contains(handle) },
            set: { isOn in
                if isOn { selected.insert(handle) } else { selected.remove(handle) }
            }
        )
    }

    private func send() {
        guard canSend else { return }
        let chosen = targets.filter { selected.contains($0.handle) }
        let keys = command
        let enter = appendEnter
        isSending = true
        Task {
            await withTaskGroup(of: Void.self) { group in
                for target in chosen {
                    let service = target.service
                    let name = target.sessionName
                    group.addTask {
                        try? await service.sendKeys(session: name, keys: keys, enter: enter)
                    }
                }
            }
            isSending = false
            onClose()
        }
    }
}
