package com.iaportafolio.argos.core.doctor

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Paridad con `ArgosTests/DiagnosticReportTests.swift`: redacción, formato del registro e informe. */
class DiagnosticReportTest {

    private val servers = listOf(
        DiagnosticRedactor.KnownServer("Producción", "prod.miempresa.com", "victor"),
        DiagnosticRedactor.KnownServer("dev", "203.0.113.7", "root"),
    )

    private fun redact(text: String, known: Boolean = true, personal: Boolean = false): String =
        DiagnosticRedactor(if (known) servers else emptyList(), personal).redact(text)

    private val app = DiagnosticAppInfo("1.9.0", "64", "GitHub (Sparkle)", "macOS 15.4", "Mac14,2")

    private fun entry(message: String, level: String = "error", category: String = "ssh", at: Long = 0) =
        DiagnosticLogLine(Instant.ofEpochSecond(1_800_000_000 + at), level, category, message)

    private fun input(log: DiagnosticLogExcerpt, doctor: DoctorResult? = null) =
        DiagnosticInput(app, Instant.ofEpochSecond(1_800_000_000), "Producción", doctor, log)

    // MARK: DiagnosticRedactor

    @Test
    fun `servidores conocidos comparten marcador estable`() {
        assertEquals(
            "Conectado a servidor-1 (servidor-1); luego servidor-2 y servidor-2",
            redact("Conectado a prod.miempresa.com (Producción); luego 203.0.113.7 y dev"),
        )
    }

    @Test
    fun `un host mas largo no queda a medias por otro mas corto`() {
        val redactor = DiagnosticRedactor(
            listOf(
                DiagnosticRedactor.KnownServer("a", "miempresa.com", "u"),
                DiagnosticRedactor.KnownServer("b", "prod.miempresa.com", "u"),
            ),
        )
        assertEquals("servidor-2 y servidor-1", redactor.redact("prod.miempresa.com y miempresa.com"))
    }

    @Test
    fun `IPv4 se sustituyen y se conserva lo que no es una IP`() {
        assertEquals(
            "ip servidor-1 y servidor-2, otra vez servidor-1; versión 15.4.1; 999.1.1.1; 1.2.3.4.5",
            redact("ip 192.168.1.20 y 10.0.0.5, otra vez 192.168.1.20; versión 15.4.1; 999.1.1.1; 1.2.3.4.5", known = false),
        )
    }

    @Test
    fun `IPv6 validas si, horas y MAC no`() {
        val text = redact("v6 2001:db8::1 y fe80::1ff:fe23:4567:890a, hora 12:30:45, mac aa:bb:cc:dd:ee:ff, [::1]:22", known = false)
        assertTrue(text.contains("v6 servidor-1 y servidor-2"), text)
        assertTrue(text.contains("hora 12:30:45"))
        assertTrue(text.contains("mac aa:bb:cc:dd:ee:ff"))
        assertFalse(text.contains("2001:db8"))
        assertFalse(text.contains("fe80"))
        assertTrue(DiagnosticRedactor.isIPv6("::1"))
        assertTrue(DiagnosticRedactor.isIPv6("::ffff:192.0.2.1"))
        assertFalse(DiagnosticRedactor.isIPv6("12:30:45"))
        assertFalse(DiagnosticRedactor.isIPv6("1::2::3"))
    }

    @Test
    fun `usuario arroba host con marcadores consistentes`() {
        assertEquals(
            "ssh usuario-1@servidor-1 y usuario-1@servidor-2; usuario-2@servidor-1",
            redact("ssh alice@build.example.org y alice@10.1.2.3; bob@build.example.org", known = false),
        )
        assertEquals("usuario-1@servidor-1", redact("victor@prod.miempresa.com"))
    }

    @Test
    fun `rutas home y Users`() {
        assertEquals(
            "abre /home/usuario-1/proyecto y /Users/usuario-1/Library, /home/usuario-2/x",
            redact("abre /home/alice/proyecto y /Users/alice/Library, /home/bob/x", known = false),
        )
        assertEquals("/Users/usuario-1/Desktop", redact("/Users/victor/Desktop"))
    }

