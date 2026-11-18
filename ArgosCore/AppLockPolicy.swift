//
//  AppLockPolicy.swift
//  Argos
//
//  Bloqueo opcional con Face ID / Touch ID al abrir la app (lógica pura). Argos es un
//  shell sobre los servidores del usuario: quien coja el teléfono desbloqueado no debe
//  poder entrar en ellos. Se bloquea al arrancar y al volver de segundo plano tras un
//  margen (cambiar un momento de app no pide la cara cada vez).
//

import Foundation

enum AppLockPolicy {
    /// Clave de `UserDefaults` del ajuste (desactivado por defecto).
    static let enabledKey = "security.appLock.enabled"
    /// Tiempo en segundo plano a partir del cual se vuelve a pedir.
    static let gracePeriod: TimeInterval = 60

    /// ¿Hay que bloquear al volver? `backgroundedAt == nil`: arranque en frío.
    static func shouldLock(
        enabled: Bool,
        backgroundedAt: Date?,
        now: Date,
        gracePeriod: TimeInterval = gracePeriod
    ) -> Bool {
        guard enabled else { return false }
        guard let backgroundedAt else { return true }
        // Reloj cambiado hacia atrás: no se puede saber cuánto pasó, se bloquea.
        let elapsed = now.timeIntervalSince(backgroundedAt)
        return elapsed < 0 || elapsed >= gracePeriod
    }

    /// Se tapa el contenido (selector de apps, captura del sistema) si el bloqueo está
    /// activo y la app no está delante, o si está bloqueada. La portada va en una
    /// ventana propia por encima de hojas y alertas: tapa TODO lo presentado.
    static func shouldCover(enabled: Bool, isLocked: Bool, isActive: Bool) -> Bool {
        enabled && (isLocked || !isActive)
    }

    /// Un enlace entrante (`argos://add-server`) o el toque en una notificación se
    /// guardan y se atienden tras desbloquear: bloqueada, la app no hace nada.
    static func shouldDeferIncoming(enabled: Bool, isLocked: Bool) -> Bool {
        enabled && isLocked
    }

    /// Lo encolado mientras estaba bloqueada: solo el ÚLTIMO destino (abrir varios
    /// seguidos al desbloquear sería confuso). `nil` si se puede atender ya.
    static func deferring<Item>(_ item: Item, enabled: Bool, isLocked: Bool) -> Item? {
        shouldDeferIncoming(enabled: enabled, isLocked: isLocked) ? item : nil
    }
}
