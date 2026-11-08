package com.iaportafolio.argos.data

import java.io.File
import java.io.FileOutputStream
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * Escritura atómica: se escribe un temporal en el MISMO directorio, se fuerza a disco y se
 * renombra encima del destino. Un corte a mitad deja el archivo anterior intacto (nunca un
 * JSON a medias). Equivale a `Data.write(options: .atomic)` de Apple.
 */
internal object AtomicFiles {

    fun write(target: File, bytes: ByteArray) {
        val directory = target.absoluteFile.parentFile
            ?: throw IllegalArgumentException("El archivo ${target.name} no tiene directorio padre.")
        if (!directory.exists() && !directory.mkdirs()) {
            throw java.io.IOException("No se pudo crear el directorio ${directory.name}.")
        }
        val temp = File.createTempFile(".${target.name}.", ".tmp", directory)
        try {
            FileOutputStream(temp).use { out ->
                out.write(bytes)
                out.flush()
                out.fd.sync()
            }
            move(temp, target)
        } finally {
            if (temp.exists()) temp.delete()
        }
    }

    private fun move(source: File, target: File) {
        try {
            Files.move(
                source.toPath(),
                target.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } catch (_: AtomicMoveNotSupportedException) {
            // Mismo directorio: en ext4/f2fs siempre se admite; respaldo por si acaso.
            Files.move(source.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }
}
