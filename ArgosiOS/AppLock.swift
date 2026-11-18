//
//  AppLock.swift
//  ArgosiOS
//
//  Bloqueo opcional con Face ID / Touch ID (o el código del dispositivo) al abrir la
//  app y al volver de segundo plano tras un margen (`AppLockPolicy`). Mientras está
//  bloqueada, o fuera de primer plano con el ajuste activo, una portada en una ventana
//  propia (`AppLockWindows`, por encima de hojas y alertas) tapa el contenido: tampoco
//  se ve en el selector de apps. Bloqueada, los enlaces y avisos tocados esperan.
//

import LocalAuthentication
import Observation
import SwiftUI
import UIKit

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

    /// Solo para crear la ventana antes de tener el de verdad.
    static let placeholder = AppLock(defaults: UserDefaults(suiteName: "argos.applock.placeholder") ?? .standard)

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
        default: return String(localized: "el código del dispositivo")
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
        if await authenticate(reason: String(localized: "Desbloquea Argos para ver tus servidores.")) {
            isLocked = false
            lastError = nil
        }
    }

    /// Activa o desactiva el ajuste confirmando la identidad (así no lo cambia otro).
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        let reason = enabled ? String(localized: "Confirma para pedir \(Self.biometryName) al abrir Argos.") : String(localized: "Confirma para dejar de bloquear Argos.")
        guard await authenticate(reason: reason) else { return }
        isEnabled = enabled
        isLocked = false
    }

    private func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastError = String(localized: "Este dispositivo no tiene código ni \(Self.biometryName) configurado.")
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

/// Ventana propia para la portada, por encima de TODO (hojas, `fullScreenCover`,
/// alertas y diálogos: un `.overlay` de SwiftUI quedaría debajo de lo ya presentado y
/// se podría seguir usando). Una por escena (iPad con varias ventanas).
@MainActor
final class AppLockWindows {
    static let shared = AppLockWindows()
    private var windows: [ObjectIdentifier: UIWindow] = [:]

    /// Muestra u oculta la portada en todas las escenas conectadas.
    func update(cover: Bool, lock: AppLock, isActive: Bool) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let alive = Set(scenes.map(ObjectIdentifier.init))
        windows = windows.filter { alive.contains($0.key) }
        for scene in scenes {
            let key = ObjectIdentifier(scene)
            guard cover else {
                windows[key]?.isHidden = true
                continue
            }
            let window = windows[key] ?? makeWindow(for: scene)
            windows[key] = window
            (window.rootViewController as? UIHostingController<AppLockCover>)?.rootView = AppLockCover(lock: lock, isActive: isActive)
            window.isHidden = false
            if isActive { window.makeKey() }
        }
    }

    private func makeWindow(for scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        // Por encima de las alertas del sistema de la app.
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: AppLockCover(lock: AppLock.placeholder, isActive: false))
        host.view.backgroundColor = .systemBackground
        window.rootViewController = host
        return window
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
