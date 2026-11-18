//
//  RefreshPlan.swift
//  ArgosCore
//
//  «Refrescar todo» (⌘R en el Mac): antes llamaba a `load()` en todos los servidores, lo
//  que pasaba por `.verifying`/`.loading` (parpadeo del detalle), repetía el arranque de
//  tmux y conectaba los servidores que aún no se habían abierto.
//

/// Qué hace ⌘R con cada servidor según su estado (lógica pura).
enum RefreshPlan: Equatable {
    case refresh
    case load
    case skip

    static func action(for state: SessionsLoadState) -> RefreshPlan {
        switch state {
        case .loaded: return .refresh
        case .failed, .hostKeyChanged, .tmuxMissing: return .load
        case .idle, .verifying, .installing, .configuring, .loading: return .skip
        }
    }
}
