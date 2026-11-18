package com.iaportafolio.argos.core.doctor

import java.time.Instant

/**
 * Reglas (lógica pura) del Doctor (port de `ArgosCore/Doctor/DoctorEvaluator.swift`): convierte
 * los datos del servidor ([DoctorFacts]) en comprobaciones con su severidad, su explicación y su
 * arreglo. TODA la decisión de qué es un aviso y qué un problema vive aquí. Este archivo cubre el
 * software; los recursos y el sistema están en `DoctorSystemRules.kt`. Los textos son los de Swift.
 */
object DoctorEvaluator {

    /** Datos del dispositivo y de Argos que no salen del script remoto. */
    data class Context(
        /** Hora del dispositivo en mitad de la consulta (para el desfase de reloj). */
        val deviceNow: Instant = Instant.now(),
        /** ¿Los hooks de Claude de Argos están en su versión actual? `null` = no se verificó. */
        val hooksUpToDate: Boolean? = null,
    )

    /** Versión mínima de git para commits de muchos archivos (`--pathspec-from-file`). */
    val MINIMUM_GIT = DoctorVersion(2, 26)

    /** tmux 3.0 introdujo las opciones de panel (`set-option -p`) que usan los hooks de Claude. */
    val MINIMUM_TMUX_FOR_HOOKS = DoctorVersion(3, 0)

    /** Canales SSH simultáneos que Argos usa por conexión (`ChannelGate.sharedConnectionLimit`). */
    const val DESIRED_SESSIONS = 6

    fun evaluate(facts: DoctorFacts, context: Context = Context()): List<DoctorCheck> = listOf(
        tmux(facts), git(facts), claude(facts), gh(facts),
        tools(facts), python(facts),
        DoctorSystemRules.diskHome(facts), DoctorSystemRules.diskTmp(facts), DoctorSystemRules.memory(facts),
        DoctorSystemRules.swap(facts), DoctorSystemRules.claudeProcesses(facts),
        DoctorSystemRules.maxSessions(facts), DoctorSystemRules.fail2ban(facts),
        claudeHooks(facts, context), portsSkill(facts), projectsFile(facts),
        DoctorSystemRules.locale(facts), DoctorSystemRules.clock(facts, context),
    )

    private fun installFix(packageName: String, facts: DoctorFacts): DoctorFix? =
        DoctorInstallHints.install(packageName, facts["pm"])?.let(DoctorFix::CopyCommand)

    // MARK: Software

    private fun tmux(facts: DoctorFacts): DoctorCheck {
        val id = DoctorCheckID.TMUX
        val title = "tmux"
        val present = facts.flag("tmux.present")
            ?: return DoctorCheck(id, title, DoctorStatus.UNKNOWN, "No se pudo comprobar si tmux está instalado.")
        if (!present) {
            return DoctorCheck(
                id, title, DoctorStatus.PROBLEM,
                "tmux no está instalado: Argos lo necesita para listar, crear y abrir sesiones.",
                installFix("tmux", facts),
            )
        }
        val raw = facts["tmux.version"].orEmpty()
        val version = DoctorVersion.parse(raw)
            ?: return DoctorCheck(id, title, DoctorStatus.OK, if (raw.isEmpty()) "Instalado." else "Instalado ($raw).")
        if (version < MINIMUM_TMUX_FOR_HOOKS) {
            return DoctorCheck(
                id, title, DoctorStatus.WARNING,
                "tmux ${version.text}: funciona, pero el indicador de estado de Claude necesita tmux 3.0 o posterior.",
                installFix("tmux", facts),
            )
        }
        return DoctorCheck(id, title, DoctorStatus.OK, "tmux ${version.text} instalado.")
    }

    private fun git(facts: DoctorFacts): DoctorCheck {
        val id = DoctorCheckID.GIT
        val title = "git"
        val present = facts.flag("git.present")
            ?: return DoctorCheck(id, title, DoctorStatus.UNKNOWN, "No se pudo comprobar si git está instalado.")
        val install = installFix("git", facts)
        if (!present) {
            return DoctorCheck(
                id, title, DoctorStatus.WARNING,
                "git no está instalado: no funcionarán los cambios, commits, ramas ni clonar.", install,
            )
        }
        val version = DoctorVersion.parse(facts["git.version"].orEmpty())
            ?: return DoctorCheck(id, title, DoctorStatus.OK, "Instalado (no se pudo leer la versión).")
        if (version < MINIMUM_GIT) {
            return DoctorCheck(
                id, title, DoctorStatus.WARNING,
                "git ${version.text} es anterior a 2.26: los commits de muchísimos archivos pueden fallar. Actualízalo.",
                install,
            )
        }
        return DoctorCheck(id, title, DoctorStatus.OK, "git ${version.text} instalado.")
    }

