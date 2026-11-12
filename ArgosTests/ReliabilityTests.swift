//
//  ReliabilityTests.swift
//  ArgosTests
//
//  Casos en los que un fallo de lectura o de red NO debe tomarse por «vacío» ni por
//  «hecho»: lista de servidores ilegible con iCloud, registro de huellas dañado, lectura
//  remota fallida, refresco de sesiones y respuesta a un permiso que no llegó.
//

import Foundation
import Testing
@testable import Argos

private final class MemoryCloud: CloudKeyValueStore {
    var values: [String: Data] = [:]
    func data(forKey key: String) -> Data? { values[key] }
    func setData(_ data: Data?, forKey key: String) { values[key] = data }
    func synchronize() -> Bool { true }
}

private func temporaryFolder() -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argos-reliability-\(UUID())")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@MainActor
@Suite("iCloud con datos locales ilegibles")
struct CloudSyncUnreadableLocalTests {

    private func sync(_ cloud: MemoryCloud, in dir: URL) -> (store: ServerStore, sync: CloudServerSync) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ServerStore(storeURL: dir.appendingPathComponent("servers.json"))
        let sync = CloudServerSync(
            store: store, cloud: cloud,
            defaults: UserDefaults(suiteName: "argos.tests.reliability.\(UUID())")!,
            stateURL: dir.appendingPathComponent("icloud-sync.json"),
            knownHostsURL: dir.appendingPathComponent("known_hosts.json")
        )
        return (store, sync)
    }

    private let prod = Server(name: "producción", host: "srv.example", username: "ana", privateKeyPath: "~/.ssh/id_ed25519")

    @Test("servers.json corrupto NO borra los servidores de los demás dispositivos")
    func corruptListAdoptsCloudInsteadOfDeleting() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = MemoryCloud()
        let macDir = folder.appendingPathComponent("mac"), phoneDir = folder.appendingPathComponent("iphone")

        var mac = sync(cloud, in: macDir)
        mac.store.add(prod)
        mac.sync.start()
        let phone = sync(cloud, in: phoneDir)
        phone.sync.start()
        #expect(phone.store.servers.map(\.name) == ["producción"])

        // El Mac arranca con servers.json dañado.
        try Data("{ roto".utf8).write(to: macDir.appendingPathComponent("servers.json"))
        mac = sync(cloud, in: macDir)
        #expect(mac.store.loadOutcome == .unreadable)
        mac.sync.start()

        // Recupera su lista de iCloud y el iPhone conserva la suya.
        #expect(mac.store.servers.map(\.name) == ["producción"])
        var removedOnPhone = 0
        phone.sync.onRemoteRemoval = { _ in removedOnPhone += 1 }
        phone.sync.sync()
        #expect(phone.store.servers.map(\.name) == ["producción"])
        #expect(removedOnPhone == 0)
    }

    @Test("servers.json desaparecido tampoco publica borrados")
    func missingListAdoptsCloud() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = MemoryCloud()
        let macDir = folder.appendingPathComponent("mac")

        var mac = sync(cloud, in: macDir)
        mac.store.add(prod)
        mac.sync.start()
        try FileManager.default.removeItem(at: macDir.appendingPathComponent("servers.json"))

        mac = sync(cloud, in: macDir)
        mac.sync.start()
        #expect(mac.store.servers.map(\.name) == ["producción"])
    }

    @Test("Vaciar la lista a propósito sí se propaga")
    func deliberateRemovalStillPropagates() {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = MemoryCloud()
        let macDir = folder.appendingPathComponent("mac"), phoneDir = folder.appendingPathComponent("iphone")

        var mac = sync(cloud, in: macDir)
        mac.store.add(prod)
        mac.sync.start()
        let phone = sync(cloud, in: phoneDir)
        phone.sync.start()

        mac.store.remove(mac.store.servers[0])
        mac.sync.sync()
        // Relanzar con la lista vacía (pero legible) no la resucita.
        mac = sync(cloud, in: macDir)
        #expect(mac.store.loadOutcome == .loaded)
        mac.sync.start()
        phone.sync.sync()
        #expect(mac.store.servers.isEmpty)
        #expect(phone.store.servers.isEmpty)
    }

    @Test("Con el registro de huellas dañado no se sincroniza (no se propagan olvidos)")
    func corruptKnownHostsSkipsSync() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cloud = MemoryCloud()
        let macDir = folder.appendingPathComponent("mac")
        let hosts = macDir.appendingPathComponent("known_hosts.json")

        let mac = sync(cloud, in: macDir)
        TOFUHostKeyValidator.trust(["srv:22": "SHA256:buena"], storeURL: hosts)
        mac.sync.start()
        let published = try #require(cloud.values[CloudServerSync.documentKey])

        try Data("no es json".utf8).write(to: hosts)
        mac.sync.sync()
        #expect(cloud.values[CloudServerSync.documentKey] == published)
    }
}

