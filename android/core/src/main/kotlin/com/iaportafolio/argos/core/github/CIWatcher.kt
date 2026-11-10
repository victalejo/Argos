package com.iaportafolio.argos.core.github

import java.time.Duration
import java.time.Instant

/** Un commit cuyo CI se está esperando. */
data class CIWatch(
    val root: String,
    /** Nombre para el aviso (el del proyecto). */
    val name: String,
    /** `null` tras un push: se fija en la primera lectura (el HEAD recién subido). */
    val sha: String?,
    val since: Instant,
)

/** CI terminado de un commit vigilado (mismos textos que Mac e iPhone). */
data class CIResult(val watch: CIWatch, val state: GitHubCheckState, val failed: List<String>, val url: String?) {
    val title: String
        get() = "CI de «${watch.name}»: ${if (state == GitHubCheckState.SUCCESS) "pasó" else state.label.lowercase()}"

    val body: String
        get() {
            val sha = watch.sha?.take(7).orEmpty()
            return if (failed.isEmpty()) "Commit $sha · todos los workflows en verde." else "Commit $sha · falló: ${failed.joinToString(", ")}."
        }
}

/**
 * Vigila el CI de commits concretos hasta que termina (port de `CIWatcher.swift`), para avisar
 * «el CI pasó/falló». Solo se vigila lo que el usuario subió o vio en curso. Inmutable: cada
 * operación devuelve el vigilante nuevo.
 */
data class CIWatcher(val watches: Map<String, CIWatch> = emptyMap(), val lastPoll: Instant? = null) {

    val isEmpty: Boolean get() = watches.isEmpty()

    /** Empieza a vigilar [root]; repetir la misma petición no reinicia la espera. */
    fun watch(root: String, name: String, sha: String?, now: Instant): CIWatcher {
        val current = watches[root]
        if (current != null) {
            if (sha == null || current.sha == sha) return this
            if (current.sha == null) return copy(watches = watches + (root to current.copy(sha = sha)))
        }
        return copy(watches = watches + (root to CIWatch(root, name, sha, now)))
    }

    fun isDue(now: Instant): Boolean {
        if (watches.isEmpty()) return false
        val last = lastPoll ?: return true
        return Duration.between(last, now) >= POLL_INTERVAL
    }

    fun polled(now: Instant): CIWatcher = copy(lastPoll = now)

    /** Aplica la lectura de un commit vigilado: el vigilante nuevo y el resultado si terminó. */
    fun apply(result: GitHubStatusResult, root: String, now: Instant): Pair<CIWatcher, CIResult?> {
        val watch = watches[root] ?: return this to null
        val snapshot = when (result) {
            is GitHubStatusResult.Loaded -> result.snapshot
            is GitHubStatusResult.Failed -> return this to null // fallo pasajero: se reintenta
            GitHubStatusResult.GhMissing, GitHubStatusResult.NotAuthenticated, GitHubStatusResult.NotGitHub ->
                return drop(root) to null
        }
        val pinned = if (watch.sha == null) watch.copy(sha = snapshot.headSha) else watch
        // HEAD cambió (otro commit encima): las ejecuciones ya serían de otro commit.
        if (pinned.sha != snapshot.headSha) return drop(root) to null
        val age = Duration.between(pinned.since, now)
        val updated = copy(watches = watches + (root to pinned))
        val state = snapshot.ciState
            ?: return (if (age > NO_RUNS_GIVE_UP) drop(root) else updated) to null
        if (snapshot.isCIRunning) return (if (age > MAX_AGE) drop(root) else updated) to null
        val failed = snapshot.failedRuns
        return drop(root) to CIResult(pinned, state, failed.map { it.workflow }, (failed.firstOrNull() ?: snapshot.runs.firstOrNull())?.url)
    }

    private fun drop(root: String) = copy(watches = watches - root)

    companion object {
        val POLL_INTERVAL: Duration = Duration.ofSeconds(30)
        val NO_RUNS_GIVE_UP: Duration = Duration.ofMinutes(3)
        val MAX_AGE: Duration = Duration.ofHours(2)
    }
}