    @Test
    fun `los secretos se quitan siempre, incluso con datos personales`() {
        val input = listOf(
            "key /Users/alice/.ssh/id_ed25519 y ~/.ssh/config y /srv/keys/deploy.pem y /home/bob/id_rsa.pub",
            "token sk-ant-api03-AbCdEfGhIjKlMnOp y ghp_abcdefghijklmnop1234 y github_pat_11ABCDEFGHIJKLMNOP",
            "CLAUDE_CODE_OAUTH_TOKEN=abc123 password: \"hunter 2\" passphrase=secreta",
            "Authorization: Bearer eyJhbGciOi.payload.firma",
        ).joinToString("\n")
        val leaks = listOf(
            "id_ed25519", ".ssh/config", "deploy.pem", "id_rsa", "AbCdEfGh", "ghp_abc", "github_pat_11",
            "abc123", "hunter", "secreta", "eyJhbGciOi",
        )
        for (personal in listOf(false, true)) {
            val text = redact(input, known = false, personal = personal)
            for (leaked in leaks) assertFalse(text.contains(leaked), "filtró $leaked (personal=$personal)")
            assertTrue(text.contains(DiagnosticRedactor.KEY_PATH_MARKER))
        }
    }

    @Test
    fun `con datos personales incluidos se respetan hosts, IPs y usuarios`() {
        assertEquals("alice@203.0.113.7 /home/alice", redact("alice@203.0.113.7 /home/alice", personal = true))
    }

    @Test
    fun `texto normal no se toca`() {
        val line = "10:42:11.123 [notice] ssh: Canal rechazado (intento 2); versión 1.8.10 build 63"
        assertEquals(line, redact(line, known = false))
    }

    @Test
    fun `la etiqueta del servidor se redacta igual que el resto`() {
        assertEquals("servidor-1", DiagnosticRedactor(servers).serverLabel("Producción"))
        assertEquals("Producción", DiagnosticRedactor(servers, includesPersonalData = true).serverLabel("Producción"))
    }

    // MARK: DiagnosticReport

    @Test
    fun `cabecera con version, variante, sistema y modelo`() {
        val text = DiagnosticReport.compose(input(DiagnosticLogExcerpt.Entries(emptyList())), DiagnosticRedactor())
        assertTrue(text.contains("Versión: 1.9.0 (build 64)"))
        assertTrue(text.contains("Variante: GitHub (Sparkle)"))
        assertTrue(text.contains("Sistema: macOS 15.4"))
        assertTrue(text.contains("Dispositivo: Mac14,2"))
        assertTrue(text.contains("Generado: 2027-01-15T08:00:00Z"))
        assertTrue(text.contains("Datos personales: ocultos"))
        assertTrue(text.contains("Sin servidor conectado"))
        assertTrue(text.contains("Revisa este texto antes de publicarlo"))
    }

    @Test
    fun `el Doctor y el registro salen redactados con los mismos marcadores`() {
        val doctor = DoctorResult(
            listOf(
                DoctorCheck(
                    DoctorCheckID.CLOCK, "Reloj del servidor", DoctorStatus.WARNING, "Desfase en 203.0.113.7",
                    DoctorFix.CopyCommand("ssh root@203.0.113.7"),
                ),
            ),
            Instant.EPOCH,
        )
        val log = DiagnosticLogExcerpt.Entries(listOf(entry("fallo con victor@prod.miempresa.com")))
        val redactor = DiagnosticRedactor(listOf(DiagnosticRedactor.KnownServer("Producción", "prod.miempresa.com", "victor")))
        val text = DiagnosticReport.compose(input(log, doctor), redactor)
        assertTrue(text.contains("Doctor del servidor: servidor-1"))
        assertTrue(text.contains("Desfase en servidor-2"))
        assertTrue(text.contains("usuario-2@servidor-2") || text.contains("usuario-1@servidor-2"))
        assertTrue(text.contains("fallo con usuario-1@servidor-1"))
        assertFalse(text.contains("203.0.113.7"))
        assertFalse(text.contains("prod.miempresa.com"))
    }

    @Test
    fun `sin registro disponible el informe se genera y lo dice`() {
        val text = DiagnosticReport.compose(input(DiagnosticLogExcerpt.Unavailable("sin permisos")), DiagnosticRedactor())
        assertTrue(text.contains("## Registro de la app"))
        assertTrue(text.contains("No disponible"))
        assertTrue(text.contains("sin permisos"))
        assertTrue(text.contains("Versión: 1.9.0"))
    }

    @Test
    fun `un secreto en el registro no sale ni con datos personales incluidos`() {
        val log = DiagnosticLogExcerpt.Entries(listOf(entry("token=sk-ant-oat01-ZZZZZZZZZZZZ en /Users/a/.ssh/id_rsa")))
        val text = DiagnosticReport.compose(input(log), DiagnosticRedactor(includesPersonalData = true))
        assertFalse(text.contains("ZZZZ"))
        assertFalse(text.contains("id_rsa"))
        assertTrue(text.contains("incluidos a petición"))
    }