    private fun claude(facts: DoctorFacts): DoctorCheck {
        val id = DoctorCheckID.CLAUDE
        val title = "Claude Code"
        val present = facts.flag("claude.present")
            ?: return DoctorCheck(id, title, DoctorStatus.UNKNOWN, "No se pudo comprobar si Claude Code está instalado.")
        if (!present) {
            return DoctorCheck(
                id, title, DoctorStatus.WARNING,
                "claude no está instalado: el panel de agente y las ventanas de Claude no estarán disponibles.",
                DoctorFix.CopyCommand(DoctorInstallHints.CLAUDE_INSTALL),
            )
        }
        val version = DoctorVersion.parse(facts["claude.version"].orEmpty())?.let { " ${it.text}" }.orEmpty()
        return when (facts["claude.auth"]) {
            "in" -> DoctorCheck(id, title, DoctorStatus.OK, "Instalado$version y con sesión iniciada.")
            "out" -> DoctorCheck(
                id, title, DoctorStatus.WARNING,
                "Instalado$version, pero sin sesión iniciada. Inicia sesión desde el panel de agente de Argos o en el servidor.",
                DoctorFix.CopyCommand("claude auth login"),
            )
            else -> DoctorCheck(
                id, title, DoctorStatus.UNKNOWN,
                "Instalado$version, pero no se pudo comprobar si tiene sesión iniciada.",
            )
        }
    }

    private fun gh(facts: DoctorFacts): DoctorCheck {
        val id = DoctorCheckID.GH
        val title = "GitHub CLI (gh)"
        val present = facts.flag("gh.present")
            ?: return DoctorCheck(id, title, DoctorStatus.UNKNOWN, "No se pudo comprobar si gh está instalado.")
        if (!present) {
            return DoctorCheck(
                id, title, DoctorStatus.WARNING,
                "gh no está instalado: no se podrán ver PR ni CI, abrir PR ni clonar repositorios de GitHub.",
                installFix("gh", facts),
            )
        }
        val version = DoctorVersion.parse(facts["gh.version"].orEmpty())?.let { " ${it.text}" }.orEmpty()
        return when (facts["gh.auth"]) {
            "in" -> DoctorCheck(id, title, DoctorStatus.OK, "Instalado$version y con sesión iniciada.")
            "out" -> DoctorCheck(
                id, title, DoctorStatus.WARNING,
                "Instalado$version, pero sin sesión: inicia sesión para usar PR, CI y clonar.",
                DoctorFix.CopyCommand("gh auth login"),
            )
            else -> DoctorCheck(
                id, title, DoctorStatus.UNKNOWN,
                "Instalado$version, pero no se pudo comprobar la sesión (¿sin conexión a GitHub?).",
            )
        }
    }

    // MARK: Utilidades

    private data class RequiredTool(val key: String, val name: String, val impact: String)

    /** Utilidades que usan los scripts de Argos. */
    private val REQUIRED_TOOLS = listOf(
        RequiredTool("tool.base64d", "base64 -d", "los agentes persistentes (iPhone/iPad) no podrán arrancar"),
        RequiredTool("tool.mkfifo", "mkfifo", "los agentes persistentes (iPhone/iPad) no podrán arrancar"),
        RequiredTool("tool.nohup", "nohup", "los agentes persistentes (iPhone/iPad) no podrán arrancar"),
        RequiredTool("tool.findprintf", "find con -printf (GNU)", "«Enviar al Mac» no podrá listar los archivos del proyecto"),
        RequiredTool("tool.timeout", "timeout", "las comprobaciones lentas no tienen límite de tiempo"),
        RequiredTool("tool.cksum", "cksum", "se omiten las comprobaciones de integridad opcionales"),
        RequiredTool("tool.awk", "awk", "algunas lecturas del servidor no se podrán interpretar"),
    )

    private fun tools(facts: DoctorFacts): DoctorCheck {
        val id = DoctorCheckID.TOOLS
        val title = "Utilidades del sistema"
        val missing = REQUIRED_TOOLS.filter { facts.flag(it.key) == false }
        val unknown = REQUIRED_TOOLS.filter { facts.flag(it.key) == null }
        if (unknown.size == REQUIRED_TOOLS.size) {
            return DoctorCheck(id, title, DoctorStatus.UNKNOWN, "No se pudieron comprobar las utilidades.")
        }
        if (missing.isEmpty()) {
            return DoctorCheck(id, title, DoctorStatus.OK, "timeout, cksum, base64, find -printf, mkfifo, nohup y awk disponibles.")
        }
        val text = missing.joinToString("; ") { "${it.name}: ${it.impact}" }
        val isMac = facts["os"] == "Darwin"
        val hint = if (isMac) " (macOS trae las versiones de BSD; en Linux vienen con coreutils y findutils)." else "."
        return DoctorCheck(
            id, title, DoctorStatus.WARNING, "Faltan utilidades. Sin $text$hint",
            if (isMac) null else installFix("coreutils findutils", facts),
        )
    }

