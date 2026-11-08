package com.iaportafolio.argos.core.files

import java.time.Instant

/**
 * Una entrada de directorio del servidor (port de `ArgosCore/Files/RemoteFileEntry.swift`).
 *
 * Lógica pura del explorador remoto: tipo desde `st_mode`, orden (carpetas primero, orden
 * natural) y carpetas pesadas que se ocultan por defecto.
 */
data class RemoteFileEntry(
    val name: String,
    /** Ruta absoluta en el servidor (también es su identificador). */
    val path: String,
    val kind: Kind,
    val size: Long? = null,
    val modified: Instant? = null,
) {
    enum class Kind { DIRECTORY, FILE, SYMLINK }

    val id: String get() = path
    val isDirectory: Boolean get() = kind == Kind.DIRECTORY
    val isHidden: Boolean get() = name.startsWith(".")

    /** ¿Se muestra con la configuración actual? */
    fun isVisible(showHidden: Boolean): Boolean {
        if (showHidden) return true
        if (isHidden) return false
        return !(isDirectory && name in NOISY_DIRECTORIES)
    }

    companion object {
        // Bits de tipo de `st_mode` (POSIX).
        private const val TYPE_MASK = 0xF000 // 0o170000
        private const val DIRECTORY_BITS = 0x4000 // 0o040000
        private const val SYMLINK_BITS = 0xA000 // 0o120000

        /** Carpetas pesadas o generadas que se ocultan salvo que el usuario las muestre. */
        val NOISY_DIRECTORIES: Set<String> = setOf(
            ".git", "node_modules", ".next", ".nuxt", "dist", "build", "out", ".turbo",
            ".cache", "__pycache__", ".venv", "venv", ".mypy_cache", ".pytest_cache",
            "target", ".gradle", "Pods", "DerivedData", ".svelte-kit", "coverage",
        )

        /** Construye la entrada a partir de los atributos SFTP (`permissions` = `st_mode`). */
        fun fromAttributes(
            name: String,
            parent: String,
            permissions: Int?,
            size: Long?,
            modified: Instant?,
        ): RemoteFileEntry {
            val kind = when ((permissions ?: 0) and TYPE_MASK) {
                DIRECTORY_BITS -> Kind.DIRECTORY
                SYMLINK_BITS -> Kind.SYMLINK
                else -> Kind.FILE
            }
            return RemoteFileEntry(name, RemotePath.join(parent, name), kind, size, modified)
        }

        /** Carpetas primero; dentro de cada grupo, orden natural ("file2" < "file10"). */
        fun sorted(entries: List<RemoteFileEntry>): List<RemoteFileEntry> =
            entries.sortedWith(
                compareByDescending<RemoteFileEntry> { it.isDirectory }
                    .thenComparator { a, b -> NaturalOrder.compare(a.name, b.name) },
            )
    }
}
