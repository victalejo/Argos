//
//  DoctorModels.swift
//  ArgosCore
//
//  Tipos (lógica pura) del Doctor del servidor: estado de cada comprobación, el arreglo
//  que se ofrece y el resultado completo. Las reglas de severidad viven en
//  `DoctorEvaluator`; las vistas solo pintan lo que aquí se decide.
//

import Foundation

/// Resultado de una comprobación. El orden de `severity` sirve para resumir (peor gana).
enum DoctorStatus: String, Sendable, Equatable {
    case ok
    case warning
    case problem
    /// No se pudo comprobar (falta una utilidad, permisos, otro sistema operativo…).
    case unknown

    /// 0 = correcto … 2 = problema; `unknown` no pesa (no es un fallo demostrado).
    var severity: Int {
        switch self {
        case .ok, .unknown: return 0
        case .warning: return 1
        case .problem: return 2
        }
    }

    /// Etiqueta corta para el texto del informe y la accesibilidad.
    var label: String {
        switch self {
        case .ok: return "Correcto"
        case .warning: return "Aviso"
        case .problem: return "Problema"
        case .unknown: return "No se pudo comprobar"
        }
    }
}

/// Identidad estable de cada comprobación (las vistas y los tests no dependen del texto).
enum DoctorCheckID: String, Sendable, CaseIterable {
    case tmux, git, claude, gh, tools, python, diskHome, diskTmp, memory, swap, claudeProcesses
    case maxSessions, fail2ban, claudeHooks, portsSkill, projectsFile, locale, clock
}

/// Qué se ofrece para arreglar una comprobación. Las acciones de un toque son SOLO las que
/// Argos ya sabe hacer de forma segura; el resto son comandos para copiar, nunca se ejecutan.
enum DoctorFix: Equatable, Sendable {
    /// Instala o actualiza los hooks de Claude de Argos (`SSHServicing.installClaudeHooks`).
    case installClaudeHooks(isUpdate: Bool)
    /// Instala o actualiza la skill «argos-puertos» y su script.
    case installPortsSkill(isUpdate: Bool)
    /// Comando que el usuario copia y ejecuta él mismo en el servidor.
    case copyCommand(String)
}

struct DoctorCheck: Identifiable, Equatable, Sendable {
    let id: DoctorCheckID
    let title: String
    let status: DoctorStatus
    /// Explicación corta (qué se encontró y por qué importa).
    let detail: String
    let fix: DoctorFix?

    init(_ id: DoctorCheckID, _ title: String, _ status: DoctorStatus, _ detail: String, fix: DoctorFix? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.fix = fix
    }
}

/// Resultado de una pasada del Doctor.
struct DoctorResult: Equatable, Sendable {
    let checks: [DoctorCheck]
    let finishedAt: Date

    var problemCount: Int { checks.filter { $0.status == .problem }.count }
    var warningCount: Int { checks.filter { $0.status == .warning }.count }

    /// Peor estado de la pasada (`.ok` si todo está bien o no se pudo comprobar).
    var overall: DoctorStatus {
        if problemCount > 0 { return .problem }
        if warningCount > 0 { return .warning }
        return .ok
    }

    var summary: String {
        switch (problemCount, warningCount) {
        case (0, 0): return "Todo en orden."
        case (0, let w): return w == 1 ? "1 aviso." : "\(w) avisos."
        case (let p, 0): return p == 1 ? "1 problema." : "\(p) problemas."
        case (let p, let w):
            return "\(p == 1 ? "1 problema" : "\(p) problemas") y \(w == 1 ? "1 aviso" : "\(w) avisos")."
        }
    }

    /// Texto plano para pegar en un issue (`serverLabel` ya viene redactado si hace falta).
    func plainText(serverLabel: String) -> String {
        var lines = ["Doctor del servidor: \(serverLabel)", "Resumen: \(summary)"]
        for check in checks {
            lines.append("[\(check.status.label)] \(check.title): \(check.detail)")
            if case .copyCommand(let command) = check.fix { lines.append("    Arreglo: \(command)") }
        }
        return lines.joined(separator: "\n")
    }
}

/// Versión numérica «a.b.c» extraída de la salida de `--version`.
struct DoctorVersion: Comparable, Equatable, Sendable {
    let parts: [Int]

    /// Primera secuencia `N.N[.N…]` del texto («tmux 3.3a» → 3.3, «git version 2.39.2 (Apple…)»).
    init?(parsing text: String) {
        guard let range = text.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return nil }
        let numbers = text[range].split(separator: ".").compactMap { Int($0) }
        guard !numbers.isEmpty else { return nil }
        parts = numbers
    }

    init(_ parts: Int...) { self.parts = parts }

    /// 2.26 y 2.26.0 son la misma versión.
    static func == (lhs: DoctorVersion, rhs: DoctorVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func < (lhs: DoctorVersion, rhs: DoctorVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    var text: String { parts.map(String.init).joined(separator: ".") }
}
