//
//  SSHSessionManagement.swift
//  Argos
//
//  Fase 3: gestión de sesiones tmux (crear / renombrar / matar) por el CANAL DE
//  COMANDOS (executeCommandStream), NO por el PTY. Cada operación es un único comando
//  tmux no interactivo; la UI refresca la lista después de cualquiera de ellas.
//
//  Los nombres se entrecomillan para el shell con `Self.shellSingleQuoted(_:)`
//  (definido en SSHTerminalSession.swift) para resistir espacios y caracteres
//  especiales. La validación de caracteres prohibidos por tmux (':' y '.') la hace
//  `SessionNameValidator` antes de llegar aquí.
//

import Foundation
@preconcurrency import Citadel
import NIOCore

extension SSHService {

    /// Crea una nueva sesión tmux *detached* (`tmux new-session -d -s '<nombre>'`).
    func createSession(named name: String) async throws {
        try await runManagementCommand(
            "tmux new-session -d -s \(ShellQuoting.singleQuoted(name))"
        )
    }

    /// Renombra una sesión (`tmux rename-session -t '<viejo>' '<nuevo>'`).
    func renameSession(from oldName: String, to newName: String) async throws {
        try await runManagementCommand(
            "tmux rename-session -t \(Self.exactSessionTarget(oldName)) "
            + ShellQuoting.singleQuoted(newName)
        )
    }

    /// Mata una sesión (`tmux kill-session -t '=<nombre>'`). Operación destructiva.
    /// Target EXACTO: sin '=', tmux podría matar otra sesión por coincidencia de prefijo.
    func killSession(named name: String) async throws {
        try await runManagementCommand(
            "tmux kill-session -t \(Self.exactSessionTarget(name))"
        )
    }

    // MARK: - Ventanas

    /// Lista las ventanas de una sesión. Devuelve `[]` si la sesión no existe o no hay
    /// servidor tmux (no lanza: la barra de ventanas simplemente queda vacía).
    func listWindows(session: String) async throws -> [TmuxWindow] {
        let client = try await connectedClient()
        let command =
            "tmux list-windows -t \(ShellQuoting.singleQuoted(session)) "
            + "-F \(ShellQuoting.singleQuoted(Self.listWindowsFormat))"
        let result = try await capture(client, command: command)
        guard result.exitCode == 0 else { return [] }
        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { TmuxWindow(line: String($0)) }
            .sorted { $0.index < $1.index }
    }

    /// Cambia la ventana activa de la sesión (`tmux select-window -t '<sesión>':<idx>`).
    /// El terminal adjunto a esa sesión refleja el cambio en vivo.
    func selectWindow(session: String, index: Int) async throws {
        try await runManagementCommand(
            "tmux select-window -t \(ShellQuoting.singleQuoted(session)):\(index)"
        )
    }

    /// Formato de `list-windows` que parsea `TmuxWindow(line:)`. El nombre va al final
    /// para tolerar '|' dentro de él; `@argos_color` es el color elegido en Argos y
    /// `pane_current_command` permite reconocer agentes (claude, codex, grok).
    static let listWindowsFormat =
        "#{window_index}|#{window_active}|#{window_panes}|#{@argos_color}|#{pane_current_command}|#{window_name}"

    /// `tmux new-window` en el directorio del panel activo (como hace `prefix c` con
    /// `-c '#{pane_current_path}'`), en vez de abrir siempre en `~`.
    static func newWindowCommand(session: String) -> String {
        "tmux new-window -t \(ShellQuoting.singleQuoted(session)) -c '#{pane_current_path}'"
    }

    /// `tmux rename-window` de la ventana `índice` de la sesión.
    static func renameWindowCommand(session: String, index: Int, name: String) -> String {
        "tmux rename-window -t \(ShellQuoting.singleQuoted(session)):\(index) "
            + ShellQuoting.singleQuoted(name)
    }

