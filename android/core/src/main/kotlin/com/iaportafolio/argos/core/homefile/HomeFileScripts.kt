package com.iaportafolio.argos.core.homefile

import com.iaportafolio.argos.core.ShellQuoting

/*
 * Escritura de ficheros de configuración en el $HOME del servidor (port de la parte pura de
 * `ArgosCore/RemotePrivateFile.swift`: `HomeFileExpectation`, `HomeFileError`, `HomeFileScripts`).
 * Los comparten el Mac, el iPhone/iPad y Android, así que el protocolo es el MISMO byte a byte:
 *  - el contenido viaja por SFTP, nunca en la línea de comandos;
 *  - todo bajo `umask 077` (temporal, copia y fichero final en 600);
 *  - temporal propio `<fichero>.argos-tmp-<token>` + `mv`, bajo el cerrojo `<fichero>.argos-lock`
 *    (un `mkdir` atómico) compartido por todos los dispositivos;
 *  - nunca se escribe A TRAVÉS de un enlace simbólico;
 *  - opcionalmente, solo si el fichero sigue siendo el que se leyó ([HomeFileExpectation]).
 */

/** Qué debe haber en el fichero justo antes de reemplazarlo. */
sealed interface HomeFileExpectation {
    /** Sin comprobación. */
    data object Any : HomeFileExpectation

    /** Inexistente o vacío. */
    data object AbsentOrEmpty : HomeFileExpectation

    /** Lo que imprime `cksum` del contenido leído ([PosixChecksum.fingerprint]). */
    data class Fingerprint(val value: String) : HomeFileExpectation

    companion object {
        /** `null` = el fichero leído estaba vacío o no existía. */
        fun expected(fingerprint: String?): HomeFileExpectation = fingerprint?.let(::Fingerprint) ?: AbsentOrEmpty
    }
}

/** Resultado de una escritura condicionada. */
enum class HomeFileWriteOutcome {
    WRITTEN,

    /** El fichero cambió desde que se leyó: no se escribió nada. */
    CONFLICT,
}

/** Fallos propios de la escritura (los textos son los de Apple). */
sealed class HomeFileException(message: String) : Exception(message) {
    class Locked(val path: String) :
        HomeFileException("Otro dispositivo está guardando ~/$path en el servidor. Vuelve a intentarlo en unos segundos.")

    class Symlink(val path: String) : HomeFileException(
        "~/$path es un enlace simbólico y Argos no lo reemplaza. Sustitúyelo por un archivo normal en el servidor.",
    )

    class UnsafePath(val path: String) : HomeFileException("Ruta de configuración no válida: $path.")
}

/**
 * Scripts de escritura (puros). `relativePath` lo fija el código, nunca el usuario, y solo admite
 * `[A-Za-z0-9._/-]`: se interpola entre comillas dobles para que `$HOME` se expanda.
 */
object HomeFileScripts {
    const val CONFLICT_EXIT_CODE = 75
    const val LOCKED_EXIT_CODE = 76
    const val SYMLINK_EXIT_CODE = 77

    /** Intentos (de 1 s) de tomar el cerrojo; uno de más de un minuto se da por abandonado. */
    const val LOCK_ATTEMPTS = 10

    private val ALLOWED = (('A'..'Z') + ('a'..'z') + ('0'..'9') + listOf('.', '_', '/', '-')).toSet()

    fun isSafe(relativePath: String): Boolean =
        relativePath.isNotEmpty() && !relativePath.startsWith("/") && !relativePath.contains("..") &&
            relativePath.all { it in ALLOWED }

    fun temporarySuffix(token: String): String = ".argos-tmp-$token"

    /** Paso 1: carpeta y temporal vacío propio (600, sin seguir un enlace previo); imprime `$HOME`. */
    fun prepare(relativePath: String, token: String): String {
        val directory = deletingLastPathComponent(relativePath)
        val temporary = "\"\$HOME/$relativePath${temporarySuffix(token)}\""
        return "umask 077 && mkdir -p \"\$HOME/$directory\" && rm -f -- $temporary && " +
            "( set -C; : > $temporary ) && printf '%s' \"\$HOME\""
    }

