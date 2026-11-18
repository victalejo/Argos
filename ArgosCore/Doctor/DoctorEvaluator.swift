//
//  DoctorEvaluator.swift
//  ArgosCore
//
//  Reglas (lógica pura) del Doctor: convierte los datos del servidor (`DoctorFacts`) en
//  comprobaciones con su severidad, su explicación y su arreglo. TODA la decisión de qué es
//  un aviso y qué un problema vive aquí; las vistas no deciden nada.
//  Este archivo cubre el software (tmux, git, claude, gh, utilidades, hooks, skill,
//  projects.json); los recursos y el sistema están en `DoctorEvaluator+System.swift`.
//

import Foundation

enum DoctorEvaluator {

    /// Datos del dispositivo y de Argos que no salen del script remoto.
    struct Context: Sendable {
        /// Hora del dispositivo en mitad de la consulta (para el desfase de reloj).
        var deviceNow: Date
        /// ¿Los hooks de Claude de Argos están en su versión actual? `nil` = no se verificó.
        var hooksUpToDate: Bool?

        init(deviceNow: Date = Date(), hooksUpToDate: Bool? = nil) {
            self.deviceNow = deviceNow
            self.hooksUpToDate = hooksUpToDate
        }
    }

    /// Versión mínima de git para commits de muchos archivos (`--pathspec-from-file`).
    static let minimumGit = DoctorVersion(2, 26)
    /// tmux 3.0 introdujo las opciones de panel (`set-option -p`) que usan los hooks de Claude.
    static let minimumTmuxForHooks = DoctorVersion(3, 0)
    /// Canales SSH simultáneos que Argos usa por conexión (`ChannelGate.sharedConnectionLimit`).
    static let desiredSessions = ChannelGate.sharedConnectionLimit

    static func evaluate(_ facts: DoctorFacts, context: Context = Context()) -> [DoctorCheck] {
        [
            tmux(facts), git(facts), claude(facts), gh(facts),
            tools(facts), python(facts),
            diskHome(facts), diskTmp(facts), memory(facts), swap(facts), claudeProcesses(facts),
            maxSessions(facts), fail2ban(facts),
            claudeHooks(facts, context: context), portsSkill(facts), projectsFile(facts),
            locale(facts), clock(facts, context: context),
        ]
    }

    // MARK: - Software

    private static func tmux(_ facts: DoctorFacts) -> DoctorCheck {
        let title = "tmux"
        guard let present = facts.flag("tmux.present") else {
            return DoctorCheck(.tmux, title, .unknown, "No se pudo comprobar si tmux está instalado.")
        }
        guard present else {
            return DoctorCheck(.tmux, title, .problem,
                               "tmux no está instalado: Argos lo necesita para listar, crear y abrir sesiones.",
                               fix: DoctorInstallHints.install(package: "tmux", packageManager: facts["pm"]).map(DoctorFix.copyCommand))
        }
        let raw = facts["tmux.version"] ?? ""
        guard let version = DoctorVersion(parsing: raw) else {
            return DoctorCheck(.tmux, title, .ok, raw.isEmpty ? "Instalado." : "Instalado (\(raw)).")
        }
        if version < minimumTmuxForHooks {
            return DoctorCheck(.tmux, title, .warning,
                               "tmux \(version.text): funciona, pero el indicador de estado de Claude necesita tmux 3.0 o posterior.",
                               fix: DoctorInstallHints.install(package: "tmux", packageManager: facts["pm"]).map(DoctorFix.copyCommand))
        }
        return DoctorCheck(.tmux, title, .ok, "tmux \(version.text) instalado.")
    }

    private static func git(_ facts: DoctorFacts) -> DoctorCheck {
        let title = "git"
        guard let present = facts.flag("git.present") else {
            return DoctorCheck(.git, title, .unknown, "No se pudo comprobar si git está instalado.")
        }
        let install = DoctorInstallHints.install(package: "git", packageManager: facts["pm"]).map(DoctorFix.copyCommand)
        guard present else {
            return DoctorCheck(.git, title, .warning,
                               "git no está instalado: no funcionarán los cambios, commits, ramas ni clonar.", fix: install)
        }
        guard let version = DoctorVersion(parsing: facts["git.version"] ?? "") else {
            return DoctorCheck(.git, title, .ok, "Instalado (no se pudo leer la versión).")
        }
        if version < minimumGit {
            return DoctorCheck(.git, title, .warning,
                               "git \(version.text) es anterior a 2.26: los commits de muchísimos archivos pueden fallar. Actualízalo.",
                               fix: install)
        }
        return DoctorCheck(.git, title, .ok, "git \(version.text) instalado.")
    }

