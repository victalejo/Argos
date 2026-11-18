//
//  DoctorEvaluator+System.swift
//  ArgosCore
//
//  Reglas del Doctor sobre recursos y sistema: disco, memoria, swap, procesos de Claude,
//  `MaxSessions` de sshd, fail2ban, locale y desfase de reloj. Umbrales como constantes.
//

import Foundation

extension DoctorEvaluator {

    // MARK: - Umbrales (KB salvo que se diga otra cosa)

    static let homeWarningKB = 1_024 * 1_024         // 1 GB
    static let homeProblemKB = 200 * 1_024           // 200 MB
    static let tmpWarningKB = 200 * 1_024
    static let tmpProblemKB = 50 * 1_024
    static let memoryWarningKB = 1_024 * 1_024
    static let memoryProblemKB = 300 * 1_024
    /// Con menos RAM que esto, no tener swap es un aviso.
    static let swaplessRAMLimitKB = 4 * 1_024 * 1_024
    /// Fracción de la RAM que suman los procesos `claude` para avisar / dar problema.
    static let claudeMemoryWarningFraction = 0.4
    static let claudeMemoryProblemFraction = 0.7
    static let clockWarningSeconds = 60.0
    static let clockProblemSeconds = 300.0

    // MARK: - Disco

    static func diskHome(_ facts: DoctorFacts) -> DoctorCheck {
        disk(.diskHome, "Disco libre en $HOME", facts.numbers("disk.home", count: 2),
             warning: homeWarningKB, problem: homeProblemKB,
             impact: "Las sesiones, los agentes y los proyectos escriben ahí.")
    }

    static func diskTmp(_ facts: DoctorFacts) -> DoctorCheck {
        disk(.diskTmp, "Disco libre en /tmp", facts.numbers("disk.tmp", count: 2),
             warning: tmpWarningKB, problem: tmpProblemKB,
             impact: "Las subidas de archivos y capturas pasan por /tmp.")
    }

    private static func disk(
        _ id: DoctorCheckID, _ title: String, _ numbers: [Int]?, warning: Int, problem: Int, impact: String
    ) -> DoctorCheck {
        guard let numbers else { return DoctorCheck(id, title, .unknown, "No se pudo leer el espacio libre (df).") }
        let free = numbers[1]
        let text = "\(formatKB(free)) libres de \(formatKB(numbers[0]))."
        if free < problem { return DoctorCheck(id, title, .problem, "Casi sin espacio: \(text) \(impact)") }
        if free < warning { return DoctorCheck(id, title, .warning, "Poco espacio: \(text) \(impact)") }
        return DoctorCheck(id, title, .ok, text)
    }

    // MARK: - Memoria

    /// `mem` = «total disponible swapTotal swapLibre» en KB (solo Linux, de /proc/meminfo).
    private static func memoryNumbers(_ facts: DoctorFacts) -> [Int]? {
        facts.numbers("mem", count: 4).flatMap { $0[0] > 0 ? $0 : nil }
    }

    static func memory(_ facts: DoctorFacts) -> DoctorCheck {
        let title = "Memoria disponible"
        guard let mem = memoryNumbers(facts) else {
            return DoctorCheck(.memory, title, .unknown, "Solo se puede leer en servidores Linux (/proc/meminfo).")
        }
        let text = "\(formatKB(mem[1])) disponibles de \(formatKB(mem[0]))."
        if mem[1] < memoryProblemKB {
            return DoctorCheck(.memory, title, .problem,
                               "Memoria casi agotada: \(text) El sistema puede matar procesos (y sesiones tmux) sin avisar.")
        }
        if mem[1] < memoryWarningKB {
            return DoctorCheck(.memory, title, .warning, "Memoria justa: \(text) Evita abrir más agentes de Claude.")
        }
        return DoctorCheck(.memory, title, .ok, text)
    }

    static func swap(_ facts: DoctorFacts) -> DoctorCheck {
        let title = "Swap"
        guard let mem = memoryNumbers(facts) else {
            return DoctorCheck(.swap, title, .unknown, "Solo se puede leer en servidores Linux (/proc/meminfo).")
        }
        if mem[2] == 0 {
            if mem[0] < swaplessRAMLimitKB {
                return DoctorCheck(.swap, title, .warning,
                                   "Sin swap y con poca RAM (\(formatKB(mem[0]))): un pico de memoria puede tumbar tus sesiones. Añade un archivo de swap.")
            }
            return DoctorCheck(.swap, title, .ok, "Sin swap (hay \(formatKB(mem[0])) de RAM).")
        }
        let used = max(mem[2] - mem[3], 0)
        if Double(used) / Double(mem[2]) > 0.8 {
            return DoctorCheck(.swap, title, .warning,
                               "Swap casi llena: \(formatKB(used)) usados de \(formatKB(mem[2])). El servidor está corto de memoria.")
        }
        return DoctorCheck(.swap, title, .ok, "\(formatKB(used)) usados de \(formatKB(mem[2])).")
    }

    static func claudeProcesses(_ facts: DoctorFacts) -> DoctorCheck {
        let title = "Procesos de Claude"
        guard let procs = facts.numbers("claude.procs", count: 2) else {
            return DoctorCheck(.claudeProcesses, title, .unknown, "No se pudo listar los procesos (ps).")
        }
        let count = procs[0]
        guard count > 0 else { return DoctorCheck(.claudeProcesses, title, .ok, "Ningún proceso de Claude en marcha.") }
        let text = "\(count) \(count == 1 ? "proceso" : "procesos") de Claude suman \(formatKB(procs[1]))."
        guard let mem = memoryNumbers(facts) else { return DoctorCheck(.claudeProcesses, title, .ok, text) }
        let fraction = Double(procs[1]) / Double(mem[0])
        if fraction >= claudeMemoryProblemFraction {
            return DoctorCheck(.claudeProcesses, title, .problem,
                               "\(text) Ocupan casi toda la RAM: cierra agentes que no uses.")
        }
        if fraction >= claudeMemoryWarningFraction {
            return DoctorCheck(.claudeProcesses, title, .warning,
                               "\(text) Es mucha memoria: cierra agentes que no uses para no quedarte sin RAM.")
        }
        return DoctorCheck(.claudeProcesses, title, .ok, text)
    }

