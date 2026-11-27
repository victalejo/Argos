//
//  ClaudeSchedule.swift
//  ArgosCore
//
//  Tareas programadas (fase 3 de `docs/encargos.md`): «cada noche a las 3:00, corre los tests
//  y arregla lo que falle». Una tarea programada es una PLANTILLA de encargo en agente: cada
//  vez que toca, el despachador del servidor crea un encargo nuevo con su propio id de
//  agente, worktree y rama, sin la app. Como el lanzador del agente lo construye Swift
//  (`PersistentAgentScript`), la app deja en el servidor:
//   - `launch.tpl`: el lanzador con un id de agente centinela y los datos del agente en la
//     variable `$ARGOS_META_B64` en vez de en el script;
//   - `meta.tpl`: esos datos (JSON) con huecos `@@RUN@@` y `@@NOW@@`;
//   - `send.tpl`, `stop.tpl` y `task.tpl` (el `meta` del encargo), con los mismos huecos.
//  Los huecos solo se rellenan con valores sin caracteres especiales (hex, UUID, fecha ISO).
//

import Foundation

struct ClaudeSchedule: Identifiable, Equatable, Sendable {
    /// Identificador corto (hex): nombra la carpeta, el worktree y la rama.
    let id: String
    var title: String
    var prompt: String
    var projectPath: String
    var session: String
    /// Días de la semana (1 = lunes … 7 = domingo, como `date +%u`).
    var weekdays: Set<Int>
    var hour: Int
    var minute: Int
    var enabled = true
    /// Push a main al terminar (solo si pasa `checkCommand`, si lo hay).
    var push = false
    /// Comando que debe pasar antes del push (p. ej. `npm test`). Vacío = ninguno.
    var checkCommand = ""
    /// Tiempo máximo de una ejecución, en minutos.
    var maxMinutes = 60
    var permissionMode: ClaudeAgentCommand.PermissionMode = AgentPermissionPreferences.fallback

    /// Última ejecución (la escribe el despachador).
    var lastRun: Date?

    static func makeID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
    }

    /// Hora en `HH:MM` (hora local del servidor).
    var timeText: String { String(format: "%02d:%02d", hour, minute) }
}

enum ClaudeScheduleScripts {

    static let directoryRelativePath = ".config/argos/tasks/schedules"
    /// Id de agente que el despachador sustituye por uno nuevo en cada ejecución.
    static let sentinelAgentID = "a7905000-0000-4000-8000-000000000000"
    static let runPlaceholder = "@@RUN@@"
    static let nowPlaceholder = "@@NOW@@"
    /// Fecha fija que se cambia por `@@NOW@@` en el JSON de los datos del agente.
    private static let placeholderDate = Date(timeIntervalSinceReferenceDate: 0)

    struct Files: Equatable {
        /// Configuración (clave=valor) que lee el despachador.
        let config: String
        let prompt: String
        let launch: String
        let meta: String
        let send: String
        let stop: String
        let task: String
    }

    static func make(_ schedule: ClaudeSchedule, claudePath: String) throws -> Files {
        guard schedule.prompt.utf8.count <= ClaudeTaskAgentScripts.maxPromptBytes else {
            throw ClaudeTaskAgentError.promptTooLong
        }
        let folder = (schedule.projectPath as NSString).lastPathComponent
        let parent = (schedule.projectPath as NSString).deletingLastPathComponent
        let worktree = "\(parent)/\(folder)-prog-\(schedule.id)-\(runPlaceholder)"
        let branch = "argos/prog-\(schedule.id)-\(runPlaceholder)"

        let meta = PersistentAgentMeta(
            workingDirectory: worktree, title: schedule.title, createdAt: placeholderDate,
            permissionMode: schedule.permissionMode.rawValue
        )
        let metaJSON = String(decoding: try JSONEncoder.projects.encode(meta), as: UTF8.self)
        let metaB64 = Data(metaJSON.utf8).base64EncodedString()
        let fixedDate = ISO8601DateFormatter().string(from: placeholderDate)
        let metaTemplate = metaJSON.replacingOccurrences(of: fixedDate, with: nowPlaceholder)

        let worktreeCommand = GitWorktreeCommands.add(GitWorktreeRequest(
            repository: schedule.projectPath, branch: branch, createsBranch: true, base: "HEAD", path: worktree
        ))
        let invocation = ClaudeAgentCommand.persistent(
            claudePath: claudePath, sessionID: sentinelAgentID, resume: false, permissionMode: schedule.permissionMode
        )
        let launcher = try PersistentAgentScript.launch(id: sentinelAgentID, meta: meta, claudeInvocation: invocation)
        // Los datos del agente se leen de la variable que prepara el despachador.
        let launch = "\(worktreeCommand) </dev/null >/dev/null 2>&1 || exit 1\n"
            + launcher.replacingOccurrences(of: "'\(metaB64)'", with: "\"$ARGOS_META_B64\"") + "\n"

        var request = ClaudeTaskRequest(prompt: schedule.prompt, session: schedule.session, window: 0)
        request.source = "schedule"
        request.customTitle = schedule.title
        request.reference = schedule.id
        request.commit = true
        request.push = schedule.push
        request.target = .agent(id: sentinelAgentID, worktree: worktree, branch: branch)
        var task = request.metaText(directory: schedule.projectPath)
        task += "max_minutes=\(max(1, schedule.maxMinutes))\n"
        if !schedule.checkCommand.isEmpty { task += "check=\(clean(schedule.checkCommand))\n" }
        // El revisor automático antes del push usa este mismo `claude`.
        if schedule.push { task += "claude=\(clean(claudePath))\n" }

        return Files(
            config: configText(schedule),
            prompt: schedule.prompt,
            launch: launch,
            meta: metaTemplate,
            send: PersistentAgentScript.send(id: sentinelAgentID, line: AgentProtocol.encodeUserMessage(text: schedule.prompt)) + "\n",
            stop: PersistentAgentScript.stop(id: sentinelAgentID, delete: false) + "\n",
            task: task
        )
    }