    private static func claude(_ facts: DoctorFacts) -> DoctorCheck {
        let title = "Claude Code"
        guard let present = facts.flag("claude.present") else {
            return DoctorCheck(.claude, title, .unknown, "No se pudo comprobar si Claude Code está instalado.")
        }
        guard present else {
            return DoctorCheck(.claude, title, .warning,
                               "claude no está instalado: el panel de agente y las ventanas de Claude no estarán disponibles.",
                               fix: .copyCommand(DoctorInstallHints.claudeInstall))
        }
        let version = DoctorVersion(parsing: facts["claude.version"] ?? "").map { " \($0.text)" } ?? ""
        switch facts["claude.auth"] {
        case "in":
            return DoctorCheck(.claude, title, .ok, "Instalado\(version) y con sesión iniciada.")
        case "out":
            return DoctorCheck(.claude, title, .warning,
                               "Instalado\(version), pero sin sesión iniciada. Inicia sesión desde el panel de agente de Argos o en el servidor.",
                               fix: .copyCommand("claude auth login"))
        default:
            return DoctorCheck(.claude, title, .unknown,
                               "Instalado\(version), pero no se pudo comprobar si tiene sesión iniciada.")
        }
    }

    private static func gh(_ facts: DoctorFacts) -> DoctorCheck {
        let title = "GitHub CLI (gh)"
        guard let present = facts.flag("gh.present") else {
            return DoctorCheck(.gh, title, .unknown, "No se pudo comprobar si gh está instalado.")
        }
        guard present else {
            return DoctorCheck(.gh, title, .warning,
                               "gh no está instalado: no se podrán ver PR ni CI, abrir PR ni clonar repositorios de GitHub.",
                               fix: DoctorInstallHints.install(package: "gh", packageManager: facts["pm"]).map(DoctorFix.copyCommand))
        }
        let version = DoctorVersion(parsing: facts["gh.version"] ?? "").map { " \($0.text)" } ?? ""
        switch facts["gh.auth"] {
        case "in":
            return DoctorCheck(.gh, title, .ok, "Instalado\(version) y con sesión iniciada.")
        case "out":
            return DoctorCheck(.gh, title, .warning,
                               "Instalado\(version), pero sin sesión: inicia sesión para usar PR, CI y clonar.",
                               fix: .copyCommand("gh auth login"))
        default:
            return DoctorCheck(.gh, title, .unknown,
                               "Instalado\(version), pero no se pudo comprobar la sesión (¿sin conexión a GitHub?).")
        }
    }

    // MARK: - Utilidades

    /// Utilidades que usan los scripts de Argos: (clave del script, nombre, qué se pierde sin ella).
    private static let requiredTools: [(key: String, name: String, impact: String)] = [
        ("tool.base64d", "base64 -d", "los agentes persistentes (iPhone/iPad) no podrán arrancar"),
        ("tool.mkfifo", "mkfifo", "los agentes persistentes (iPhone/iPad) no podrán arrancar"),
        ("tool.nohup", "nohup", "los agentes persistentes (iPhone/iPad) no podrán arrancar"),
        ("tool.findprintf", "find con -printf (GNU)", "«Enviar al Mac» no podrá listar los archivos del proyecto"),
        ("tool.timeout", "timeout", "las comprobaciones lentas no tienen límite de tiempo"),
        ("tool.cksum", "cksum", "se omiten las comprobaciones de integridad opcionales"),
        ("tool.awk", "awk", "algunas lecturas del servidor no se podrán interpretar"),
    ]

    private static func tools(_ facts: DoctorFacts) -> DoctorCheck {
        let title = "Utilidades del sistema"
        let missing = requiredTools.filter { facts.flag($0.key) == false }
        let unknown = requiredTools.filter { facts.flag($0.key) == nil }
        if unknown.count == requiredTools.count {
            return DoctorCheck(.tools, title, .unknown, "No se pudieron comprobar las utilidades.")
        }
        if missing.isEmpty {
            return DoctorCheck(.tools, title, .ok, "timeout, cksum, base64, find -printf, mkfifo, nohup y awk disponibles.")
        }
        let text = missing.map { "\($0.name): \($0.impact)" }.joined(separator: "; ")
        let isMac = facts["os"] == "Darwin"
        let hint = isMac
            ? " (macOS trae las versiones de BSD; en Linux vienen con coreutils y findutils)."
            : "."
        return DoctorCheck(.tools, title, .warning, "Faltan utilidades. Sin " + text + hint,
                           fix: isMac ? nil : DoctorInstallHints.install(package: "coreutils findutils", packageManager: facts["pm"]).map(DoctorFix.copyCommand))
    }