    // MARK: - sshd y fail2ban

    static func maxSessions(_ facts: DoctorFacts) -> DoctorCheck {
        let title = "MaxSessions de sshd"
        switch facts["sshd.config"] {
        case "readable":
            let configured = facts["sshd.maxsessions"] ?? "default"
            let value = configured == "default" ? 10 : Int(configured)
            guard let value else { return DoctorCheck(.maxSessions, title, .unknown, "No se pudo interpretar el valor.") }
            let origin = configured == "default" ? " (valor por defecto de OpenSSH)" : ""
            if value < desiredSessions {
                return DoctorCheck(.maxSessions, title, .warning,
                                   "MaxSessions = \(value)\(origin), menos de \(desiredSessions). Argos se adapta, pero irá más lento al abrir varias cosas a la vez. Súbelo en sshd_config si puedes.")
            }
            return DoctorCheck(.maxSessions, title, .ok, "MaxSessions = \(value)\(origin).")
        case "unreadable":
            return DoctorCheck(.maxSessions, title, .unknown, "No se pudo comprobar: /etc/ssh/sshd_config no es legible sin permisos de root.")
        case "missing":
            return DoctorCheck(.maxSessions, title, .unknown, "No se pudo comprobar: no hay /etc/ssh/sshd_config.")
        default:
            return DoctorCheck(.maxSessions, title, .unknown, "No se pudo comprobar.")
        }
    }

    static func fail2ban(_ facts: DoctorFacts) -> DoctorCheck {
        let title = "fail2ban"
        switch facts["fail2ban"] {
        case "running":
            return DoctorCheck(.fail2ban, title, .ok, "En marcha. Si Argos reconecta muchas veces seguidas con una clave mala, puede bloquearte.")
        case "installed":
            return DoctorCheck(.fail2ban, title, .ok, "Instalado (no se pudo ver si está activo). Un exceso de intentos fallidos puede bloquear tu IP.")
        case "absent":
            return DoctorCheck(.fail2ban, title, .ok, "No instalado (solo informativo).")
        default:
            return DoctorCheck(.fail2ban, title, .unknown, "No se pudo comprobar.")
        }
    }

    // MARK: - Locale y reloj

    static func locale(_ facts: DoctorFacts) -> DoctorCheck {
        let title = "Locale UTF-8"
        guard let env = facts.flag("locale.env") else {
            return DoctorCheck(.locale, title, .unknown, "No se pudo comprobar.")
        }
        if env { return DoctorCheck(.locale, title, .ok, "El entorno usa UTF-8.") }
        let command = "sudo locale-gen en_US.UTF-8 && echo 'export LANG=en_US.UTF-8' >> ~/.profile"
        switch facts.flag("locale.avail") {
        case true?:
            return DoctorCheck(.locale, title, .warning,
                               "Hay locales UTF-8, pero el entorno no usa ninguno: una tmux sin UTF-8 rompe los acentos. Define LANG=en_US.UTF-8 en ~/.profile.",
                               fix: .copyCommand("echo 'export LANG=en_US.UTF-8' >> ~/.profile"))
        case false?:
            return DoctorCheck(.locale, title, .warning,
                               "El servidor no tiene ningún locale UTF-8: una tmux sin UTF-8 rompe los acentos. Genera uno y defínelo.",
                               fix: .copyCommand(command))
        case nil:
            return DoctorCheck(.locale, title, .warning,
                               "El entorno no declara UTF-8 (LANG vacío o distinto): una tmux sin UTF-8 rompe los acentos.",
                               fix: .copyCommand("echo 'export LANG=en_US.UTF-8' >> ~/.profile"))
        }
    }

    static func clock(_ facts: DoctorFacts, context: Context) -> DoctorCheck {
        let title = "Reloj del servidor"
        guard let seconds = Int(facts["clock"] ?? ""), seconds > 0 else {
            return DoctorCheck(.clock, title, .unknown, "No se pudo leer la hora del servidor.")
        }
        let skew = Double(seconds) - context.deviceNow.timeIntervalSince1970
        let magnitude = abs(skew)
        let direction = skew > 0 ? "adelantado" : "atrasado"
        let text = "El servidor va \(formatSeconds(magnitude)) \(direction) respecto a este dispositivo."
        if magnitude >= clockProblemSeconds {
            return DoctorCheck(.clock, title, .problem,
                               "\(text) Los túneles, los avisos de Claude y las fechas de los commits saldrán desfasados. Activa la sincronización horaria (NTP).")
        }
        if magnitude >= clockWarningSeconds {
            return DoctorCheck(.clock, title, .warning, "\(text) Conviene activar la sincronización horaria (NTP).")
        }
        return DoctorCheck(.clock, title, .ok, "Desfase de \(formatSeconds(magnitude)): correcto.")
    }

    // MARK: - Formato

    static func formatKB(_ kb: Int) -> String {
        let mb = Double(kb) / 1_024
        if mb >= 1_024 { return String(format: "%.1f GB", mb / 1_024) }
        return String(format: "%.0f MB", mb)
    }

    static func formatSeconds(_ seconds: Double) -> String {
        if seconds < 90 { return "\(Int(seconds.rounded())) s" }
        return "\(Int((seconds / 60).rounded())) min"
    }
}
