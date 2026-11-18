//
//  PortForwardsUIState.swift
//  Argos
//
//  Estado de interfaz compartido entre el botón «Puertos» y el aviso de solicitudes:
//  con el popover abierto el aviso espera (no se pinta encima), y abrir un túnel desde el
//  aviso actualiza el contador del botón en el acto (no a los 10 s).
//

import Observation

@MainActor
@Observable
final class PortForwardsUIState {
    static let shared = PortForwardsUIState()

    /// Popovers de «Puertos» abiertos ahora mismo.
    private(set) var openPopovers = 0
    /// Sube cada vez que se abre o cierra un túnel fuera del popover.
    private(set) var tunnelsRevision = 0

    var isPopoverOpen: Bool { openPopovers > 0 }

    func popover(isOpen: Bool) {
        openPopovers = max(0, openPopovers + (isOpen ? 1 : -1))
    }

    func tunnelsChanged() {
        tunnelsRevision &+= 1
    }
}