    private static func python(_ facts: DoctorFacts) -> DoctorCheck {
        let title = "python3 (opcional)"
        switch facts.flag("tool.python3") {
        case true?: return DoctorCheck(.python, title, .ok, "Instalado: permite validar projects.json a fondo.")
        case false?: return DoctorCheck(.python, title, .ok, "No instalado. Es opcional: Argos no lo necesita.")
        case nil: return DoctorCheck(.python, title, .unknown, "No se pudo comprobar.")
        }
    }

    // MARK: - Integraciones de Argos en el servidor

    private static func claudeHooks(_ facts: DoctorFacts, context: Context) -> DoctorCheck {
        let title = "Hooks de Claude de Argos"
        switch facts["hooks.settings"] {
        case "unreadable":
            return DoctorCheck(.claudeHooks, title, .unknown, "~/.claude/settings.json no se puede leer (permisos).")
        case "missing":
            return DoctorCheck(.claudeHooks, title, .warning,
                               "No instalados: sin ellos Argos no muestra si Claude trabaja o espera tu permiso.",
                               fix: .installClaudeHooks(isUpdate: false))
        case "ok":
            break
        default:
            return DoctorCheck(.claudeHooks, title, .unknown, "No se pudo comprobar.")
        }
        guard let count = Int(facts["hooks.marker"] ?? ""), count > 0 else {
            return DoctorCheck(.claudeHooks, title, .warning,
                               "No instalados: sin ellos Argos no muestra si Claude trabaja o espera tu permiso.",
                               fix: .installClaudeHooks(isUpdate: false))
        }
        switch context.hooksUpToDate {
        case true?: return DoctorCheck(.claudeHooks, title, .ok, "Instalados y al día.")
        case false?:
            return DoctorCheck(.claudeHooks, title, .warning,
                               "Instalados, pero de una versión anterior: actualízalos para que el indicador sea fiable.",
                               fix: .installClaudeHooks(isUpdate: true))
        case nil: return DoctorCheck(.claudeHooks, title, .ok, "Instalados (no se pudo verificar que estén al día).")
        }
    }

    private static func portsSkill(_ facts: DoctorFacts) -> DoctorCheck {
        let title = "Skill «argos-puertos»"
        switch facts["skill.ports"] {
        case "current":
            return DoctorCheck(.portsSkill, title, .ok, "Instalada y al día: Claude sabe qué puertos hay y puede pedirte abrir uno.")
        case "outdated":
            return DoctorCheck(.portsSkill, title, .warning, "Instalada, pero de una versión anterior.",
                               fix: .installPortsSkill(isUpdate: true))
        case "missing":
            return DoctorCheck(.portsSkill, title, .warning,
                               "No instalada: Claude no podrá consultar los puertos ni pedirte que abras uno.",
                               fix: .installPortsSkill(isUpdate: false))
        default:
            return DoctorCheck(.portsSkill, title, .unknown, "No se pudo comprobar.")
        }
    }

    private static func projectsFile(_ facts: DoctorFacts) -> DoctorCheck {
        let title = "Proyectos (projects.json)"
        switch facts["projects.file"] {
        case "missing":
            return DoctorCheck(.projectsFile, title, .ok, "Aún no existe: se crea al añadir el primer proyecto.")
        case "unreadable":
            return DoctorCheck(.projectsFile, title, .problem,
                               "~/.config/argos/projects.json existe pero no se puede leer: revisa sus permisos.")
        case "ok":
            if facts["projects.json"] == "invalid" {
                return DoctorCheck(.projectsFile, title, .problem,
                                   "~/.config/argos/projects.json no es un JSON válido: Argos no lo modificará hasta que lo corrijas.")
            }
            let version = facts["projects.version"].map { "versión \($0)" } ?? "sin número de versión"
            return DoctorCheck(.projectsFile, title, .ok, "Legible (\(version)).")
        default:
            return DoctorCheck(.projectsFile, title, .unknown, "No se pudo comprobar.")
        }
    }
}