    /// `tmux kill-window` de la ventana `índice` de la sesión.
    static func killWindowCommand(session: String, index: Int) -> String {
        "tmux kill-window -t \(ShellQuoting.singleQuoted(session)):\(index)"
    }

    /// Guarda (o borra, con `nil`) el color de la ventana en la opción de usuario
    /// `@argos_color`. Vive en el servidor tmux: persiste y lo ven todos los clientes.
    static func windowColorCommand(session: String, index: Int, color: WindowColor?) -> String {
        let target = "\(ShellQuoting.singleQuoted(session)):\(index)"
        guard let color else { return "tmux set-option -wu -t \(target) @argos_color" }
        return "tmux set-option -w -t \(target) @argos_color \(ShellQuoting.singleQuoted(color.rawValue))"
    }

    /// Crea una nueva ventana en la sesión, en el directorio del panel activo.
    func newWindow(session: String) async throws {
        try await runManagementCommand(Self.newWindowCommand(session: session))
    }

    /// Nueva ventana con un agente: la crea con el nombre del agente en `directory` (o
    /// en el del panel activo) y le teclea el binario. Se lanza tecleándolo en el shell
    /// interactivo, no como comando de la ventana, para que use el PATH del usuario y,
    /// al salir del agente, la ventana quede en su shell en vez de cerrarse.
    static func newAgentWindowCommand(session: String, agent: CodingAgent, directory: String?) -> String {
        let target = ShellQuoting.singleQuoted(session)
        let dir = directory.map(ShellQuoting.singleQuoted) ?? "'#{pane_current_path}'"
        return "idx=$(tmux new-window -P -F '#{window_index}' -t \(target) -c \(dir) "
            + "-n \(ShellQuoting.singleQuoted(agent.displayName))) && "
            + "tmux send-keys -t \(target):\"$idx\" \(ShellQuoting.singleQuoted(agent.binary)) Enter"
    }

    /// Abre una ventana con `agent` corriendo (ver `newAgentWindowCommand`).
    func newAgentWindow(session: String, agent: CodingAgent, directory: String?) async throws {
        try await runManagementCommand(
            Self.newAgentWindowCommand(session: session, agent: agent, directory: directory)
        )
    }

    /// Agentes de terminal instalados en el servidor (para el menú «+»).
    func installedCodingAgents() async throws -> Set<CodingAgent> {
        let client = try await connectedClient()
        let result = try await capture(client, command: CodingAgent.installedAgentsScript)
        return CodingAgent.parseInstalled(result.stdout)
    }

    /// `git rev-parse --abbrev-ref HEAD` en `path`; `nil` si no es un repositorio.
    static func gitBranchCommand(path: String) -> String {
        "git -C \(ShellQuoting.singleQuoted(path)) rev-parse --abbrev-ref HEAD 2>/dev/null"
    }

    /// Rama git actual de `path` en el servidor, o `nil` si no es un repo (o no hay git).
    func gitBranch(at path: String) async throws -> String? {
        let client = try await connectedClient()
        let result = try await capture(client, command: Self.gitBranchCommand(path: path))
        guard result.exitCode == 0 else { return nil }
        return Self.parseGitBranch(result.stdout)
    }

    /// Última línea no vacía de la salida (el perfil del shell puede ensuciar la
    /// primera); `nil` si está vacía o es `HEAD` (HEAD desacoplado: no hay rama).
    static func parseGitBranch(_ output: String) -> String? {
        let branch = output
            .split(whereSeparator: \.isNewline).last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return branch.isEmpty || branch == "HEAD" ? nil : branch
    }

    /// Renombra una ventana (desactiva el auto-renombrado de tmux para ella).
    func renameWindow(session: String, index: Int, to name: String) async throws {
        let validName = try WindowNameValidator.validate(name)
        try await runManagementCommand(
            Self.renameWindowCommand(session: session, index: index, name: validName)
        )
    }

