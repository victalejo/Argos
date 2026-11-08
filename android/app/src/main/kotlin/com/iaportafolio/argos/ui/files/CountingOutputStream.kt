package com.iaportafolio.argos.ui.files

import java.io.FilterOutputStream
import java.io.OutputStream

/**
 * Cuenta los bytes escritos en [target] y avisa a [onProgress] cada [reportEveryBytes] (y en
 * [flush]/[close]) para mostrar el progreso de una descarga sin saturar la UI. No es dueño de
 * [target]: [close] solo vacía y avisa; quien lo abrió lo cierra.
 */
class CountingOutputStream(
    private val target: OutputStream,
    private val reportEveryBytes: Long = DEFAULT_REPORT_BYTES,
    private val onProgress: (Long) -> Unit,
) : FilterOutputStream(target) {

    @Volatile
    var count: Long = 0
        private set

    private var lastReported = 0L

    override fun write(b: Int) {
        target.write(b)
        advance(1)
    }

    override fun write(b: ByteArray, off: Int, len: Int) {
        target.write(b, off, len)
        advance(len.toLong())
    }

    override fun flush() {
        target.flush()
        report()
    }

    override fun close() {
        flush()
    }

    private fun advance(bytes: Long) {
        count += bytes
        if (count - lastReported >= reportEveryBytes) report()
    }

    private fun report() {
        if (count == lastReported) return
        lastReported = count
        onProgress(count)
    }

    companion object {
        const val DEFAULT_REPORT_BYTES = 64L * 1024
    }
}
