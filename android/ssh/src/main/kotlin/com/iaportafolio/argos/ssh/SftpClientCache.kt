package com.iaportafolio.argos.ssh

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.sftp.SFTPClient
import java.io.IOException

/**
 * Cliente SFTP del explorador, reutilizado mientras la conexión SSH sea la misma (port de
 * `browserSFTPClient()` de `SSHFileBrowser.swift`).
 *
 * - Un único subsistema SFTP por conexión: abrir uno por llamada cuesta un canal y un
 *   handshake SFTP, y agota antes el `MaxSessions` del servidor.
 * - El `SFTPEngine` de sshj admite peticiones concurrentes (cada una con su id y su promesa),
 *   así que varias operaciones lo comparten a la vez; [mutex] solo serializa abrir/cerrar.
 * - Si [SshjConnection] reconectó (otro `SSHClient`) o el canal SFTP se cerró, se cierra el
 *   viejo y se abre uno nuevo en la siguiente llamada.
 */
internal class SftpClientCache(private val connection: SshjConnection) {

    private class Entry(val owner: SSHClient, val sftp: SFTPClient) {
        val isAlive: Boolean get() = owner.isConnected && sftp.sftpEngine.subsystem.isOpen
    }

    private val mutex = Mutex()
    private var current: Entry? = null

    /** Cliente SFTP vivo de la conexión actual (lo abre si hace falta). Lanza `IOException` de sshj. */
    suspend fun client(): SFTPClient {
        val ssh = connection.connectedClient()
        return mutex.withLock {
            current?.takeIf { it.owner === ssh && it.isAlive }?.sftp ?: reopen(ssh)
        }
    }

    /** Cierra el cliente cacheado (al desconectar). Idempotente y no cancelable a medias. */
    suspend fun close() {
        withContext(NonCancellable) {
            mutex.withLock {
                val stale = current
                current = null
                stale?.let { withContext(Dispatchers.IO) { closeQuietly(it.sftp) } }
            }
        }
    }

    /** Requiere [mutex]. */
    private suspend fun reopen(ssh: SSHClient): SFTPClient {
        val stale = current
        current = null
        stale?.let { withContext(NonCancellable + Dispatchers.IO) { closeQuietly(it.sftp) } }
        val sftp = runInterruptible(Dispatchers.IO) { ssh.newSFTPClient() }
        current = Entry(ssh, sftp)
        return sftp
    }

    private fun closeQuietly(sftp: SFTPClient) {
        try {
            sftp.close()
        } catch (_: IOException) {
            // El canal ya estaba cerrado (o la conexión caída): no hay nada más que hacer.
        }
    }
}
