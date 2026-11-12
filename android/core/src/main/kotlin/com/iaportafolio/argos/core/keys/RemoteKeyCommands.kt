package com.iaportafolio.argos.core.keys

import com.iaportafolio.argos.core.ShellQuoting

/**
 * Comandos para añadir, retirar y leer claves de `~/.ssh/authorized_keys` del servidor
 * (parte pura de `ArgosCore/SSHKeyAuthorization.swift`).
 */
object AuthorizedKeysCommands {

    /**
     * Añade [line] al final de `authorized_keys` (crea `~/.ssh` con permisos 0700 y el
     * archivo con 0600 si no existen).
     */
    fun authorizeKey(line: String): String =
        "umask 077 && mkdir -p \"\$HOME/.ssh\" && " +
            "printf '%s\\n' ${ShellQuoting.singleQuoted(line)} >> \"\$HOME/.ssh/authorized_keys\""

    /**
     * Reescribe `authorized_keys` sin las líneas que contienen ` <comment>`. Solo
     * sobrescribe si `grep` terminó bien (0 = quedan líneas, 1 = no queda ninguna); con
     * `cat >` el archivo conserva sus permisos y propietario.
     */
    fun revokeKey(comment: String): String =
        "f=\"\$HOME/.ssh/authorized_keys\"; [ -f \"\$f\" ] || exit 0; " +
            "grep -vF -- ${ShellQuoting.singleQuoted(" $comment")} \"\$f\" > \"\$f.argos\"; " +
            "s=\$?; if [ \$s -le 1 ]; then cat \"\$f.argos\" > \"\$f\"; fi; rm -f \"\$f.argos\"; [ \$s -le 1 ]"

    /** Lee `authorized_keys` (vacío si no existe). */
    const val READ_AUTHORIZED_KEYS: String =
        "f=\"\$HOME/.ssh/authorized_keys\"; if [ -f \"\$f\" ]; then cat \"\$f\"; fi"
}

/**
 * Comandos de lectura/escritura privada de ficheros en el `$HOME` del servidor (parte pura
 * de `ArgosCore/RemotePrivateFile.swift`):
 *  - el contenido viaja por SFTP, NUNCA en la línea de comandos (visible en `ps`);
 *  - todo se crea bajo `umask 077` (temporal, copia y fichero final en 600);
 *  - la escritura es atómica: temporal + `mv`.
 *
 * `relativePath` lo fija siempre el código (no el usuario): se interpola entre comillas
 * dobles para que `$HOME` se expanda.
 */
object RemoteHomeFileCommands {

    const val TEMP_SUFFIX = ".argos-tmp"
    const val BACKUP_SUFFIX = ".argos-backup"

    /**
     * Contenido de `~/<relativePath>`. Sale con 0 y sin salida si no existe, y con el código de
     * `cat` si existe y no se puede leer (incluido un enlace simbólico roto): ese fallo NO debe
     * tomarse por «no existe», o quien lee-modifica-escribe guardaría encima solo lo nuevo.
     */
    fun read(relativePath: String): String {
        val path = "\"\$HOME/$relativePath\""
        return "[ -e $path ] || [ -L $path ] || exit 0; cat $path"
    }

    /**
     * Paso 1: prepara el temporal (600), opcionalmente copia de seguridad, y escribe
     * `$HOME` por stdout para construir la ruta SFTP absoluta del temporal.
     */
    fun prepareWrite(relativePath: String, backup: Boolean = false): String {
        val path = "\$HOME/$relativePath"
        val directory = relativePath.substringBeforeLast('/', missingDelimiterValue = "")
        val backupStep = "{ [ ! -f \"$path\" ] || cp \"$path\" \"$path$BACKUP_SUFFIX\"; }"
        return listOfNotNull(
            "umask 077",
            "mkdir -p \"\$HOME/$directory\"",
            backupStep.takeIf { backup },
            ": > \"$path$TEMP_SUFFIX\"",
            "printf '%s' \"\$HOME\"",
        ).joinToString(" && ")
    }

    /** Paso 2: ruta SFTP absoluta del temporal, o `null` si [home] no es una ruta absoluta. */
    fun tempUploadPath(home: String, relativePath: String): String? {
        val trimmed = home.trim()
        return if (trimmed.startsWith("/")) "$trimmed/$relativePath$TEMP_SUFFIX" else null
    }

    /** Paso 3: reemplazo atómico del fichero final. */
    fun commitWrite(relativePath: String): String {
        val path = "\$HOME/$relativePath"
        return "mv \"$path$TEMP_SUFFIX\" \"$path\""
    }
}
