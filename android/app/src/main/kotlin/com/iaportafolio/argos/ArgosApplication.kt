package com.iaportafolio.argos

import android.app.Application
import com.iaportafolio.argos.core.SSHConnector
import com.iaportafolio.argos.ssh.SshjConnector

/** Punto de arranque del proceso: instala la criptografía y crea el grafo de dependencias. */
class ArgosApplication : Application() {

    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        installSecurityProvider()
        container = AppContainer(this, sshConnector())
    }

    /**
     * Hook de criptografía, ANTES de crear cualquier conexión: sshj necesita el BouncyCastle
     * completo en primera posición (Android trae un "BC" recortado). El Keystore no se ve
     * afectado: `KeystoreSecretCipher` no fija proveedor y JCA elige el del Keystore por la clave.
     */
    private fun installSecurityProvider() {
        SshjConnector.installSecurityProvider()
    }

    /** Conector SSH real (sshj). */
    private fun sshConnector(): SSHConnector = SshjConnector()
}