@Suite("Registro de huellas dañado")
struct CorruptKnownHostsTests {

    private func corruptStore() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("argos-knownhosts-\(UUID()).json")
        try Data("{ roto".utf8).write(to: url)
        return url
    }

    private func cleanUp(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasPrefix(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    @Test("No se lee como vacío ni se le añaden huellas")
    func failsClosed() throws {
        let url = try corruptStore()
        defer { cleanUp(url) }
        #expect(!TOFUHostKeyValidator.isReadable(storeURL: url))
        #expect(!TOFUHostKeyValidator.isTrusted(host: "srv", port: 22, storeURL: url))
        #expect(!TOFUHostKeyValidator.trustIfUnknown(fingerprint: "SHA256:x", host: "srv", port: 22, storeURL: url))
        TOFUHostKeyValidator.trust(["srv:22": "SHA256:x"], storeURL: url)
        // Una limpieza automática (deshacer una prueba de conexión) tampoco lo reinicia.
        TOFUHostKeyValidator.forget(host: "srv", port: 22, storeURL: url)
        // Sigue intacto: nadie lo sobrescribió con un registro «nuevo».
        #expect(try Data(contentsOf: url) == Data("{ roto".utf8))
    }

    @Test("«Olvidar host key» lo aparta y deja empezar un registro nuevo")
    func forgetQuarantines() throws {
        let url = try corruptStore()
        defer { cleanUp(url) }
        TOFUHostKeyValidator.forgetExplicitly(host: "srv", port: 22, storeURL: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(TOFUHostKeyValidator.isReadable(storeURL: url))
        let dir = url.deletingLastPathComponent()
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(url.lastPathComponent + ".corrupt-") }
        #expect(backups.count == 1)
    }

    @Test("Con el registro sano, la acción explícita solo olvida ese servidor")
    func explicitForgetOnHealthyStore() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("argos-knownhosts-\(UUID()).json")
        defer { cleanUp(url) }
        TOFUHostKeyValidator.trust(["a:22": "SHA256:a", "b:22": "SHA256:b"], storeURL: url)
        TOFUHostKeyValidator.forgetExplicitly(host: "a", port: 22, storeURL: url)
        #expect(TOFUHostKeyValidator.allTrusted(storeURL: url) == ["b:22": "SHA256:b"])
    }

    @Test("Un registro inexistente es el primer uso, no un error")
    func missingIsEmpty() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("argos-knownhosts-\(UUID()).json")
        #expect(TOFUHostKeyValidator.isReadable(storeURL: url))
        #expect(TOFUHostKeyValidator.allTrusted(storeURL: url).isEmpty)
    }
}

@Suite("Lectura de archivos remotos")
struct ReadHomeFileCommandTests {

    /// Ejecuta el comando real con `sh` y un `$HOME` de prueba.
    private func run(_ relativePath: String, home: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SSHService.readHomeFileCommand(relativePath)]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test("Inexistente: éxito sin salida. Presente: su contenido. Ilegible: error")
    func distinguishesMissingFromUnreadable() throws {
        let home = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: home) }

        let missing = try run(".config/argos/projects.json", home: home)
        #expect(missing.status == 0 && missing.output.isEmpty)

        let file = home.appendingPathComponent("projects.json")
        try Data(#"{"projects":[]}"#.utf8).write(to: file)
        let present = try run("projects.json", home: home)
        #expect(present.status == 0 && present.output == #"{"projects":[]}"#)

        // Existe pero `cat` falla (aquí, un directorio): NO debe parecer «no existe».
        try FileManager.default.createDirectory(at: home.appendingPathComponent("carpeta"), withIntermediateDirectories: true)
        let unreadable = try run("carpeta", home: home)
        #expect(unreadable.status != 0)

        // Un enlace roto tampoco es «no existe»: escribir encima rompería el enlace.
        try FileManager.default.createSymbolicLink(
            atPath: home.appendingPathComponent("enlace").path, withDestinationPath: "/no/existe"
        )
        #expect(try run("enlace", home: home).status != 0)
    }
}

