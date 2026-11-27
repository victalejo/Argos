//
//  ClaudeSchedulesTests.swift
//  ArgosTests
//
//  Tareas programadas: plantillas, configuración, el despachador real (día y hora, proyecto
//  en uso, «ejecutar ahora», tiempo máximo) con un tmux aislado, y la pantalla.
//

import Testing
import Foundation
@testable import Argos

@Suite("Tareas programadas (plantillas)")
struct ClaudeScheduleScriptsTests {

    static func schedule(days: Set<Int> = [1, 2, 3, 4, 5], hour: Int = 3, minute: Int = 0, push: Bool = true) -> ClaudeSchedule {
        ClaudeSchedule(
            id: "abc12345", title: "Tests de la noche", prompt: "Corre los tests y arregla lo que falle",
            projectPath: "/srv/repos/app", session: "app", weekdays: days, hour: hour, minute: minute,
            push: push, checkCommand: "npm test", maxMinutes: 45, permissionMode: .acceptEdits
        )
    }

    @Test func lasPlantillasLlevanHuecosYNuncaLosDatosFijos() throws {
        let files = try ClaudeScheduleScripts.make(Self.schedule(), claudePath: "/usr/local/bin/claude")
        let sentinel = ClaudeScheduleScripts.sentinelAgentID
        #expect(files.launch.contains("\"$ARGOS_META_B64\""), "los datos del agente los pone el despachador")
        #expect(files.launch.contains(sentinel) && files.launch.contains("@@RUN@@"))
        #expect(files.launch.contains("--permission-mode acceptEdits"))
        #expect(files.meta.contains("@@NOW@@") && files.meta.contains("app-prog-abc12345-@@RUN@@"))
        #expect(files.send.contains(sentinel) && files.stop.contains(sentinel))
        #expect(files.task.contains("source=schedule\n") && files.task.contains("title=Tests de la noche\n"))
        #expect(files.task.contains("push=0\n") && files.task.contains("review_push=1\n") && files.task.contains("check=npm test\n") && files.task.contains("max_minutes=45\n"))
        #expect(files.task.contains("branch=argos/prog-abc12345-@@RUN@@\n"))
        #expect(files.config.contains("days=1,2,3,4,5\n") && files.config.contains("time=03:00\n"))
    }

    @Test func laListaSeLeeConSuProyecto() {
        let project = Project(name: "App", path: "/srv/repos/app")
        let config = ClaudeScheduleScripts.configText(Self.schedule(days: [6, 7], hour: 22, minute: 5))
        let output = "@@schedule abc12345\n" + config.split(separator: "\n").map { "config \($0)" }.joined(separator: "\n")
            + "\nlast 1800000000\nprompt Corre los tests\n@@schedule zzz\nconfig project=x\n"
        let list = ClaudeScheduleScripts.parse(listOutput: output, projects: [project])
        #expect(list.count == 1, "ids raros y proyectos desconocidos se ignoran")
        #expect(list.first?.weekdays == [6, 7] && list.first?.timeText == "22:05")
        #expect(list.first?.checkCommand == "npm test" && list.first?.push == true)
        #expect(list.first?.lastRun == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(ClaudeTaskTimer.parse("ruido\nlaunchd\n") == .launchd)
        #expect(ClaudeTaskTimer.parse("") == .none)
    }
}

@Suite("Tareas programadas (despachador con tmux)", .enabled(if: LocalTmux.path != nil), .serialized)
struct ClaudeScheduleDispatcherTests {

