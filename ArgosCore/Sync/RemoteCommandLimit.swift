//
//  RemoteCommandLimit.swift
//  Argos
//
//  Linux limita CADA argumento de `execve` a 128 KiB (`MAX_ARG_STRLEN`). Por SSH, el
//  comando entero llega como UN argumento del shell de login (`$SHELL -c '…'`) y, con
//  `ShellQuoting.posixShell`, otra vez como argumento de `sh -c`. Un comando más largo
//  falla en el servidor con «Argument list too long», sin explicación para el usuario.
//
//  Aquí: el tope (con margen), la comprobación antes de enviar y el troceo en lotes de
//  una lista de argumentos ya entrecomillados.
//

import Foundation

enum RemoteCommandLimit {
    /// Bytes máximos de un comando remoto (margen bajo los 131.072 de Linux: el shell
    /// de login puede envolverlo y `posixShell` cuadruplica cada comilla simple).
    static let maxCommandBytes = 100_000
    /// Bytes por lote al trocear listas de rutas (deja sitio al resto del script).
    static let batchBytes = 48_000

    /// Lanza `RemoteCommandError.tooLong` si `command` no cabe en un argumento.
    static func check(_ command: String) throws {
        let bytes = command.utf8.count
        guard bytes <= maxCommandBytes else { throw RemoteCommandError.tooLong(bytes: bytes) }
    }

    /// Reparte `items` (fragmentos YA entrecomillados) en lotes de como mucho `maxBytes`
    /// (contando el separador) sin partir ningún elemento. Un elemento mayor que el tope
    /// va solo en su lote (la comprobación final del comando dirá si cabe).
    static func batches(_ items: [String], maxBytes: Int = batchBytes) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        var size = 0
        for item in items {
            let length = item.utf8.count + 1
            if !current.isEmpty, size + length > maxBytes {
                result.append(current)
                current = []
                size = 0
            }
            current.append(item)
            size += length
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

enum RemoteCommandError: LocalizedError, Equatable {
    case tooLong(bytes: Int)

    var errorDescription: String? {
        switch self {
        case .tooLong(let bytes):
            return String(localized: "La orden para el servidor es demasiado larga (\(bytes / 1024) KiB; Linux admite unos 128 KiB). Hazlo con menos archivos a la vez.")
        }
    }
}
