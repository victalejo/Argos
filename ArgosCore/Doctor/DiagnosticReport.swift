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
            version: info?["CFBundleShortVersionString"] as? String ?? String(localized: "desconocida"),
            build: info?["CFBundleVersion"] as? String ?? String(localized: "desconocida"),
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
        guard size > 0 else { return String(localized: "desconocido") }
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
    static func compose(
        _ input: DiagnosticInput, policy: DiagnosticLogPolicy = DiagnosticLogPolicy(), redactor: inout DiagnosticRedactor
    ) -> String {
        var sections: [String] = []

        sections.append([
            String(localized: "## Argos · diagnóstico"),
            String(localized: "Versión: \(input.app.version) (build \(input.app.build))"),
            String(localized: "Variante: \(input.app.variant)"),
            String(localized: "Sistema: \(input.app.system)"),
            String(localized: "Dispositivo: \(input.app.deviceModel)"),
            String(localized: "Generado: \(timestamp(input.generatedAt))"),
            redactor.includesPersonalData
                ? String(localized: "Datos personales: incluidos a petición del usuario (los secretos que Argos reconoce se omiten siempre).")
                : String(localized: "Datos personales: ocultos (servidores, usuarios e IPs sustituidos por marcadores)."),
        ].joined(separator: "\n"))

        if let doctor = input.doctor {
            let label = redactor.serverLabel(input.serverName ?? "servidor")
            sections.append(String(localized: "## Doctor del servidor\n") + redactor.redact(doctor.plainText(serverLabel: label)))
        } else {
            sections.append(String(localized: "## Doctor del servidor\nSin servidor conectado: no se ejecutó."))
        }

        sections.append(logSection(input.log, policy: policy, redactor: &redactor))
        sections.append(reviewReminder)
        // Pasada final sobre todo el informe: los secretos no dependen de ninguna sección.
        return DiagnosticSecretScrubber.scrub(sections.joined(separator: "\n\n")) + "\n"
    }

    private static func logSection(
        _ log: DiagnosticLogExcerpt, policy: DiagnosticLogPolicy, redactor: inout DiagnosticRedactor
    ) -> String {
        let title = String(localized: "## Registro de la app (últimos \(DiagnosticLogFormatter.defaultMinutes) min)")
        switch log {
        case .unavailable(let reason):
            return String(localized: "## Registro de la app\nNo disponible en este dispositivo: \(redactor.redact(reason)). El resto del informe es válido.")
        case .entries(let entries):
            let admitted = entries.filter(policy.admits)
            let omitted = entries.count - admitted.count
            // Orden: filtrar → redactar → recortar cada línea → recortar el total (siempre al final).
            let redacted = admitted.map {
                DiagnosticLogFormatter.clip(redactor.redact(DiagnosticLogFormatter.format($0)), to: policy.maxLineCharacters)
            }
            let (kept, truncated) = DiagnosticLogFormatter.newest(of: redacted, maxBytes: policy.maxBytes)
            var notes: [String] = []
            if truncated { notes.append(String(localized: "recortado a lo más reciente")) }
            if omitted > 0 {
                notes.append(String(localized: "\(omitted) entradas de depuración o del agente omitidas: pueden contener texto del servidor"))
            }
            let header = title + (notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))")
            return kept.isEmpty ? header + String(localized: "\nSin entradas.") : header + "\n" + kept.joined(separator: "\n")
        }
    }

    static let reviewReminder =
        String(localized: "Revisa este texto antes de publicarlo: Argos oculta los secretos y datos personales que reconoce, pero no puede garantizar que no se escape alguno.")

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Reúne los datos reales y compone el informe. Nunca lanza: lo que falle queda indicado en el texto.
    static func collect(
        doctor: DoctorResult?, serverName: String?, knownServers: [DiagnosticRedactor.KnownServer],
        includePersonalData: Bool,
        includesTechnicalDetail: Bool = false
    ) async -> String {
        let log = await DiagnosticLogReader.read()
        let input = DiagnosticInput(
            app: .current(), generatedAt: Date(), serverName: serverName, doctor: doctor, log: log
        )
        var redactor = DiagnosticRedactor(knownServers: knownServers, includesPersonalData: includePersonalData)
        return compose(input, policy: DiagnosticLogPolicy(includesTechnicalDetail: includesTechnicalDetail), redactor: &redactor)
    }
}
