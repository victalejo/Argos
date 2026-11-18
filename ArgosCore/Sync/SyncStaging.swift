//
//  SyncStaging.swift
//  Argos
//
//  «Enviar al servidor» sin ventana de pérdida (lógica pura, testeable). Cada archivo se
//  sube a `<ruta>.argos-up` (con sus permisos y fecha ya puestos) y, cuando TODOS están
//  subidos, se colocan con `mv -f` en el servidor, por lotes: `rename(2)` reemplaza el
//  destino de forma atómica (SFTP v3 no sabe renombrar encima de un archivo, y borrar
//  antes el destino dejaba un hueco en el que un corte de red perdía el archivo).
//
//  Si algo falla antes de colocar, se borran los temporales y el servidor queda como
//  estaba. Los huérfanos de un envío interrumpido se ignoran en los listados y se borran
//  al empezar el siguiente envío.
//

import Foundation

enum SyncStaging {
    /// Sufijo de los temporales de subida.
    static let suffix = ".argos-up"
    /// Minutos que debe tener un temporal para considerarlo huérfano (otro envío en curso
    /// desde otro Mac no se toca).
    static let staleMinutes = 30

    static func temporaryPath(for remotePath: String) -> String { remotePath + suffix }

    static func isTemporary(_ relativePath: String) -> Bool { relativePath.hasSuffix(suffix) }

    private static func q(_ value: String) -> String { ShellQuoting.singleQuoted(value) }

    /// Funciones del script de colocación. `place` NUNCA renombra sobre una carpeta (mv
    /// metería el archivo dentro) y, si el destino es un enlace, lo quita antes (mv lo
    /// seguiría si apunta a una carpeta). `link` prepara el enlace en el temporal.
    static let placeFunctions = """
    fail=0
    place() {
      if [ -L "$1" ]; then rm -f -- "$1" || { fail=1; return; }
      elif [ -d "$1" ]; then printf 'No se puede reemplazar la carpeta %s\\n' "$1" >&2; rm -f -- "$1\(suffix)"; fail=1; return
      fi
      mv -f -- "$1\(suffix)" "$1" || fail=1
    }
    link() { rm -f -- "$1\(suffix)" && ln -s -- "$2" "$1\(suffix)" && place "$1" || fail=1; }
    """

    /// Una línea del script por archivo (rutas relativas a la raíz, ya validadas).
    static func placeLine(_ file: SyncFile) -> String {
        if let target = file.linkTarget { return "link \(q(file.path)) \(q(target))" }
        return "place \(q(file.path))"
    }

    /// Comandos (ya envueltos en `sh -c`) que colocan `files`, en lotes que caben en un
    /// argumento. Salen con 1 si algún archivo no se pudo colocar (los demás sí).
    static func placeCommands(root: String, files: [SyncFile]) -> [String] {
        let lines = files.filter { SyncPath.isSafeRelative($0.path) }.map(placeLine)
        return RemoteCommandLimit.batches(lines).map { batch in
            ShellQuoting.posixShell(
                "cd \(q(root)) || exit 1\n\(placeFunctions)\n\(batch.joined(separator: "\n"))\nexit $fail"
            )
        }
    }

    /// Borra los temporales de `paths` (camino de error), por lotes.
    static func discardCommands(root: String, paths: [String]) -> [String] {
        let temporaries = paths.filter(SyncPath.isSafeRelative).map { q($0 + suffix) }
        return RemoteCommandLimit.batches(temporaries).map { batch in
            ShellQuoting.posixShell("cd \(q(root)) || exit 1; rm -f -- \(batch.joined(separator: " "))")
        }
    }

    /// Borra los temporales huérfanos (más de `staleMinutes`) de envíos interrumpidos.
    /// Solo archivos y enlaces del proyecto (sin entrar en carpetas excluidas ni seguir
    /// enlaces: `find` no los sigue por defecto).
    static func staleCleanupCommand(root: String) -> String {
        let prune = SyncExclusions.directories.sorted()
            .map { "-name \(q($0))" }
            .joined(separator: " -o ")
        return ShellQuoting.posixShell(
            "cd \(q(root)) || exit 0; find . \\( \(prune) \\) -prune -o "
                + "\\( -type f -o -type l \\) -name \(q("*" + suffix)) -mmin +\(staleMinutes) -exec rm -f -- {} +"
        )
    }
}
