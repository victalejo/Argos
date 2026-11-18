package com.iaportafolio.argos.core.doctor

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Paridad con `ArgosTests/DiagnosticSecretScrubberTests.swift`: mismos casos, mismas entradas. */
class DiagnosticSecretScrubberTest {

    private fun scrub(text: String) = DiagnosticSecretScrubber.scrub(text)

    private fun expectHidden(input: String, secrets: List<String>) {
        val output = scrub(input)
        for (secret in secrets) assertFalse(output.contains(secret), "sobrevivió «$secret» en: $output")
    }

    // MARK: Clave/valor

    @Test
    fun `JSON con la clave entre comillas`() {
        expectHidden(
            """{"token": "abc123XYZ", "password":"hunter2", "api_key" : 'k-999', "client_secret": "s3cr3t"}""",
            listOf("abc123XYZ", "hunter2", "k-999", "s3cr3t"),
        )
        val output = scrub("""{"token": "abc123XYZ", "user": "ana"}""")
        assertTrue(output.contains(""""user": "ana""""), "no debe tocar claves ajenas: $output")
    }

    @Test
    fun `nombres habituales de secretos`() {
        expectHidden(
            "access_token=AAA111 refresh_token: BBB222 private_key=CCC333 credentials=DDD444",
            listOf("AAA111", "BBB222", "CCC333", "DDD444"),
        )
        expectHidden(
            "sessionid=EEE555 session_key: FFF666 x-api-key: GGG777 ANTHROPIC_API_KEY=HHH888",
            listOf("EEE555", "FFF666", "GGG777", "HHH888"),
        )
        expectHidden("CLAUDE_CODE_OAUTH_TOKEN=abc123 password: \"hunter 2\" passphrase=secreta", listOf("abc123", "hunter", "secreta"))
    }

    @Test
    fun `auth y session solo se ocultan con valor opaco`() {
        expectHidden("""auth=Zm9vYmFyYmF6cXV4MTIz session: "a1b2c3d4e5f6a7b8"""", listOf("Zm9vYmFyYmF6cXV4MTIz", "a1b2c3d4e5f6a7b8"))
        val normal = "auth: fallida; session: attached; auth=ok"
        assertEquals(normal, scrub(normal))
    }

    @Test
    fun `opciones de linea de comandos`() {
        expectHidden("gh --token ghx-1234 --password=hunter2 --api-key 'k k' run", listOf("ghx-1234", "hunter2", "k k"))
        expectHidden("tool --client-secret zzz999", listOf("zzz999"))
    }

    // MARK: URL

    @Test
    fun `credenciales en URL, tambien con datos personales incluidos`() {
        val input = "git clone https://ana:p%40ss-w0rd@github.com/org/repo.git y postgres://app:S3cr3t!@db.local:5432/x"
        expectHidden(input, listOf("p%40ss-w0rd", "S3cr3t!"))
        assertTrue(scrub(input).contains("https://ana:${DiagnosticSecretScrubber.MARKER}@github.com/org/repo.git"))
        val output = DiagnosticRedactor(includesPersonalData = true).redact(input)
        assertFalse(output.contains("p%40ss-w0rd") || output.contains("S3cr3t!"))
        expectHidden("https://ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com/x", listOf("ghp_abcdefghijkl"))
        expectHidden("https://0123456789abcdefghijABCDEFGH@host.example/x", listOf("0123456789abcdefghij"))
    }

    @Test
    fun `URL sin credenciales ni arrobas ajenas no se tocan`() {
        val texts = listOf(
            "https://github.com/victalejo/Argos/issues/new", "ssh://git@github.com/org/repo", "http://localhost:3000/@user/pkg",
            "http://[::1]:8080/ruta", "mailto:ana@example.com",
        )
        for (text in texts) assertEquals(text, scrub(text))
    }

    // MARK: Sin clave

    @Test
    fun `bloques de clave privada completos, de varias lineas y cortados`() {
        val body = "b3BlbnNzaC1rZXktdjEAAAAABG5vbmU".repeat(4)
        val complete = "antes\n-----BEGIN OPENSSH PRIVATE KEY-----\n$body\n$body\n-----END OPENSSH PRIVATE KEY-----\ndespués"
        val output = scrub(complete)
        assertFalse(output.contains("b3BlbnNz") || output.contains("BEGIN") || output.contains("END OPENSSH"))
        assertTrue(output.startsWith("antes\n") && output.endsWith("\ndespués"))

        assertFalse(scrub("-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n-----END RSA PRIVATE KEY-----").contains("MIIEow"))
        val flattened = "log ⏎ -----BEGIN PRIVATE KEY----- ⏎ $body ⏎ -----END PRIVATE KEY----- ⏎ fin"
        assertFalse(scrub(flattened).contains("b3BlbnNz"))
        assertTrue(scrub(flattened).endsWith("⏎ fin"))
        // Cortado: sin pie, se retira hasta el final.
        assertFalse(scrub("x -----BEGIN OPENSSH PRIVATE KEY-----\n$body").contains("b3BlbnNz"))
        // Cabecera perdida: el cuerpo base64 que precede al pie también se retira.
        val tail = "ruido normal $body\n$body\nQUJDRA==\n-----END OPENSSH PRIVATE KEY-----\nsigue"
        val tailOutput = scrub(tail)
        assertFalse(tailOutput.contains("b3BlbnNz") || tailOutput.contains("QUJDRA=="))
        assertTrue(tailOutput.startsWith("ruido normal ") && tailOutput.endsWith("sigue"), tailOutput)
        // Un pie suelto sin cuerpo no se come la prosa anterior.
        assertTrue(scrub("hola mundo -----END RSA PRIVATE KEY-----").startsWith("hola mundo "))
    }

    @Test
    fun `JWT`() {
        val jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        expectHidden("sesión $jwt ok", listOf("eyJhbGciOiJIUzI1NiJ9", "SflKxwRJSMe"))
        expectHidden("truncado eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0", listOf("eyJzdWIi"))
    }

    @Test
    fun `cabeceras Authorization, Bearer y Basic`() {
        expectHidden("Authorization: Bearer abc.def-ghi_jkl", listOf("abc.def-ghi_jkl"))
        expectHidden("authorization=Basic dXNlcjpwYXNz", listOf("dXNlcjpwYXNz"))
        expectHidden("""{"Authorization": "token ghx_secretvalue"}""", listOf("ghx_secretvalue"))
        expectHidden("Proxy-Authorization: Digest realm123", listOf("realm123"))
        expectHidden("curl -H 'x: y' Bearer 0123456789abcdef", listOf("0123456789abcdef"))
        expectHidden("usó Basic dXNlcjEyMzpwYXNz== en la petición", listOf("dXNlcjEyMzpwYXNz"))
        assertEquals("Basic configuration y Bearer token caducado", scrub("Basic configuration y Bearer token caducado"))
    }

    @Test
    fun `cookies`() {
        expectHidden("Cookie: sid=abc123; theme=dark; _gh_sess=zzz999", listOf("abc123", "theme=dark", "zzz999"))
        expectHidden("Set-Cookie: session=qwerty987; Path=/; HttpOnly", listOf("qwerty987"))
    }

    @Test
    fun `prefijos de token conocidos`() {
        val tokens = listOf(
            "sk-ant-api03-AbCdEfGhIjKlMnOpQr", "sk-ant-oat01-ZZZZ1111yyyy2222", "sk-proj-AbCdEfGhIjKlMnOpQrStUv123",
            "ghp_abcdefghijklmnop1234", "gho_abcdefghijklmnop1234", "ghu_abcdefghijklmnop1234", "ghs_abcdefghijklmnop1234",
            "github_pat_11ABCDEFGHIJKLMNOP_abc", "glpat-AbCdEfGhIjKlMn", "xoxb-1234567890-abcdefgh", "xoxp-1234567890-abcdefgh",
            "AKIAIOSFODNN7EXAMPLE", "npm_abcdefghijklmnopqrstuvwxyz123456", "AIzaSyA-abcdefghijklmnopqrstuvwxyz12345",
            "sk_live_abcdefghij123456",
        )
        for (token in tokens) {
            expectHidden("antes $token después", listOf(token))
            assertEquals("antes ${DiagnosticSecretScrubber.MARKER} después", scrub("antes $token después"), token)
        }
    }

    @Test
    fun `rutas de claves privadas`() {
        val output = scrub("lee /Users/ana/.ssh/id_ed25519 y ~/.ssh/config y /srv/deploy.pem y /home/b/id_rsa.pub y /etc/ssl/server.key")
        for (leaked in listOf("id_ed25519", ".ssh/config", "deploy.pem", "id_rsa", "server.key")) assertFalse(output.contains(leaked), output)
        assertEquals("/usr/bin/tmux y ~/proyectos/app", scrub("/usr/bin/tmux y ~/proyectos/app"))
    }

    // MARK: Negativos

    @Test
    fun `texto normal, hashes y huellas no se tocan`() {
        val normal = listOf(
            "el token caducó",
            "Inicia sesión: el token ha caducado y la contraseña es incorrecta",
            "commit a3f5c9d1e2b4a3f5c9d1e2b4a3f5c9d1e2b4a3f5 en main",
            "huella SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8 de host key",
            "Version: 1.9.0 (build 64) · tmux 3.3a",
            "Doctor del servidor: servidor-1 [Aviso] git: git 2.25.1 es anterior a 2.26",
            "10:42:11.123 [notice] ssh: Canal rechazado (intento 2)",
            "Arreglo: claude auth login y gh auth login",
            "risk-assessment-for-the-whole-project y task-force-numero-uno-muy-largo",
            "Procesos de Claude: 3 procesos de Claude suman 1.2 GB.",
        )
        for (text in normal) assertEquals(text, scrub(text))
    }

    @Test
    fun `un resultado de Doctor sano no se altera`() {
        val facts = DoctorFacts.parse(SAMPLE_HEALTHY_OUTPUT)
        val checks = DoctorEvaluator.evaluate(facts, DoctorEvaluator.Context(Instant.ofEpochSecond(1_800_000_000), hooksUpToDate = true))
        val text = DoctorResult(checks, Instant.EPOCH).plainText("servidor-1")
        assertEquals(text, scrub(text))
    }

    @Test
    fun `es idempotente`() {
        val input = "token=abc123 https://u:p@h.io/x Bearer abcdefgh12345678 -----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----"
        assertEquals(scrub(input), scrub(scrub(input)))
    }

    // MARK: Humo

    @Test
    fun `registro de ejemplo con todos los formatos sin que sobreviva ninguno`() {
        val key = "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo".repeat(3)
        val secrets = listOf(
            "hunter2pass", "p4ssw0rdURL", "tok-json-123", "AAAaccess111", "cookievalue9", "dXNlcjpwYXNzMTIz",
            "eyJhbGciOiJIUzI1NiJ9", "SflKxwRJSMeKKF2QT4fwpMe", "sk-ant-oat01-ZZZZ1111yyyy2222", "ghp_abcdefghijklmnop1234",
            "glpat-AbCdEfGhIjKlMn", "xoxb-1234567890-abcdefgh", "AKIAIOSFODNN7EXAMPLE", "npm_abcdefghijklmnopqrstuvwxyz123456",
            "sk-proj-AbCdEfGhIjKlMnOpQrStUv123", "bearerValue12345678", key, "id_ed25519", "flagsecret77",
        )
        val log = listOf(
            "10:00:01.000 [error] ssh: git push https://ana:p4ssw0rdURL@github.com/org/repo.git falló",
            """10:00:02.000 [error] store: {"token": "tok-json-123", "access_token": "AAAaccess111", "password": "hunter2pass"}""",
            "10:00:03.000 [notice] ssh: Cookie: sid=cookievalue9; theme=dark",
            "10:00:04.000 [error] ssh: Authorization: Basic dXNlcjpwYXNzMTIz y Bearer bearerValue12345678",
            "10:00:05.000 [error] ssh: jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMe_x",
            "10:00:06.000 [error] agent: CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-ZZZZ1111yyyy2222 gh=ghp_abcdefghijklmnop1234 gl=glpat-AbCdEfGhIjKlMn",
            "10:00:07.000 [error] ssh: slack xoxb-1234567890-abcdefgh aws AKIAIOSFODNN7EXAMPLE npm npm_abcdefghijklmnopqrstuvwxyz123456 sk-proj-AbCdEfGhIjKlMnOpQrStUv123",
            "10:00:08.000 [error] ssh: clave -----BEGIN OPENSSH PRIVATE KEY----- ⏎ $key ⏎ -----END OPENSSH PRIVATE KEY----- leída de /Users/ana/.ssh/id_ed25519",
            "10:00:09.000 [error] ssh: cli --token flagsecret77 sigue",
            "10:00:10.000 [notice] ssh: el token caducó; commit a3f5c9d1e2b4a3f5c9d1e2b4a3f5c9d1e2b4a3f5; SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8",
        ).joinToString("\n")
        for (personal in listOf(false, true)) {
            val output = DiagnosticRedactor(includesPersonalData = personal).redact(log)
            for (secret in secrets) assertFalse(output.contains(secret), "sobrevivió «$secret» (personal=$personal)")
            assertTrue(output.contains("el token caducó"))
            assertTrue(output.contains("a3f5c9d1e2b4a3f5c9d1e2b4a3f5c9d1e2b4a3f5"))
            assertTrue(output.contains("SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8"))
        }
    }

    companion object {
        /** Salida sana mínima (la de `DoctorFacts.sampleHealthyOutput` de Swift). */
        val SAMPLE_HEALTHY_OUTPUT = listOf(
            "os=Linux", "clock=1800000000", "tmux.present=yes", "tmux.version=tmux 3.3a", "git.present=yes",
            "git.version=git version 2.43.0", "hooks.settings=ok", "hooks.marker=9", "skill.ports=current", "done=1", "",
        ).joinToString("\n")
    }
}
