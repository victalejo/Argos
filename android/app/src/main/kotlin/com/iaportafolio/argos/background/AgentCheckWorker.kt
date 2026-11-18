package com.iaportafolio.argos.background

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.iaportafolio.argos.ArgosApplication
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Comprobación periódica en segundo plano: avisos de agentes y CI vigilado. Los fallos ya están
 * aislados por servidor; el resultado queda en el diagnóstico de Ajustes.
 */
class AgentCheckWorker(appContext: Context, params: WorkerParameters) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val container = (applicationContext as ArgosApplication).container
        container.agentNotifier.check(CheckTrigger.BACKGROUND)
        val provider = container.backgroundServices()
        try {
            // El vigilante de CI vive en el hilo principal (como en primer plano).
            withContext(Dispatchers.Main) { container.ciWatches.pollWith(provider) }
        } finally {
            provider.closeAll()
        }
        container.backgroundSchedule.sync()
        return Result.success()
    }
}

/** Trabajo único cada 15 min (el mínimo del sistema) con red. WorkManager lo conserva al reiniciar. */
class WorkManagerAgentCheckScheduler(context: Context) : AgentCheckScheduler {
    private val appContext = context.applicationContext

    override fun schedule() {
        val request = PeriodicWorkRequestBuilder<AgentCheckWorker>(INTERVAL_MINUTES, TimeUnit.MINUTES)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        WorkManager.getInstance(appContext).enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    override fun cancel() {
        WorkManager.getInstance(appContext).cancelUniqueWork(WORK_NAME)
    }

    private companion object {
        const val WORK_NAME = "agents-check"
        const val INTERVAL_MINUTES = 15L
    }
}
