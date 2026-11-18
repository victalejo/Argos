//
//  RemoteUpload.swift
//  Argos
//
//  Reglas puras de las subidas a `/tmp` del servidor (capturas pegadas y archivos
//  arrastrados). `/tmp` lo comparten todos los usuarios, así que:
//   - el nombre lleva una parte aleatoria: otro usuario no puede adivinarlo de antemano;
//   - se abre con SSH_FXF_EXCL: si la ruta ya existe (también si es un enlace simbólico
//     preparado por otro), la subida falla en vez de escribir a través de ella;
//   - se crea con permisos 0600: nadie más puede leer el contenido.
//

import Foundation

enum RemoteUpload {

    /// SSH_FXF_WRITE | SSH_FXF_CREAT | SSH_FXF_EXCL.
    static let exclusiveOpenFlags: UInt32 = 0x02 | 0x08 | 0x20
    static let privatePermissions: UInt32 = 0o600

    static func pastedPath(fileExtension: String, now: Date = Date()) -> String {
        "/tmp/argos-pasted-\(uniqueStamp(now)).\(fileExtension)"
    }

    /// Conserva el nombre original (saneado) para que sea reconocible en el terminal.
    static func droppedPath(originalName: String, now: Date = Date()) -> String {
        "/tmp/argos-\(uniqueStamp(now))-\(sanitize(originalName))"
    }

    /// Lista de rutas para `git … --pathspec-from-file` (se borra al terminar el commit).
    static func pathspecPath(now: Date = Date()) -> String {
        "/tmp/argos-pathspec-\(uniqueStamp(now))"
    }

    /// Días que se conservan las subidas en `/tmp` (una captura pegada puede seguir
    /// citada en una conversación de Claude un tiempo).
    static let retentionDays = 3

    /// Borra las subidas antiguas DE ESTE USUARIO: solo archivos normales (nunca enlaces
    /// ni carpetas), directamente en `/tmp` y con los nombres que genera este archivo. `find` no sigue
    /// enlaces, así que no puede borrar nada fuera de `/tmp`.
    static let staleCleanupCommand =
        "find /tmp -maxdepth 1 -type f \\( -name 'argos-pasted-*' -o -name 'argos-pathspec-*' -o -name 'argos-[0-9]*-*' \\) -user \"$(id -u)\" -mmin +\(retentionDays * 24 * 60) "
        + "-exec rm -f -- {} + 2>/dev/null; exit 0"

    private static func uniqueStamp(_ now: Date) -> String {
        let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "\(Int(now.timeIntervalSince1970 * 1000))-\(random)"
    }

    /// Deja solo `[A-Za-z0-9._-]`, el resto → `_`. Evita rutas, espacios y caracteres que
    /// romperían la ruta al insertarla en el terminal.
    private static func sanitize(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let result = String(base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return result.isEmpty ? "archivo" : result
    }
}