    private fun python(facts: DoctorFacts): DoctorCheck {
        val id = DoctorCheckID.PYTHON
        val title = "python3 (opcional)"
        return when (facts.flag("tool.python3")) {
            true -> DoctorCheck(id, title, DoctorStatus.OK, "Instalado: permite validar projects.json a fondo.")
            false -> DoctorCheck(id, title, DoctorStatus.OK, "No instalado. Es opcional: Argos no lo necesita.")
            null -> DoctorCheck(id, title, DoctorStatus.UNKNOWN, "No se pudo comprobar.")
        }
    }

    // MARK: Integraciones de Argos en el servidor

    private fun claudeHooks(facts: DoctorFacts, context: Context): DoctorCheck {
        val id = DoctorCheckID.CLAUDE_HOOKS
        val title = "Hooks de Claude de Argos"
        val missing = DoctorCheck(
            id, title, DoctorStatus.WARNING,
            "No instalados: sin ellos Argos no muestra si Claude trabaja o espera tu permiso.",
            DoctorFix.InstallClaudeHooks(isUpdate = false),
        )
        when (facts["hooks.settings"]) {
            "unreadable" -> return DoctorCheck(id, title, DoctorStatus.UNKNOWN, "~/.claude/settings.json no se puede leer (permisos).")
            "missing" -> return missing
            "ok" -> Unit
            else -> return DoctorCheck(id, title, DoctorStatus.UNKNOWN, "No se pudo comprobar.")
        }
        val count = facts["hooks.marker"]?.toIntOrNull()
        if (count == null || count <= 0) return missing
        return when (context.hooksUpToDate) {
            true -> DoctorCheck(id, title, DoctorStatus.OK, "Instalados y al día.")
            false -> DoctorCheck(
                id, title, DoctorStatus.WARNING,
                "Instalados, pero de una versión anterior: actualízalos para que el indicador sea fiable.",
                DoctorFix.InstallClaudeHooks(isUpdate = true),
            )
            null -> DoctorCheck(id, title, DoctorStatus.OK, "Instalados (no se pudo verificar que estén al día).")
        }
    }

    private fun portsSkill(facts: DoctorFacts): DoctorCheck {
        val id = DoctorCheckID.PORTS_SKILL
        val title = "Skill «argos-puertos»"
        return when (facts["skill.ports"]) {
            "current" -> DoctorCheck(
                id, title, DoctorStatus.OK,
                "Instalada y al día: Claude sabe qué puertos hay y puede pedirte abrir uno.",
            )
            "outdated" -> DoctorCheck(
                id, title, DoctorStatus.WARNING, "Instalada, pero de una versión anterior.",
                DoctorFix.InstallPortsSkill(isUpdate = true),
            )
            "missing" -> DoctorCheck(
                id, title, DoctorStatus.WARNING,
                "No instalada: Claude no podrá consultar los puertos ni pedirte que abras uno.",
                DoctorFix.InstallPortsSkill(isUpdate = false),
            )
            else -> DoctorCheck(id, title, DoctorStatus.UNKNOWN, "No se pudo comprobar.")
        }
    }

    private fun projectsFile(facts: DoctorFacts): DoctorCheck {
        val id = DoctorCheckID.PROJECTS_FILE
        val title = "Proyectos (projects.json)"
        return when (facts["projects.file"]) {
            "missing" -> DoctorCheck(id, title, DoctorStatus.OK, "Aún no existe: se crea al añadir el primer proyecto.")
            "unreadable" -> DoctorCheck(
                id, title, DoctorStatus.PROBLEM,
                "~/.config/argos/projects.json existe pero no se puede leer: revisa sus permisos.",
            )
            "ok" -> if (facts["projects.json"] == "invalid") {
                DoctorCheck(
                    id, title, DoctorStatus.PROBLEM,
                    "~/.config/argos/projects.json no es un JSON válido: Argos no lo modificará hasta que lo corrijas.",
                )
            } else {
                val version = facts["projects.version"]?.let { "versión $it" } ?: "sin número de versión"
                DoctorCheck(id, title, DoctorStatus.OK, "Legible ($version).")
            }
            else -> DoctorCheck(id, title, DoctorStatus.UNKNOWN, "No se pudo comprobar.")
        }
    }
}
