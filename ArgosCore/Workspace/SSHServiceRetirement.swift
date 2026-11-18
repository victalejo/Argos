//
//  SSHServiceRetirement.swift
//  ArgosCore
//
//  Un servicio cuyo view model se descartó (servidor borrado o con conexión nueva) se
//  RETIRA: se desconecta y ya no vuelve a abrir conexiones. Antes, una hoja que aún lo
//  tenía (Enviar al iPhone, Doctor…) lo reconectaba bajo demanda con la configuración
//  antigua y nadie cerraba esa conexión.
//

import Foundation

/// Se lanza al usar un servicio retirado.
struct SSHServiceRetiredError: LocalizedError, Equatable {
    let host: String

    var errorDescription: String? {
        String(localized: "La conexión con \(host) se cerró porque el servidor cambió o se eliminó. Cierra esta ventana y vuelve a abrirla.")
    }
}

extension SSHService {
    func retire() async {
        isRetired = true
        await disconnect()
        Log.ssh.notice("Servicio SSH retirado: \(self.configuration.host, privacy: .public)")
    }
}

extension SSHServicing {
    /// Dobles de prueba: retirar es desconectar.
    func retire() async {
        await disconnect()
    }
}