    static func configText(_ schedule: ClaudeSchedule) -> String {
        [
            "v=1",
            "title=\(clean(schedule.title))",
            "project=\(ClaudeUsageProjects.key(forPath: schedule.projectPath))",
            "session=\(clean(schedule.session))",
            "days=\(schedule.weekdays.sorted().map(String.init).joined(separator: ","))",
            "time=\(schedule.timeText)",
            "enabled=\(schedule.enabled ? 1 : 0)",
            "push=\(schedule.push ? 1 : 0)",
            "max_minutes=\(max(1, schedule.maxMinutes))",
            "mode=\(schedule.permissionMode.rawValue)",
            "check=\(clean(schedule.checkCommand))",
        ].joined(separator: "\n") + "\n"
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    /// Lista las tareas programadas: por tarea, un marcador, su configuración, la última
    /// ejecución y el encargo (recortado a una línea).
    static let listCommand = #"""
        b="$HOME/.config/argos/tasks/schedules"; [ -d "$b" ] || exit 0
        for s in "$b"/*/; do
          s=${s%/}; [ -f "$s/config" ] || continue
          printf '@@schedule %s\n' "${s##*/}"
          head -c 2048 "$s/config" | sed 's/^/config /'
          printf 'last %s\n' "$(head -c 16 "$s/last" 2>/dev/null)"
          printf 'prompt %s\n' "$(head -c 400 "$s/prompt" 2>/dev/null | tr '\n\r\t' '   ')"
        done
        exit 0
        """#

    static func deleteCommand(id: String) -> String {
        precondition(id.allSatisfy { $0.isHexDigit }, "id de tarea programada no válido")
        return "rm -rf \"$HOME/\(directoryRelativePath)/\(id)\""
    }

    /// Parsea `listCommand`.
    static func parse(listOutput output: String, projects: [Project]) -> [ClaudeSchedule] {
        var result: [ClaudeSchedule] = []
        var id: String?
        var fields: [String: String] = [:]
        var prompt = ""
        var last: Date?
        func flush() {
            guard let id, id.allSatisfy(\.isHexDigit), !id.isEmpty,
                  let key = fields["project"],
                  let project = projects.first(where: { ClaudeUsageProjects.key(forPath: $0.path) == key })
            else { return }
            let time = (fields["time"] ?? "").split(separator: ":").compactMap { Int($0) }
            result.append(ClaudeSchedule(
                id: id, title: fields["title"] ?? "", prompt: prompt, projectPath: project.path,
                session: fields["session"] ?? project.sessionName,
                weekdays: Set((fields["days"] ?? "").split(separator: ",").compactMap { Int($0) }.filter { (1...7).contains($0) }),
                hour: time.first.map { min(23, max(0, $0)) } ?? 0,
                minute: time.count > 1 ? min(59, max(0, time[1])) : 0,
                enabled: fields["enabled"] != "0",
                push: fields["push"] == "1",
                checkCommand: fields["check"] ?? "",
                maxMinutes: Int(fields["max_minutes"] ?? "") ?? 60,
                permissionMode: fields["mode"].flatMap(ClaudeAgentCommand.PermissionMode.init(rawValue:)) ?? AgentPermissionPreferences.unrecognized,
                lastRun: last
            ))
        }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@schedule ") {
                flush()
                id = String(line.dropFirst(11)); fields = [:]; prompt = ""; last = nil
            } else if line.hasPrefix("config "), let equals = line.firstIndex(of: "=") {
                let key = String(line[line.index(line.startIndex, offsetBy: 7)..<equals])
                if fields[key] == nil { fields[key] = String(line[line.index(after: equals)...]) }
            } else if line.hasPrefix("last ") {
                last = Double(line.dropFirst(5).trimmingCharacters(in: .whitespaces)).map { Date(timeIntervalSince1970: $0) }
            } else if line.hasPrefix("prompt ") {
                prompt = String(line.dropFirst(7))
            }
        }
        flush()
        return result
    }
}
