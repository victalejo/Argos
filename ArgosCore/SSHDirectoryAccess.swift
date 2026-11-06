//
//  SSHDirectoryAccess.swift
//  ArgosCore
//
//  Acceso a ~/.ssh del usuario (config y claves referenciadas por ruta).
//
//  · Canal GitHub: la excepción temporal de sandbox `home-relative-path /.ssh/` deja
//    leer la carpeta sin más (estado `.implicit`).
//  · Canal App Store: sin excepciones; el usuario concede UNA vez la carpeta ~/.ssh
//    con un panel y se guarda como bookmark de solo lectura (estado `.granted`).
//
//  Toda lectura dentro de ~/.ssh pasa por `withAccess`, que abre el scope del bookmark
//  si existe y si no lee directamente. Así el mismo código sirve a ambos canales.
//

import Foundation

enum SSHDirectoryAccess {

    /// Clave de UserDefaults con el bookmark de la carpeta ~/.ssh.
    static let bookmarkKey = "sshDirectoryBookmark"

    enum Status: Equatable, Sendable {
        /// El usuario concedió la carpeta (bookmark guardado).
        case granted
        /// Se puede leer sin permiso explícito (excepción de sandbox o sin sandbox).
        case implicit
        /// Hay que pedir al usuario que conceda la carpeta.
        case needsGrant
    }

    // MARK: - Rutas (lógica pura)

    /// Home POSIX real del usuario. Bajo App Sandbox `NSHomeDirectory()` apunta al
    /// container; `getpwuid` devuelve siempre el home real.
    static var realHome: String {
        if let pw = getpwuid(getuid()) {
            return String(cString: pw.pointee.pw_dir)
        }
        return NSHomeDirectory()
    }

    static func directoryPath(home: String = realHome) -> String {
        home + "/.ssh"
    }

    /// Expande `~` y `~/…` al home indicado. No toca rutas absolutas ni `~usuario`.
    static func expandTilde(_ path: String, home: String = realHome) -> String {
        if path == "~" { return home }
        guard path.hasPrefix("~/") else { return path }
        return home + path.dropFirst()
    }

    /// ¿La ruta (normalizada, sin `..`) está dentro de ~/.ssh o es la propia carpeta?
    static func isInsideSSHDirectory(_ path: String, home: String = realHome) -> Bool {
        guard !path.isEmpty else { return false }
        let standardized = URL(fileURLWithPath: expandTilde(path, home: home)).standardizedFileURL.path
        let directory = directoryPath(home: home)
        return standardized == directory || standardized.hasPrefix(directory + "/")
    }

    static func status(hasGrant: Bool, directoryReadable: Bool) -> Status {
        if hasGrant { return .granted }
        return directoryReadable ? .implicit : .needsGrant
    }

    /// Estado actual en este proceso.
    static func currentStatus(defaults: UserDefaults = .standard) -> Status {
        status(
            hasGrant: hasGrant(defaults: defaults),
            directoryReadable: FileManager.default.isReadableFile(atPath: directoryPath())
        )
    }

    /// Pista para el error «no se pudo leer la clave» cuando falta conceder ~/.ssh.
    static func unreadableKeyHint(path: String, hasGrant: Bool, home: String = realHome) -> String? {
        guard !hasGrant, isInsideSSHDirectory(path, home: home) else { return nil }
        return "Argos necesita permiso para leer tu carpeta ~/.ssh: concédelo en Ajustes → Permisos, "
            + "o elige el archivo de la clave en el formulario del servidor."
    }

    // MARK: - Permiso persistido

    static func hasGrant(defaults: UserDefaults = .standard) -> Bool {
        defaults.data(forKey: bookmarkKey) != nil
    }

    static func revoke(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: bookmarkKey)
    }

    /// Guarda el bookmark de solo lectura de la carpeta elegida por el usuario.
    static func storeGrant(for url: URL, defaults: UserDefaults = .standard) throws {
        #if os(macOS)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        let data = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: bookmarkKey)
    }

    // MARK: - Lectura con permiso

    /// Ejecuta `body` con acceso a ~/.ssh: abre el scope del bookmark si existe (y lo
    /// renueva si quedó obsoleto); si no, ejecuta el bloque leyendo directamente.
    static func withAccess<T>(defaults: UserDefaults = .standard, _ body: () throws -> T) rethrows -> T {
        guard let url = resolveGrant(defaults: defaults) else { return try body() }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    private static func resolveGrant(defaults: UserDefaults) -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                try? storeGrant(for: url, defaults: defaults)
            }
            return url
        } catch {
            Log.store.error("No se pudo resolver el permiso de ~/.ssh: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