@Suite("TmuxSession: nombres con '|'")
struct TmuxSessionPipeNameTests {
    @Test("Una sesión creada fuera de Argos con '|' en el nombre no desaparece")
    func pipeInName() throws {
        let session = try #require(TmuxSession(line: "api|v2|3|1|1700000000"))
        #expect(session.name == "api|v2")
        #expect(session.windowCount == 3)
        #expect(session.isAttached)
    }
}

@MainActor
@Suite("SessionsViewModel: refresco sin vaciar la lista")
struct SessionsViewModelRefreshTests {

    private func session(_ name: String, windows: Int = 1) -> TmuxSession {
        TmuxSession(name: name, windowCount: windows, isAttached: false, createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test("refresh con lista cargada no pasa por .loading")
    func refreshKeepsListVisible() async {
        let mock = MockSSHService()
        mock.sessions = [session("main")]
        let vm = SessionsViewModel(service: mock)
        await vm.load()

        // Observa el estado en mitad del refresco (cuando el servicio lista).
        var sawEmptyList = false
        mock.onListSessions = { sawEmptyList = vm.sessions.isEmpty }
        mock.sessions = [session("main"), session("deploy")]
        await vm.refresh()

        #expect(!sawEmptyList)
        #expect(vm.sessions.map(\.name) == ["main", "deploy"])
        #expect(!vm.isRefreshing)
    }

    @Test("El sondeo recoge lo que cambió fuera y no rompe la lista si falla")
    func quietRefresh() async {
        let mock = MockSSHService()
        mock.sessions = [session("main")]
        let vm = SessionsViewModel(service: mock)
        await vm.load()

        mock.sessions = []   // cerrada desde otro cliente
        await vm.refreshSessionsQuietly()
        #expect(vm.sessions.isEmpty)

        mock.sessions = [session("nueva")]
        await vm.refreshSessionsQuietly()
        #expect(vm.sessions.map(\.name) == ["nueva"])

        mock.listError = SSHService.SSHServiceError.commandFailed(exitCode: 1, message: "red")
        await vm.refreshSessionsQuietly()
        #expect(vm.sessions.map(\.name) == ["nueva"])
    }

    @Test("El sondeo no arranca nada si la lista aún no está cargada")
    func quietRefreshNeedsLoadedList() async {
        let mock = MockSSHService()
        mock.sessions = [session("main")]
        let vm = SessionsViewModel(service: mock)
        await vm.refreshSessionsQuietly()
        if case .idle = vm.state {} else { Issue.record("Esperaba .idle, fue \(vm.state)") }
    }
}

@Suite("Agente persistente: respuesta que no llega")
struct PersistentAgentUndeliveredTests {

    @MainActor
    @Test("Si el envío falla, el permiso pendiente sigue ahí para reintentar")
    func permissionStaysWhenSendFails() async throws {
        let mock = MockSSHService()
        mock.agentScript = [
            #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}"#,
        ]
        let info = PersistentAgentInfo(
            id: "6a55640d-ac70-41ab-8426-6eb72d4fb5eb", isAlive: true, logBytes: 0,
            meta: PersistentAgentMeta(workingDirectory: "/srv", title: "srv", createdAt: Date())
        )
        let session = PersistentAgentSession(service: mock, info: info)
        session.attach()
        for _ in 0..<100 where session.state.pendingPermission == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(session.state.pendingPermission?.id == "r1")

        struct Offline: Error {}
        mock.agentScriptOutput = { _ in throw Offline() }
        await session.allowPendingPermission()
        #expect(session.state.pendingPermission?.id == "r1")
        #expect(session.lastError != nil)

        mock.agentScriptOutput = { _ in "" }
        await session.allowPendingPermission()
        #expect(session.state.pendingPermission == nil)
        session.detach()
    }
}

@Suite("Deadline")
struct DeadlineTests {

    @Test("Devuelve el resultado si llega a tiempo")
    func inTime() async {
        #expect(await Deadline.succeeds(within: .seconds(5)) { true })
        #expect(await Deadline.succeeds(within: .seconds(5)) { false } == false)
    }

    @Test("No espera a una comprobación que no atiende la cancelación")
    func doesNotWaitForStuckWork() async {
        let clock = ContinuousClock()
        let start = clock.now
        let alive = await Deadline.succeeds(within: .milliseconds(100)) {
            // Como una conexión medio abierta: ignora la cancelación.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { continuation.resume() }
            }
            return true
        }
        #expect(!alive)
        #expect(clock.now - start < .seconds(2))
    }
}

@Suite("Destino de una notificación")
struct NotificationRouteTests {

