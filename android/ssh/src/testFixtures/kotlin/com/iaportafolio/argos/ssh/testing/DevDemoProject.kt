package com.iaportafolio.argos.ssh.testing

import java.awt.Color
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.nio.file.Files
import java.nio.file.Path
import javax.imageio.ImageIO
import kotlin.io.path.createDirectories
import kotlin.io.path.exists
import kotlin.io.path.writeBytes

/** Lado de la imagen PNG de demo (píxeles). */
private const val LOGO_SIZE = 64

/** Líneas del log grande: supera `FilePreview.MAX_TEXT_BYTES` (2 MiB) para ver el modo truncado. */
private const val BIG_LOG_LINES = 60_000

/**
 * Proyecto de demo en `~/proyectos/demo` del `devServer`, para probar el explorador de archivos
 * en el teléfono: código, README, una imagen PNG, un log grande (visor truncado y descarga),
 * carpetas ruidosas (`node_modules`, `.git`) y un archivo oculto.
 *
 * Idempotente: solo crea lo que falte, nunca pisa cambios hechos a mano.
 */
internal fun ensureDemoProject(home: Path): Path {
    val root = home.resolve("proyectos/demo")
    demoTextFiles().forEach { (relative, content) -> writeIfMissing(root.resolve(relative), content.toByteArray()) }
    writeIfMissing(root.resolve("assets/logo.png"), logoPng())
    val bigLog = root.resolve("logs/servidor.log")
    if (!bigLog.exists()) {
        val lines = (1..BIG_LOG_LINES).joinToString("\n", postfix = "\n") { "2026-11-07T12:00:00Z INFO petición $it atendida" }
        writeIfMissing(bigLog, lines.toByteArray())
    }
    home.resolve("proyectos/otro-proyecto").createDirectories()
    return root
}

private fun demoTextFiles(): Map<String, String> = mapOf(
    "README.md" to """
        |# Demo de Argos
        |
        |Proyecto de prueba servido por `./gradlew :ssh:devServer`.
        |
        |- `src/` código de ejemplo (Kotlin, TypeScript, Python)
        |- `assets/logo.png` imagen para el visor
        |- `logs/servidor.log` archivo grande (> 2 MiB): visor truncado y descarga
        |- `node_modules/` y `.git/` se ocultan por defecto
        |
        |```kotlin
        |fun main() = println("¡Hola desde Argos!")
        |```
        |""".trimMargin(),
    "src/Main.kt" to "fun main() {\n    val saludo = \"¡Hola desde Argos!\"\n    println(saludo)\n}\n",
    "src/app.ts" to "export function suma(a: number, b: number): number {\n  return a + b;\n}\n",
    "src/utils/texto.py" to "def capitalizar(texto: str) -> str:\n    return texto[:1].upper() + texto[1:]\n",
    "package.json" to "{\n  \"name\": \"demo\",\n  \"version\": \"1.0.0\",\n  \"private\": true\n}\n",
    ".gitignore" to "node_modules/\ndist/\n",
    ".env" to "API_URL=http://localhost:3000\n",
    "node_modules/left-pad/index.js" to "module.exports = (s, n) => String(s).padStart(n);\n",
    "node_modules/left-pad/package.json" to "{ \"name\": \"left-pad\", \"version\": \"1.3.0\" }\n",
    ".git/HEAD" to "ref: refs/heads/main\n",
)

private fun writeIfMissing(file: Path, content: ByteArray) {
    if (file.exists()) return
    file.parent?.createDirectories()
    file.writeBytes(content)
}

/** PNG pequeño con un degradado (generado, sin binarios en el repositorio). */
private fun logoPng(): ByteArray {
    System.setProperty("java.awt.headless", "true")
    val image = BufferedImage(LOGO_SIZE, LOGO_SIZE, BufferedImage.TYPE_INT_RGB)
    for (x in 0 until LOGO_SIZE) {
        for (y in 0 until LOGO_SIZE) {
            image.setRGB(x, y, Color(x * 4, y * 4, 200).rgb)
        }
    }
    return ByteArrayOutputStream().use { out ->
        check(ImageIO.write(image, "png", out)) { "No hay escritor PNG en esta JVM." }
        out.toByteArray()
    }
}

/** Ruta del proyecto de demo, para el mensaje de arranque. */
internal fun demoProjectSummary(root: Path): String =
    "$root (${Files.list(root).use { it.count() }} entradas)"
