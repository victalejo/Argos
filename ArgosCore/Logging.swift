//
//  Logging.swift
//  Argos
//
//  Logging estructurado con os.Logger. Un cliente SSH/PTY tiene fallos difíciles
//  (handshake, host key, PTY que muere, cancelaciones a destiempo) que antes no
//  dejaban rastro fuera de la UI. Cada categoría agrupa un subsistema funcional;
//  los logs son visibles en Console.app filtrando por subsystem "…argos".
//

import Foundation
import os

/// Puntos de entrada de logging por categoría funcional.
enum Log {
    private static let subsystem = "com.iaportafolio.argos"

    /// Conexión SSH y ejecución de comandos.
    static let ssh = Logger(subsystem: subsystem, category: "ssh")
    /// Terminal en vivo (PTY, feeder, ciclo de vida).
    static let terminal = Logger(subsystem: subsystem, category: "terminal")
    /// Verificación TOFU de host key y su persistencia.
    static let hostKey = Logger(subsystem: subsystem, category: "hostkey")
    /// Almacén de servidores y Keychain.
    static let store = Logger(subsystem: subsystem, category: "store")
    /// Panel de agente de Claude Code (proceso remoto, protocolo stream-json).
    static let agent = Logger(subsystem: subsystem, category: "agent")
}