    /// Guarda una tarea programada con plantillas falsas que apuntan lo que reciben.
    private static func install(_ box: ClaudeTaskDispatcherTests.Box, days: String, time: String) throws {
        let dir = box.tasks.appendingPathComponent("schedules/abc12345", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files: [String: String] = [
            "config": "v=1\ntitle=Noche\nproject=proyecto\nsession=proj\ndays=\(days)\ntime=\(time)\nenabled=1\n",
            "prompt": "Corre los tests",
            "meta.tpl": #"{"workingDirectory":"/x-@@RUN@@","createdAt":"@@NOW@@"}"#,
            "launch.tpl": "read -r token; printf '%s|%s' \"$ARGOS_META_B64\" '\(ClaudeScheduleScripts.sentinelAgentID)' > \"$HOME/launched\"\n",
            "send.tpl": "echo enviado > \"$HOME/sent\"\n",
            "stop.tpl": "echo parado > \"$HOME/stopped\"\n",
            "task.tpl": "v=1\ntitle=Noche\nsource=schedule\ntarget=agent\nagent=\(ClaudeScheduleScripts.sentinelAgentID)\nbranch=argos/prog-abc12345-@@RUN@@\ndir=/x\ncommit=0\npush=0\nmax_minutes=1\n",
        ]
        for (name, content) in files {
            try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    private static func today() -> (day: String, time: String, later: String) {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let weekday = calendar.component(.weekday, from: now) // 1 = domingo
        let isoDay = weekday == 1 ? 7 : weekday - 1
        let earlier = now.addingTimeInterval(-120)
        let later = now.addingTimeInterval(3 * 3600)
        func hm(_ date: Date) -> String {
            String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
        }
        // Cerca de medianoche la hora «anterior» sería de ayer: el test usa la de ahora.
        return (String(isoDay), calendar.isDate(earlier, inSameDayAs: now) ? hm(earlier) : hm(now), hm(later))
    }

    @Test func tocaASuHoraYCreaElEncargoDesdeLasPlantillas() throws {
        let box = try ClaudeTaskDispatcherTests.Box(fakeClaude: "awk -v f=\"$HOME/received\" '{ print > f; fflush(f) }'")
        defer { box.close() }
        let now = Self.today()
        try Self.install(box, days: now.day, time: now.time)
        try box.sh("sh \"$HOME/.config/argos/tasks/dispatch.sh\" tick")

        let task = try #require(try box.list().first)
        #expect(task.state == .running && task.isAgent)
        #expect(task.branch?.hasPrefix("argos/prog-abc12345-") == true && task.branch?.contains("@@") == false)
        let launched = try String(contentsOf: box.home.appendingPathComponent("launched"), encoding: .utf8)
        let parts = launched.split(separator: "|").map(String.init)
        #expect(!parts[1].contains("a7905000"), "el id centinela se cambia por uno nuevo")
        let meta = String(decoding: Data(base64Encoded: parts[0]) ?? Data(), as: UTF8.self)
        #expect(meta.contains("\"workingDirectory\":\"/x-") && !meta.contains("@@"))

        // Ya corrió hoy: otro tick no crea otra.
        try box.sh("sh \"$HOME/.config/argos/tasks/dispatch.sh\" tick")
        #expect(try box.list().count == 1)
    }

    @Test func noTocaFueraDeHoraNiConElProyectoEnUsoPeroSeEjecutaAMano() throws {
        let box = try ClaudeTaskDispatcherTests.Box(fakeClaude: "awk -v f=\"$HOME/received\" '{ print > f; fflush(f) }'")
        defer { box.close() }
        let now = Self.today()
        try Self.install(box, days: now.day, time: now.later)
        try box.sh("sh \"$HOME/.config/argos/tasks/dispatch.sh\" tick")
        #expect(try box.list().isEmpty, "aún no es la hora")

        try Self.install(box, days: now.day, time: now.time)
        try box.sh("tmux set-option -p -t \(box.pane) @argos_claude working")
        try box.sh("sh \"$HOME/.config/argos/tasks/dispatch.sh\" tick")
        #expect(try box.list().isEmpty, "Claude trabaja en el proyecto: espera")

        try box.sh("tmux set-option -p -t \(box.pane) @argos_claude done")
        try box.sh("sh \"$HOME/.config/argos/tasks/dispatch.sh\" run abc12345")
        #expect(try box.list().count == 1)
    }

    @Test func pasadoElTiempoMaximoSeDetieneYFalla() throws {
        let box = try ClaudeTaskDispatcherTests.Box(fakeClaude: "awk -v f=\"$HOME/received\" '{ print > f; fflush(f) }'")
        defer { box.close() }
        let now = Self.today()
        try Self.install(box, days: now.day, time: now.later)
        try box.sh("sh \"$HOME/.config/argos/tasks/dispatch.sh\" run abc12345")
        let task = try #require(try box.list().first)
        // Arrancó hace 2 minutos (máximo: 1).
        let started = box.tasks.appendingPathComponent("proyecto/\(task.folder)/started")
        try "\(Int(Date().timeIntervalSince1970) - 120)\n".write(to: started, atomically: true, encoding: .utf8)
        try box.sh("sh \"$HOME/.config/argos/tasks/dispatch.sh\" tick")
        let expired = try #require(try box.list().first)
        #expect(expired.state == .failed && expired.reason == .timeout)
        #expect(FileManager.default.fileExists(atPath: box.home.appendingPathComponent("stopped").path))
    }
}

@MainActor
@Suite("Tareas programadas (pantalla)")
struct ClaudeSchedulesModelTests {

    @Test func guardaUnaTareaDelProyectoConSuHora() async {
        let mock = MockSSHService()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let project = Project(name: "App", path: "/srv/repos/app")
        let model = ClaudeSchedulesModel(service: mock, serverID: UUID(), project: project, calendar: calendar)
        #expect(!model.canSave)
        model.title = "Dependencias"
        model.prompt = "Actualiza las dependencias"
        model.weekdays = [1]
        model.time = calendar.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 7, minute: 30))!
        model.push = true
        model.checkCommand = " npm test "
        await model.add()
        let saved = mock.schedules.first
        #expect(saved?.hour == 7 && saved?.minute == 30 && saved?.weekdays == [1])
        #expect(saved?.checkCommand == "npm test" && saved?.session == project.sessionName)
        #expect(model.schedules.count == 1 && model.timer == .launchd)
        #expect(model.title.isEmpty)

        await model.runNow(model.schedules[0])
        #expect(mock.taskActions.contains("run \(saved?.id ?? "")"))
        await model.delete(model.schedules[0])
        #expect(model.schedules.isEmpty)
    }
}
