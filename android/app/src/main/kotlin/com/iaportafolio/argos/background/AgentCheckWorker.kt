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

/** Comprobación periódica de los agentes. Los fallos ya están aislados por servidor en el notificador. */
class AgentCheckWorker(appContext: Context, params: WorkerParameters) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        (applicationContext as ArgosApplication).container.agentNotifier.check()
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
