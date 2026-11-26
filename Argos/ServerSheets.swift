//
//  ServerSheets.swift
//  Argos
//
//  Hojas y confirmaciones de los servidores: formulario, importar de ~/.ssh/config,
//  enviar al iPhone, dispositivos autorizados, Doctor; eliminar, olvidar host key e
//  indicador de Claude Code.
//

import SwiftUI

/// Hojas de servidor.
struct ServerSheets: ViewModifier {
    @Bindable var model: ArgosAppModel
    @Binding var serverFormMode: ServerFormSheet.Mode?
    @Binding var transferServer: ServerSheetTarget?
    @Binding var devicesServer: ServerSheetTarget?
    @Binding var claudeLimitsServer: ServerSheetTarget?
    @Binding var showSSHConfig: Bool
    @Binding var saveError: String?

    func body(content: Content) -> some View {
        content
            .sheet(item: $serverFormMode) { mode in
                // El error (Llavero, servidor borrado en otro dispositivo) se muestra en el
                // propio formulario, que solo se cierra si el guardado sale bien.
                ServerFormSheet(mode: mode) { server, secret in
                    try model.save(server, secret: secret, isNew: mode.isAdd)
                }
            }
            .sheet(item: $transferServer) { target in
                ServerTransferSheet(server: target.server, service: target.service) { transferServer = nil }
            }
            .sheet(item: $devicesServer) { target in
                AuthorizedDevicesSheet(server: target.server, service: target.service) { devicesServer = nil }
            }
            .sheet(item: $claudeLimitsServer) { target in
                ClaudeLimitsSheet(target: target, model: model) { claudeLimitsServer = nil }
            }
            .sheet(item: $model.doctorTarget) { target in
                DoctorSheet(service: target.service, serverName: target.server.name, knownServers: model.store.servers)
            }
            .sheet(isPresented: $showSSHConfig) {
                SSHConfigSheet(
                    existingServers: model.store.servers,
                    onImport: { host in
                        do {
                            try model.importHost(host)
                        } catch {
                            Log.store.error("Importar servidor: \(error.userMessage, privacy: .public)")
                            saveError = String(localized: "No se importó «\(host.alias)»: \(error.userMessage)")
                        }
                    },
                    onClose: { showSSHConfig = false }
                )
            }
            .onChange(of: model.connectionEpochs) { old, new in closeStaleSheets(old: old, new: new) }
    }

    /// Cierra las hojas cuyo servidor se borró o cambió de conexión: su servicio está
    /// retirado y guardar el formulario resucitaría un servidor borrado en otro dispositivo.
    private func closeStaleSheets(old: [Server.ID: Int], new: [Server.ID: Int]) {
        func changed(_ id: Server.ID) -> Bool { old[id] != new[id] }
        if let target = transferServer, changed(target.id) { transferServer = nil }
        if let target = devicesServer, changed(target.id) { devicesServer = nil }
        if let target = claudeLimitsServer, changed(target.id) { claudeLimitsServer = nil }
        if let target = model.doctorTarget, changed(target.id) { model.doctorTarget = nil }
        if case .edit(let server) = serverFormMode, model.store.server(withID: server.id) == nil {
            serverFormMode = nil
        }
    }
}

/// Confirmaciones y alertas de servidor.
struct ServerDialogs: ViewModifier {
    let model: ArgosAppModel
    @Binding var serverToDelete: Server?
    @Binding var hostKeyToForget: Server?
    @Binding var claudeHooksServer: Server?
    @Binding var claudeHooksResult: String?
    @Binding var saveError: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                serverToDelete.map { "¿Eliminar el servidor '\($0.name)'?" } ?? "",
                isPresented: presence($serverToDelete),
                titleVisibility: .visible,
                presenting: serverToDelete
            ) { server in
                Button("Eliminar", role: .destructive) { model.delete(server) }
                Button("Cancelar", role: .cancel) {}
            } message: { _ in
                Text("Se borrará su configuración y su passphrase del Keychain. No afecta al servidor remoto.")
            }
            .confirmationDialog(
                hostKeyToForget.map { "¿Olvidar la host key de '\($0.name)'?" } ?? "",
                isPresented: presence($hostKeyToForget),
                titleVisibility: .visible,
                presenting: hostKeyToForget
            ) { server in
                Button("Olvidar y reconectar", role: .destructive) { model.forgetHostKey(of: server) }
                Button("Cancelar", role: .cancel) {}
            } message: { server in
                Text(String(localized: "Argos confiará en la huella que presente \(server.host) en la próxima conexión. Hazlo solo si sabes que el servidor se reinstaló o cambió de clave: si no, podría tratarse de un ataque (alguien suplantando al servidor)."))
            }
            .confirmationDialog(
                claudeHooksServer.map { "¿Activar el indicador de Claude Code en '\($0.name)'?" } ?? "",
                isPresented: presence($claudeHooksServer),
                titleVisibility: .visible,
                presenting: claudeHooksServer
            ) { server in
                Button("Activar") { installClaudeHooks(on: server) }
                Button("Cancelar", role: .cancel) {}
            } message: { _ in
                Text(String(localized: "Se añadirán hooks a ~/.claude/settings.json del servidor (con copia en settings.json.argos-backup; tus hooks actuales se conservan). Avisan a Argos cuando Claude trabaja, termina o espera tu respuesta. Las sesiones de Claude ya abiertas deben reiniciarse para usarlos."))
            }
            .alert("Indicador de Claude Code", isPresented: presence($claudeHooksResult), presenting: claudeHooksResult) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .alert("No se pudo importar el servidor", isPresented: presence($saveError), presenting: saveError) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }

    private func presence<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    private func installClaudeHooks(on server: Server) {
        guard let vm = model.vms[server.id] else { return }
        Task {
            do {
                if try await vm.service.claudeHooksInstalled() {
                    claudeHooksResult = String(localized: "El indicador ya estaba activo en \(server.name).")
                    return
                }
                try await vm.service.installClaudeHooks()
                claudeHooksResult = String(localized: "Indicador activado en \(server.name). Reinicia las sesiones de Claude Code que ya estuvieran abiertas para que empiecen a reportar su estado.")
            } catch {
                Log.ssh.error("Instalar hooks de Claude: \(error.userMessage, privacy: .public)")
                claudeHooksResult = String(localized: "No se pudo activar el indicador: \(error.userMessage)")
            }
        }
    }
}