    // MARK: DiagnosticLogFormatter

    @Test
    fun `formato de una linea y saltos de linea aplanados`() {
        val text = DiagnosticLogFormatter.format(entry("a\nb"))
        assertTrue(text.endsWith("[error] ssh: a ⏎ b"))
        assertTrue(text.startsWith("08:00:00.000"))
    }

    @Test
    fun `el tope de tamano conserva las lineas mas recientes en orden`() {
        val lines = (0 until 10).map { "línea $it con relleno" }
        val (kept, truncated) = DiagnosticLogFormatter.newest(lines, 100)
        assertTrue(truncated)
        assertTrue(kept.isNotEmpty() && kept.size < 10)
        assertEquals("línea 9 con relleno", kept.last())
        assertTrue(kept.sumOf { it.toByteArray(Charsets.UTF_8).size + 1 } <= 100)
        val (all, allTruncated) = DiagnosticLogFormatter.newest(lines, 10_000)
        assertFalse(allTruncated)
        assertEquals(lines, all)
    }

    @Test
    fun `una linea enorme se recorta con aviso`() {
        val clipped = DiagnosticLogFormatter.clip("x".repeat(5_000), 600)
        assertTrue(clipped.length < 700 && clipped.endsWith("[recortado]"))
        assertEquals("corta", DiagnosticLogFormatter.clip("corta", 600))
    }

    @Test
    fun `por defecto no entran las entradas debug ni la categoria del agente`() {
        val policy = DiagnosticLogPolicy()
        assertTrue(policy.admits(entry("x", level = "error", category = "ssh")))
        assertFalse(policy.admits(entry("x", level = "debug", category = "ssh")))
        assertFalse(policy.admits(entry("x", level = "error", category = "agent")))
        assertTrue(DiagnosticLogPolicy(includesTechnicalDetail = true).admits(entry("x", level = "debug", category = "agent")))
    }

    // MARK: Filtrado y recorte del registro

    private fun compose(lines: List<DiagnosticLogLine>, policy: DiagnosticLogPolicy = DiagnosticLogPolicy()): String {
        val input = DiagnosticInput(DiagnosticAppInfo("1", "1", "v", "s", "m"), Instant.EPOCH, null, null, DiagnosticLogExcerpt.Entries(lines))
        return DiagnosticReport.compose(input, DiagnosticRedactor(), policy)
    }

    @Test
    fun `el detalle tecnico queda fuera salvo opcion explicita`() {
        val lines = listOf(
            entry("claude stderr: volcado remoto", level = "debug", category = "agent"),
            entry("detalle interno", level = "debug"),
            entry("fallo normal"),
        )
        val text = compose(lines)
        assertTrue(text.contains("fallo normal"))
        assertFalse(text.contains("volcado remoto") || text.contains("detalle interno"))
        assertTrue(text.contains("2 entradas de depuración o del agente omitidas"))
        val full = compose(lines, DiagnosticLogPolicy(includesTechnicalDetail = true))
        assertTrue(full.contains("volcado remoto") && full.contains("detalle interno"))
    }

    @Test
    fun `el tope se aplica despues de redactar`() {
        val secret = "sk-ant-oat01-" + "Z9".repeat(40)
        val message = "a".repeat(560) + " " + secret + " fin"
        val text = compose(listOf(entry(message)), DiagnosticLogPolicy(false, 30_000, 600))
        assertFalse(text.contains("Z9Z9"))
        assertFalse(text.contains("sk-ant-oat01"))
        assertTrue(text.contains(DiagnosticSecretScrubber.MARKER))
    }

    @Test
    fun `el tope total conserva lo mas reciente`() {
        val lines = (0 until 200).map { entry("mensaje $it " + "p".repeat(80), at = it.toLong()) }
        val text = compose(lines, DiagnosticLogPolicy(maxBytes = 2_000))
        assertTrue(text.contains("mensaje 199"))
        assertFalse(text.contains("mensaje 0 "))
        assertTrue(text.contains("recortado a lo más reciente"))
    }

    @Test
    fun `el recordatorio de revisar el texto va al pie`() {
        assertTrue(compose(emptyList()).trim().endsWith("no puede garantizar que no se escape alguno."))
    }
}
