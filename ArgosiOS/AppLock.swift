//
//  AppLock.swift
//  ArgosiOS
//
//  Bloqueo opcional con Face ID / Touch ID (o el código del dispositivo) al abrir la
//  app y al volver de segundo plano tras un margen (`AppLockPolicy`). Mientras está
//  bloqueada, o fuera de primer plano con el ajuste activo, una portada tapa el
//  contenido: así tampoco se ve en el selector de apps.
//

import LocalAuthentication
import Observation
import SwiftUI

@MainActor
@Observable
final class AppLock {
    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    private(set) var lastError: String?
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private let defaults: UserDefaults

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: AppLockPolicy.enabledKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: AppLockPolicy.enabledKey)
        self.isEnabled = enabled
        self.isLocked = AppLockPolicy.shouldLock(enabled: enabled, backgroundedAt: nil, now: Date())
    }

    /// Nombre del método disponible («Face ID», «Touch ID», «Optic ID» o el código).
    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "el código del dispositivo"
        }
    }

    // MARK: - Ciclo de vida

    func didEnterBackground() {
        backgroundedAt = Date()
    }

    /// Al volver: bloquea si pasó el margen y pide desbloquear.
    func didBecomeActive() {
        if !isLocked, AppLockPolicy.shouldLock(enabled: isEnabled, backgroundedAt: backgroundedAt ?? Date(), now: Date()) {
            isLocked = true
        }
        backgroundedAt = nil
        if isLocked { Task { await unlock() } }
    }

    // MARK: - Desbloqueo

    func unlock() async {
        guard isEnabled else {
            isLocked = false
            return
        }
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        if await authenticate(reason: "Desbloquea Argos para ver tus servidores.") {
            isLocked = false
            lastError = nil
        }
    }

    /// Activa o desactiva el ajuste confirmando la identidad (así no lo cambia otro).
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        let reason = enabled ? "Confirma para pedir \(Self.biometryName) al abrir Argos." : "Confirma para dejar de bloquear Argos."
        guard await authenticate(reason: reason) else { return }
        isEnabled = enabled
        isLocked = false
    }

    private func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastError = "Este dispositivo no tiene código ni \(Self.biometryName) configurado."
            Log.store.notice("Bloqueo de la app no disponible: \(error?.localizedDescription ?? "-", privacy: .public)")
            // Sin forma de autenticar no se deja la app inaccesible.
            if !isEnabled { return false }
            isEnabled = false
            return true
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            let code = (error as? LAError)?.code
            if code != .userCancel && code != .appCancel && code != .systemCancel {
                lastError = error.localizedDescription
                Log.store.notice("No se pudo desbloquear Argos: \(error.localizedDescription, privacy: .public)")
            }
            return false
        }
    }
}

/// Portada que tapa la app bloqueada (y en el selector de apps).
struct AppLockCover: View {
    let lock: AppLock
    let isActive: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tint)
                Text("Argos está bloqueado").font(.title3.weight(.semibold))
                if lock.isLocked && isActive {
                    Button("Desbloquear con \(AppLock.biometryName)") { Task { await lock.unlock() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(lock.isAuthenticating)
                    if let error = lock.lastError {
                        Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
            }
            .padding(32)
        }
        .ignoresSafeArea()
        .accessibilityAddTraits(.isModal)
    }
}
