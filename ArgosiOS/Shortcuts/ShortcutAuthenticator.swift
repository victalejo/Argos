//
//  ShortcutAuthenticator.swift
//  ArgosiOS
//
//  El bloqueo de Argos (Face ID / Touch ID / código) también vale para los atajos: con
//  el bloqueo activo, «Pedir a Claude» pide la misma autenticación que abrir la app antes
//  de conectar con el servidor. Si el atajo corre sin interfaz y no puede pedirla, se
//  niega y propone abrir Argos para desbloquear allí. La decisión es `AppLockPolicy`.
//

import AppIntents
import Foundation
import LocalAuthentication

@MainActor
enum ShortcutAuthenticator {

    /// Exige el desbloqueo de Argos si está activo. Lanza `ShortcutError.appLocked` si el
    /// usuario no se autentica, o el error de «continuar en la app» si aquí no se puede.
    static func requireUnlock<Intent: ForegroundContinuableIntent>(
        for intent: Intent,
        defaults: UserDefaults = .standard
    ) async throws {
        let enabled = defaults.bool(forKey: AppLockPolicy.enabledKey)
        guard AppLockPolicy.shortcutRequiresAuthentication(enabled: enabled) else { return }
        let outcome = await authenticate(reason: String(localized: "Desbloquea Argos para mandar el encargo a Claude."))
        switch AppLockPolicy.shortcutDecision(enabled: enabled, authentication: outcome) {
        case .proceed:
            return
        case .refuse:
            throw ShortcutError.appLocked
        case .continueInApp:
            // Sin continuación: la app se abre y su propio bloqueo pide la cara; el encargo
            // NO se manda (el usuario vuelve a lanzar el atajo ya desbloqueado).
            throw intent.needsToContinueInForegroundError(
                IntentDialog(stringLiteral: String(localized: "Argos está bloqueado. Ábrelo para desbloquearlo y vuelve a lanzar el atajo."))
            )
        }
    }

    /// Mismo criterio que `AppLock`: `.deviceOwnerAuthentication` (biometría o código).
    private static func authenticate(reason: String) async -> AppLockPolicy.ExternalAuthentication {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            Log.store.notice("Atajo: sin código ni biometría (\(error?.localizedDescription ?? "-", privacy: .public))")
            return .unavailable
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .succeeded : .refused
        } catch {
            return outcome(for: error)
        }
    }

    private static func outcome(for error: Error) -> AppLockPolicy.ExternalAuthentication {
        switch (error as? LAError)?.code {
        case .notInteractive?, .systemCancel?, .appCancel?:
            return .notPossibleHere
        case .passcodeNotSet?:
            return .unavailable
        default:
            Log.store.notice("Atajo: no se desbloqueó Argos: \(error.localizedDescription, privacy: .public)")
            return .refused
        }
    }
}