    /// Cierra una ventana (mata sus procesos). Si fuera la última, tmux cerraría la
    /// sesión entera: la UI no lo ofrece en ese caso.
    func killWindow(session: String, index: Int) async throws {
        try await runManagementCommand(Self.killWindowCommand(session: session, index: index))
    }

    /// Cambia (o quita) el color de una ventana.
    func setWindowColor(session: String, index: Int, color: WindowColor?) async throws {
        try await runManagementCommand(
            Self.windowColorCommand(session: session, index: index, color: color)
        )
    }

    // MARK: - Paneles
    //
    // Operan sobre el panel ACTIVO de la ventana actual de la sesión (target `-t '<sesión>'`).
    // Como tmux es cliente-servidor, el terminal adjunto refleja el cambio en vivo.

    /// Divide el panel activo. `vertical == true` apila arriba/abajo (`-v`); `false`
    /// pone los paneles lado a lado (`-h`).
    func splitPane(session: String, vertical: Bool) async throws {
        let direction = vertical ? "-v" : "-h"
        try await runManagementCommand(
            "tmux split-window \(direction) -t \(ShellQuoting.singleQuoted(session))"
        )
    }

    /// Mueve el foco al panel adyacente en la dirección dada (`select-pane -U/-D/-L/-R`).
    func selectPane(session: String, direction: TmuxPaneDirection) async throws {
        try await runManagementCommand(
            "tmux select-pane \(direction.selectPaneFlag) -t \(ShellQuoting.singleQuoted(session))"
        )
    }

    /// Alterna el zoom del panel activo a pantalla completa (`resize-pane -Z`).
    func zoomPane(session: String) async throws {
        try await runManagementCommand(
            "tmux resize-pane -Z -t \(ShellQuoting.singleQuoted(session))"
        )
    }

    /// Cierra el panel activo (`kill-pane`). Destructivo: la UI confirma antes y solo lo
    /// ofrece cuando la ventana activa tiene más de un panel (cerrar el único panel
    /// cerraría la ventana —y, si es la última, la sesión—).
    func killPane(session: String) async throws {
        try await runManagementCommand(
            "tmux kill-pane -t \(ShellQuoting.singleQuoted(session))"
        )
    }

    // MARK: - Envío de comandos (send-keys / broadcast)

    /// Construye el comando `tmux send-keys` (lógica pura, testeable). El texto se
    /// entrecomilla para el shell con `ShellQuoting`; tmux lo TECLEA literal en el panel
    /// activo. `enter` añade la tecla `Enter` como argumento aparte (no entrecomillado,
    /// para que tmux lo interprete como pulsación, no como texto literal).
    static func sendKeysCommand(session: String, keys: String, enter: Bool) -> String {
        var command =
            "tmux send-keys -t \(ShellQuoting.singleQuoted(session)) "
            + ShellQuoting.singleQuoted(keys)
        if enter { command += " Enter" }
        return command
    }

    /// Teclea `keys` en el panel activo de la sesión (`tmux send-keys`). Permite ejecutar
    /// un comando en una o varias sesiones (broadcast) sin escribir en el PTY.
    func sendKeys(session: String, keys: String, enter: Bool) async throws {
        try await runManagementCommand(
            Self.sendKeysCommand(session: session, keys: keys, enter: enter)
        )
    }

    /// Ejecuta un comando de gestión y lanza `commandFailed` si tmux sale con código
    /// distinto de cero (p. ej. nombre duplicado o sesión inexistente), propagando el
    /// mensaje de stderr de tmux para mostrarlo en la UI.
    func runManagementCommand(_ command: String) async throws {
        let client = try await connectedClient()
        let result = try await capture(client, command: command)
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHServiceError.commandFailed(
                exitCode: result.exitCode,
                message: detail.isEmpty ? "El servidor no devolvió detalles." : detail
            )
        }
    }
}
