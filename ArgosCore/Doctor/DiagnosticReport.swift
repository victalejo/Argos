//
//  DiagnosticReport.swift
//  ArgosCore
//
//  Informe de «Copiar diagnóstico»: texto plano para pegar en un issue. La composición es
//  lógica pura (`DiagnosticReport.compose`); `DiagnosticReport.collect` reúne los datos del
//  dispositivo y del registro. Lo que depende del usuario (servidor, registro) pasa por
//  `DiagnosticRedactor`; la cabecera (versión, sistema, modelo) no contiene datos personales.
//

import Foundation

/// Datos de la app y del dispositivo (sin nada personal).
struct DiagnosticAppInfo: Equatable, Sendable {
    var version: String
    var build: String
    var variant: String
    var system: String
    var deviceModel: String

    /// Lee el bundle y el sistema actuales.
    static func current() -> DiagnosticAppInfo {
        let info = Bundle.main.infoDictionary
        return DiagnosticAppInfo(
            version: info?["CFBundleShortVersionString"] as? String ?? "desconocida",
            build: info?["CFBundleVersion"] as? String ?? "desconocida",
            variant: variantName,
            system: "\(systemName) \(ProcessInfo.processInfo.operatingSystemVersionString)",
            deviceModel: modelIdentifier
        )
    }

    private static var variantName: String {
        #if os(macOS)
        #if APPSTORE
        return "Mac App Store"
        #else
        return "GitHub (Sparkle)"
        #endif
        #else
        return "App Store / TestFlight"
        #endif
    }

    private static var systemName: String {
        #if os(macOS)
        return "macOS"
        #else
        return modelIdentifier.hasPrefix("iPad") ? "iPadOS" : "iOS"
        #endif
    }

    private static var modelIdentifier: String {
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "desconocido" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
        #else
        var system = utsname()
        uname(&system)
        let machine = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
        // En el simulador `machine` es la arquitectura; el modelo simulado va en el entorno.
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
        #endif
    }
}

/// Todo lo que entra en el informe.
struct DiagnosticInput: Sendable {
    var app: DiagnosticAppInfo
    var generatedAt: Date
    /// Nombre del servidor del Doctor (se redacta) y su resultado, si hay uno conectado.
    var serverName: String?
    var doctor: DoctorResult?
    var log: DiagnosticLogExcerpt
}

enum DiagnosticReport {

    /// Compone el informe. `redactor` se comparte entre secciones para que los marcadores
    /// («servidor-1») sean los mismos en todo el informe.
    static func compose(_ input: DiagnosticInput, redactor: inout DiagnosticRedactor) -> String {
        var sections: [String] = []

        sections.append([
            "## Argos · diagnóstico",
            "Versión: \(input.app.version) (build \(input.app.build))",
            "Variante: \(input.app.variant)",
            "Sistema: \(input.app.system)",
            "Dispositivo: \(input.app.deviceModel)",
            "Generado: \(timestamp(input.generatedAt))",
            redactor.includesPersonalData
                ? "Datos personales: incluidos a petición del usuario (secretos siempre omitidos)."
                : "Datos personales: ocultos (servidores, usuarios e IPs sustituidos por marcadores).",
        ].joined(separator: "\n"))

        if let doctor = input.doctor {
            let label = redactor.serverLabel(input.serverName ?? "servidor")
            sections.append("## Doctor del servidor\n" + redactor.redact(doctor.plainText(serverLabel: label)))
        } else {
            sections.append("## Doctor del servidor\nSin servidor conectado: no se ejecutó.")
        }

        sections.append(logSection(input.log, redactor: &redactor))
        return sections.joined(separator: "\n\n") + "\n"
    }

    private static func logSection(_ log: DiagnosticLogExcerpt, redactor: inout DiagnosticRedactor) -> String {
        switch log {
        case .unavailable(let reason):
            return "## Registro de la app\nNo disponible en este dispositivo: \(redactor.redact(reason)). "
                + "El resto del informe es válido."
        case .lines(let lines, let truncated):
            guard !lines.isEmpty else {
                return "## Registro de la app (últimos \(DiagnosticLogFormatter.defaultMinutes) min)\nSin entradas."
            }
            let note = truncated ? " (recortado a lo más reciente)" : ""
            let body = lines.map { redactor.redact($0) }.joined(separator: "\n")
            return "## Registro de la app (últimos \(DiagnosticLogFormatter.defaultMinutes) min)\(note)\n" + body
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Reúne los datos reales y compone el informe. Nunca lanza: lo que falle queda indicado en el texto.
    static func collect(
        doctor: DoctorResult?, serverName: String?, knownServers: [DiagnosticRedactor.KnownServer],
        includePersonalData: Bool
    ) async -> String {
        let log = await DiagnosticLogReader.read()
        let input = DiagnosticInput(
            app: .current(), generatedAt: Date(), serverName: serverName, doctor: doctor, log: log
        )
        var redactor = DiagnosticRedactor(knownServers: knownServers, includesPersonalData: includePersonalData)
        return compose(input, redactor: &redactor)
    }
}