    @Test("Viaja en el userInfo y vuelve igual")
    func roundTrip() {
        let route = NotificationRoute(serverID: UUID(), session: "api|v2", window: 3)
        #expect(NotificationRoute(userInfo: route.userInfo) == route)
        let serverOnly = NotificationRoute(serverID: UUID())
        #expect(NotificationRoute(userInfo: serverOnly.userInfo) == serverOnly)
    }

    @Test("Un userInfo ajeno o con un id inválido no produce destino")
    func rejectsForeignPayloads() {
        #expect(NotificationRoute(userInfo: [:]) == nil)
        #expect(NotificationRoute(userInfo: ["argos.serverID": "no-es-uuid"]) == nil)
        #expect(NotificationRoute(userInfo: ["argos.serverID": 42]) == nil)
        // Sesión vacía o ventana con tipo equivocado: se ignoran, el servidor vale.
        let id = UUID()
        let loose = NotificationRoute(userInfo: ["argos.serverID": id.uuidString, "argos.session": "", "argos.window": "3"])
        #expect(loose == NotificationRoute(serverID: id))
    }
}

@MainActor
@Suite("Estado de Claude: referencia y persistencia")
struct ClaudeActivityBaselineTests {

    private func pane(_ activity: ClaudeActivity, window: Int = 1) -> ClaudePaneActivity {
        ClaudePaneActivity(paneID: "%\(window)", session: "api", window: window, activity: activity, isQuiet: false)
    }

    @Test("El snapshot se guarda y se recupera igual (se persiste entre refrescos en segundo plano)")
    func snapshotIsCodable() throws {
        let snapshot = ClaudeActivitySnapshot(panes: [pane(.working), pane(.waiting, window: 2)])
        let data = try JSONEncoder().encode(["srv": snapshot])
        #expect(try JSONDecoder().decode([String: ClaudeActivitySnapshot].self, from: data) == ["srv": snapshot])
    }

    @Test("Lo ya avisado en segundo plano no se avisa otra vez al volver")
    func adoptedBaselineIsNotAnnouncedAgain() async {
        let mock = MockSSHService()
        mock.sessions = [TmuxSession(name: "api", windowCount: 1, isAttached: false, createdAt: Date(timeIntervalSince1970: 0))]
        let vm = SessionsViewModel(service: mock)
        await vm.load()
        mock.claudeSnapshot = ClaudeActivitySnapshot(panes: [pane(.working)])
        _ = await vm.refreshClaudeActivity()   // primer sondeo: referencia

        // En segundo plano terminó y ya se avisó: esa es la nueva referencia.
        let done = ClaudeActivitySnapshot(panes: [pane(.done)])
        vm.adoptClaudeActivityBaseline(done)
        mock.claudeSnapshot = done
        #expect(await vm.refreshClaudeActivity().isEmpty)

        // Un cambio posterior sí se avisa.
        mock.claudeSnapshot = ClaudeActivitySnapshot(panes: [pane(.waiting)])
        #expect(await vm.refreshClaudeActivity() == [ClaudeTransition(session: "api", window: 1, activity: .waiting)])
    }
}

@Suite("Autenticación sin contraseña")
struct MissingPasswordTests {

    @Test("Sin contraseña guardada no se intenta el login (ni se toca la red)")
    func missingPasswordFailsBeforeConnecting() async {
        // Host inválido a propósito: si llegara a conectar, el error sería de red.
        let server = Server(name: "x", host: "host.invalid", port: 22, username: "u", authMethod: .password, privateKeyPath: "")
        for password in [nil, ""] as [String?] {
            let service = SSHService(configuration: SSHService.Configuration(server: server, password: password))
            await #expect(throws: SSHService.SSHServiceError.self) { _ = try await service.listSessions() }
        }
    }
}
