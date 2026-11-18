//
//  NotificationReadiness.swift
//  Argos
//
//  ¿Pueden llegar los avisos de «Claude terminó / espera tu permiso»? (lógica pura).
//  En iPhone/iPad dependen de tres cosas que el usuario controla en Ajustes de iOS: el
//  permiso de notificaciones, la actualización en segundo plano (BGAppRefreshTask) y el
//  modo de bajo consumo (que la suspende). La vista lee el estado real del sistema, lo
//  traduce a estos tipos y muestra lo que devuelve `issues`.
//

import Foundation

/// Permiso de notificaciones (espejo de `UNAuthorizationStatus` sin importar el framework).
enum NotificationPermission: Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
    /// Provisional o efímero: llegan sin sonido al Centro de notificaciones.
    case quiet
}

/// Actualización en segundo plano (espejo de `UIBackgroundRefreshStatus`).
enum BackgroundRefreshAvailability: Sendable, Equatable {
    case available
    /// Desactivada por el usuario (para Argos o en general).
    case denied
    /// Bloqueada por un perfil o control parental.
    case restricted
}

/// Estado leído del sistema.
struct NotificationReadiness: Sendable, Equatable {
    var permission: NotificationPermission
    /// Alertas desactivadas aunque el permiso esté concedido (`alertSetting`).
    var alertsEnabled: Bool = true
    var backgroundRefresh: BackgroundRefreshAvailability
    var lowPowerMode: Bool

    /// Algo que impide (o limita) los avisos, con lo que puede hacer el usuario.
    enum Issue: Sendable, Equatable, Identifiable {
        /// Aún no se pidió el permiso: se puede pedir desde la app.
        case permissionNotRequested
        /// Denegado: solo se arregla en Ajustes.
        case permissionDenied
        case alertsOff
        case backgroundRefreshOff
        case backgroundRefreshRestricted
        case lowPowerMode

        var id: String { String(describing: self) }

        var title: String {
            switch self {
            case .permissionNotRequested: return "Los avisos están sin activar"
            case .permissionDenied: return "Las notificaciones de Argos están desactivadas"
            case .alertsOff: return "Las alertas de Argos están desactivadas"
            case .backgroundRefreshOff: return "La actualización en segundo plano está desactivada"
            case .backgroundRefreshRestricted: return "La actualización en segundo plano está restringida"
            case .lowPowerMode: return "Modo de bajo consumo activado"
            }
        }

        var detail: String {
            switch self {
            case .permissionNotRequested:
                return "Actívalos para que Argos te avise cuando Claude termine o espere tu permiso."
            case .permissionDenied:
                return "Actívalas en Ajustes → Argos → Notificaciones."
            case .alertsOff:
                return "Argos puede avisar, pero los avisos no se muestran. Revisa Ajustes → Argos → Notificaciones."
            case .backgroundRefreshOff:
                return "Con la app cerrada no se revisan tus servidores. Actívala en Ajustes → Argos → Actualización en segundo plano."
            case .backgroundRefreshRestricted:
                return "Un perfil o el control parental la bloquean: con la app cerrada no se revisan tus servidores."
            case .lowPowerMode:
                return "iOS suspende la actualización en segundo plano mientras dure: los avisos solo llegan con Argos abierto."
            }
        }

        /// Lo arregla el usuario en Ajustes de iOS (y no pidiendo el permiso).
        var needsSettings: Bool { self != .permissionNotRequested && self != .lowPowerMode }

        /// Impide TODOS los avisos (no solo los de segundo plano).
        var blocksAllNotices: Bool {
            switch self {
            case .permissionNotRequested, .permissionDenied, .alertsOff: return true
            case .backgroundRefreshOff, .backgroundRefreshRestricted, .lowPowerMode: return false
            }
        }
    }

    /// Problemas, del más grave al menos.
    var issues: [Issue] {
        var result: [Issue] = []
        switch permission {
        case .notDetermined: result.append(.permissionNotRequested)
        case .denied: result.append(.permissionDenied)
        case .authorized, .quiet: if !alertsEnabled { result.append(.alertsOff) }
        }
        switch backgroundRefresh {
        case .available: if lowPowerMode { result.append(.lowPowerMode) }
        case .denied: result.append(.backgroundRefreshOff)
        case .restricted: result.append(.backgroundRefreshRestricted)
        }
        return result
    }

    /// Resumen de una línea para la hoja «Avisos».
    var summary: String {
        let current = issues
        if current.contains(where: \.blocksAllNotices) { return "Los avisos no pueden llegar." }
        if !current.isEmpty { return "Solo llegan con Argos abierto." }
        return permission == .quiet
            ? "Llegan sin sonido al Centro de notificaciones, también en segundo plano cuando iOS lo permite."
            : "Llegan con Argos abierto y, en segundo plano, cuando iOS lo permite."
    }

    /// Todo en orden.
    var isReady: Bool { issues.isEmpty }
}