    /** Paso 3 (sin envolver en `sh -c`): cerrojo, comprobaciones, copia y `mv`. */
    fun commit(relativePath: String, token: String, expectation: HomeFileExpectation, backupSuffix: String?): String {
        val name = relativePath.substringAfterLast('/')
        val lines = buildList {
            add("umask 077")
            add("f=\"\$HOME/$relativePath\"; t=\"\$f${temporarySuffix(token)}\"; l=\"\$f.argos-lock\"")
            add("n=0")
            add("until mkdir \"\$l\" 2>/dev/null; do")
            add("  if [ -n \"\$(find \"\$l\" -maxdepth 0 -mmin +1 2>/dev/null)\" ]; then rmdir \"\$l\" 2>/dev/null; continue; fi")
            add("  n=\$((n + 1)); if [ \"\$n\" -ge $LOCK_ATTEMPTS ]; then rm -f -- \"\$t\"; exit $LOCKED_EXIT_CODE; fi")
            add("  sleep 1")
            add("done")
            add("trap 'rmdir \"\$l\" 2>/dev/null' EXIT")
            add("if [ -L \"\$f\" ]; then rm -f -- \"\$t\"; exit $SYMLINK_EXIT_CODE; fi")
            when (expectation) {
                HomeFileExpectation.Any -> Unit
                HomeFileExpectation.AbsentOrEmpty -> add("[ ! -s \"\$f\" ] || { rm -f -- \"\$t\"; exit $CONFLICT_EXIT_CODE; }")
                is HomeFileExpectation.Fingerprint -> {
                    add("set -- \$(cksum < \"\$f\" 2>/dev/null)")
                    add("[ \"\$1 \$2\" = ${ShellQuoting.singleQuoted(expectation.value)} ] || { rm -f -- \"\$t\"; exit $CONFLICT_EXIT_CODE; }")
                }
            }
            if (backupSuffix != null) {
                add(
                    "if [ -f \"\$f\" ]; then rm -f -- \"\$f$backupSuffix\" && cp -- \"\$f\" \"\$f$backupSuffix\" " +
                        "|| { rm -f -- \"\$t\"; exit 1; }; fi",
                )
            }
            add("mv -f -- \"\$t\" \"\$f\" || { rm -f -- \"\$t\"; exit 1; }")
            // Temporales de escrituras interrumpidas (otro dispositivo, o esta app sin red).
            add(
                "find \"\${f%/*}\" -maxdepth 1 -name ${ShellQuoting.singleQuoted("$name.argos-tmp-*")} " +
                    "-mmin +60 -exec rm -f -- {} + 2>/dev/null",
            )
            add("exit 0")
        }
        return lines.joinToString("\n")
    }

    /** Ruta SFTP absoluta del temporal, o `null` si [home] no es absoluta. */
    fun temporaryPath(home: String, relativePath: String, token: String): String? {
        val trimmed = home.trim()
        return if (trimmed.startsWith("/")) "$trimmed/$relativePath${temporarySuffix(token)}" else null
    }

    /** Borra el temporal si la subida falló. */
    fun removeTemporary(absolutePath: String): String = "rm -f -- ${ShellQuoting.singleQuoted(absolutePath)}"

    /** `sh -c '<script>'`, como `ShellQuoting.posixShell` de Apple. */
    fun posixShell(script: String): String = "sh -c " + ShellQuoting.singleQuoted(script)

    /** `(relativePath as NSString).deletingLastPathComponent`. */
    private fun deletingLastPathComponent(path: String): String {
        val trimmed = path.trimEnd('/')
        val slash = trimmed.lastIndexOf('/')
        return if (slash <= 0) "" else trimmed.substring(0, slash)
    }
}

/**
 * CRC de `cksum` (POSIX.2: CRC-32 0x04C11DB7 sin reflejar, con la longitud añadida y
 * complementado), port de `PosixChecksum.swift`: comprobar EN EL SERVIDOR, sin herramientas
 * extra, que un archivo sigue siendo el que se leyó.
 */
object PosixChecksum {
    private val TABLE = IntArray(256) { index ->
        var crc = index shl 24
        repeat(8) { crc = if (crc and Int.MIN_VALUE != 0) (crc shl 1) xor 0x04C11DB7 else crc shl 1 }
        crc
    }

    /** Lo que imprime `cksum < archivo`: `"<crc> <bytes>"`. */
    fun fingerprint(data: ByteArray): String = "${crc(data)} ${data.size}"

    fun crc(data: ByteArray): Long {
        var crc = 0
        for (byte in data) crc = (crc shl 8) xor TABLE[((crc ushr 24) xor (byte.toInt() and 0xFF)) and 0xFF]
        var length = data.size.toLong()
        while (length > 0) {
            crc = (crc shl 8) xor TABLE[((crc ushr 24) xor (length and 0xFF).toInt()) and 0xFF]
            length = length shr 8
        }
        return crc.inv().toLong() and 0xFFFFFFFFL
    }

    /** Huella esperada de lo leído: `null` = vacío o inexistente (como `ProjectsUpdater`). */
    fun expectedFingerprint(text: String): String? =
        if (text.isEmpty()) null else fingerprint(text.toByteArray(Charsets.UTF_8))
}
