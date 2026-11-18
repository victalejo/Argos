//
//  ArgosAppModel+Servers.swift
//  Argos
//
//  Altas, ediciones y bajas de servidores, ⌘R y «Olvidar host key».
//

import Foundation

extension ArgosAppModel {

    /// Guarda un servidor nuevo (`isNew`) o editado. `secret` es la passphrase (clave) o la
    /// contraseña, según `server.authMethod`. Lanza si el Llavero falla o si el servidor
    /// editado se borró entretanto en otro dispositivo: entonces NO se guarda nada.
    ///
    /// Solo rehace la conexión (cerrando sus terminales y agentes) si cambia a dónde o
    /// cómo se conecta; cambiar el nombre no interrumpe nada.
    func save(_ server: Server, secret: String?, isNew: Bool) throws {
        let previous = store.server(withID: server.id)
        if !isNew && previous == nil { throw ServerNoLongerExistsError(name: server.name) }
        let secretChanged = ServerEditImpact.secretChanged(stored: secrets.secret(for: server), new: secret)
        try secrets.store(secret, for: server)
        guard let previous else {
            store.add(server)
            selectedServerID = server.id
            syncVMs()
            if let vm = vms[server.id] { Task { await vm.load() } }
            return
        }
        store.update(server)
        if ServerEditImpact.requiresNewConnection(previous: previous, updated: server, secretChanged: secretChanged) {
            rebuildConnection(for: server)
        }
    }

    /// Servidor de Argos a partir de un host de `~/.ssh/config` (auth por clave; la
    /// passphrase, si la hubiera, se pide al editar).
    func importHost(_ host: SSHConfigHost) throws {
        let server = Server(
            name: host.alias,
            host: host.effectiveHost,
            port: host.port ?? 22,
            username: host.user ?? "",
            authMethod: .key,
            privateKeyPath: host.identityFile ?? "~/.ssh/id_ed25519"
        )
        try save(server, secret: nil, isNew: true)
    }

    func delete(_ server: Server) {
        store.remove(server)
        forgetLocally(server)
    }

    /// Lo propio de este Mac de un servidor que ya no está (conexiones, secretos, selección).
    func forgetLocally(_ server: Server) {
        terminalStore.closeAll(forServer: server.id)
        agentStore.closeAll(forServer: server.id)
        secrets.removeAll(for: server.id)
        syncVMs()
        if selectedServerID == server.id || selectedServerID.flatMap(store.server(withID:)) == nil {
            selectedServerID = store.servers.first?.id
        }
        if let handle = selectedSession, handle.serverID == server.id {
            selectedSession = nil
        }
    }

    /// «Olvidar host key» (ya confirmado): olvida la huella anclada y reconecta, confiando
    /// en la nueva.
    func forgetHostKey(of server: Server) {
        TOFUHostKeyValidator.forgetExplicitly(host: server.host, port: server.port)
        if let vm = vms[server.id] { Task { await vm.load() } }
    }

    /// ⌘R: relee los servidores ya cargados (sin parpadeo ni repetir el arranque de tmux)
    /// y reintenta los que fallaron. Los que aún no se conectaron siguen sin conectar.
    func refreshAll() async {
        let plan = vms.values.map { ($0, RefreshPlan.action(for: $0.state)) }
        await withTaskGroup(of: Void.self) { group in
            for (vm, action) in plan {
                switch action {
                case .refresh: group.addTask { await vm.refresh() }
                case .load: group.addTask { await vm.load() }
                case .skip: break
                }
            }
        }
    }

    /// Abre el Doctor del servidor (desde su menú o desde Ayuda, con el seleccionado).
    /// Antes abre la ventana: con ella cerrada, la hoja aparecía de golpe al reabrirla.
    func presentDoctor(for server: Server? = nil) {
        guard let server = server ?? selectedServerID.flatMap(store.server(withID:)),
              let target = sheetTarget(for: server) else { return }
        showMainWindow()
        doctorTarget = target
    }
}
