package com.iaportafolio.argos.core.projects

import com.iaportafolio.argos.core.ShellQuoting
import com.iaportafolio.argos.core.keys.RemoteHomeFileCommands

/**
 * Lectura con huella y reemplazo condicionado de `projects.json` (lo reescriben a la vez el Mac,
 * el iPhone/iPad y Android): antes de sustituir el archivo se comprueba en el servidor que sigue
 * siendo el que se leyó. La huella es la salida de `cksum` (POSIX: CRC y tamaño), o `absent` si
 * no existía. El formato en disco NO cambia.
 *
 * La comprobación y el `mv` van en el mismo comando, así que la ventana en la que otro
 * dispositivo podría colarse es de milisegundos (sh no tiene un «compara y cambia» atómico).
 */
object ProjectsFileCommands {

    /** Huella de un archivo que no existe. */
    const val ABSENT = "absent"

    /** Código de salida de [commitIfUnchanged] cuando el archivo cambió desde que se leyó. */
    const val CHANGED_EXIT_CODE = 75

    private const val FILE = "f=\"\$HOME/${ProjectCommands.PROJECTS_RELATIVE_PATH}\""

    /** Huella actual en el servidor (`cksum` o [ABSENT]). */
    private const val FINGERPRINT = "if [ -e \"\$f\" ] || [ -L \"\$f\" ]; then cksum < \"\$f\"; else echo $ABSENT; fi"

    /**
     * Primera línea: la huella; el resto, el contenido. Falla (código de `cksum`/`cat`) si existe
     * y no se puede leer: eso NO es «no existe», o se guardaría encima solo lo nuevo.
     */
    const val READ_WITH_FINGERPRINT: String =
        "$FILE; if [ -e \"\$f\" ] || [ -L \"\$f\" ]; then cksum < \"\$f\" && cat \"\$f\"; else echo $ABSENT; fi"

    /**
     * Sustituye el archivo por el temporal ya subido SOLO si su huella sigue siendo
     * [fingerprint]; si no, borra el temporal y sale con [CHANGED_EXIT_CODE].
     */
    fun commitIfUnchanged(fingerprint: String): String {
        val temp = "\"\$f${RemoteHomeFileCommands.TEMP_SUFFIX}\""
        return "$FILE; c=\$($FINGERPRINT); " +
            "if [ \"\$c\" = ${ShellQuoting.singleQuoted(fingerprint)} ]; then mv $temp \"\$f\"; " +
            "else rm -f $temp; exit $CHANGED_EXIT_CODE; fi"
    }

    /** Lo leído por [READ_WITH_FINGERPRINT]. */
    data class Snapshot(val fingerprint: String, val text: String)

    /** Separa la huella del contenido; `null` si la salida no tiene la forma esperada. */
    fun parseSnapshot(stdout: String): Snapshot? {
        val newline = stdout.indexOf('\n')
        if (newline < 0) return null
        val fingerprint = stdout.substring(0, newline).trim()
        if (fingerprint.isEmpty()) return null
        return Snapshot(fingerprint, stdout.substring(newline + 1))
    }
}
