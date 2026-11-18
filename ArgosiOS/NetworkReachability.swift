//
//  NetworkReachability.swift
//  ArgosiOS
//
//  Avisa cuando vuelve la red (`NWPathMonitor`): sin red → con red, o al cambiar de
//  interfaz (wifi ↔ datos), que deja muertas las conexiones TCP abiertas. Así un
//  terminal caído reintenta en el acto en vez de esperar a su próximo plazo.
//

import Foundation
import Network

@MainActor
final class NetworkReachability {
    /// Se llama en el hilo principal al recuperar la red o cambiar de interfaz.
    var onRestored: (() -> Void)?

    private let monitor = NWPathMonitor()
    private var wasSatisfied: Bool?
    private var lastInterfaces: [NWInterface.InterfaceType] = []

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let interfaces = path.availableInterfaces.map(\.type)
            Task { @MainActor [weak self] in self?.update(satisfied: satisfied, interfaces: interfaces) }
        }
        monitor.start(queue: DispatchQueue(label: "argos.network-reachability"))
    }

    deinit { monitor.cancel() }

    private func update(satisfied: Bool, interfaces: [NWInterface.InterfaceType]) {
        defer {
            wasSatisfied = satisfied
            lastInterfaces = interfaces
        }
        // La primera lectura solo fija el punto de partida.
        guard let wasSatisfied, satisfied else { return }
        let changedInterface = interfaces.first != lastInterfaces.first
        guard !wasSatisfied || changedInterface else { return }
        Log.terminal.info("La red volvió o cambió de interfaz: se reintentan los terminales caídos")
        onRestored?()
    }
}
