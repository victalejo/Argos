//
//  DiagnosticSecretScrubberTests.swift
//  ArgosTests
//
//  Cada formato de secreto que el informe de diagnóstico debe ocultar SIEMPRE, los casos
//  negativos (texto normal que no se toca) y una prueba de humo con un registro mezclado.
//

import Foundation
import Testing
@testable import Argos

@Suite("DiagnosticSecretScrubber")
struct DiagnosticSecretScrubberTests {

    private func scrub(_ text: String) -> String { DiagnosticSecretScrubber.scrub(text) }

    private func expectHidden(_ input: String, secrets: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        let output = scrub(input)
        for secret in secrets {
            #expect(!output.contains(secret), "sobrevivió «\(secret)» en: \(output)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Clave/valor

    @Test("JSON con la clave entre comillas")
    func jsonKeys() {
        expectHidden(#"{"token": "abc123XYZ", "password":"hunter2", "api_key" : 'k-999', "client_secret": "s3cr3t"}"#,
                     secrets: ["abc123XYZ", "hunter2", "k-999", "s3cr3t"])
        let output = scrub(#"{"token": "abc123XYZ", "user": "ana"}"#)
        #expect(output.contains(#""user": "ana""#), "no debe tocar claves ajenas: \(output)")
    }

    @Test("Nombres habituales: access/refresh token, private key, credential, session id, authorization")
    func keyNames() {
        expectHidden("access_token=AAA111 refresh_token: BBB222 private_key=CCC333 credentials=DDD444",
                     secrets: ["AAA111", "BBB222", "CCC333", "DDD444"])
        expectHidden("sessionid=EEE555 session_key: FFF666 x-api-key: GGG777 ANTHROPIC_API_KEY=HHH888",
                     secrets: ["EEE555", "FFF666", "GGG777", "HHH888"])
        expectHidden("CLAUDE_CODE_OAUTH_TOKEN=abc123 password: \"hunter 2\" passphrase=secreta",
                     secrets: ["abc123", "hunter", "secreta"])
    }

    @Test("auth y session solo se ocultan con valor opaco")
    func ambiguousKeys() {
        expectHidden(#"auth=Zm9vYmFyYmF6cXV4MTIz session: "a1b2c3d4e5f6a7b8""#, secrets: ["Zm9vYmFyYmF6cXV4MTIz", "a1b2c3d4e5f6a7b8"])
        let normal = "auth: fallida; session: attached; auth=ok"
        #expect(scrub(normal) == normal)
    }

    @Test("Opciones de línea de comandos")
    func flags() {
        expectHidden("gh --token ghx-1234 --password=hunter2 --api-key 'k k' run", secrets: ["ghx-1234", "hunter2", "k k"])
        expectHidden("tool --client-secret zzz999", secrets: ["zzz999"])
    }

    // MARK: - URL

    @Test("Credenciales en URL, también con datos personales incluidos")
    func urlCredentials() {
        let input = "git clone https://ana:p%40ss-w0rd@github.com/org/repo.git y postgres://app:S3cr3t!@db.local:5432/x"
        expectHidden(input, secrets: ["p%40ss-w0rd", "S3cr3t!"])
        #expect(scrub(input).contains("https://ana:\(DiagnosticSecretScrubber.marker)@github.com/org/repo.git"))
        var redactor = DiagnosticRedactor(includesPersonalData: true)
        let output = redactor.redact(input)
        #expect(!output.contains("p%40ss-w0rd") && !output.contains("S3cr3t!"))
        expectHidden("https://ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com/x", secrets: ["ghp_abcdefghijkl"])
        expectHidden("https://0123456789abcdefghijABCDEFGH@host.example/x", secrets: ["0123456789abcdefghij"])
    }

    @Test("URL sin credenciales ni arrobas ajenas no se tocan")
    func urlNegatives() {
        for text in ["https://github.com/victalejo/Argos/issues/new", "ssh://git@github.com/org/repo", "http://localhost:3000/@user/pkg",
                     "http://[::1]:8080/ruta", "mailto:ana@example.com"] {
            #expect(scrub(text) == text)
        }
    }

    // MARK: - Sin clave

    @Test("Bloques de clave privada: completos, de varias líneas y cortados")
    func privateKeys() {
        let body = String(repeating: "b3BlbnNzaC1rZXktdjEAAAAABG5vbmU", count: 4)
        let complete = "antes\n-----BEGIN OPENSSH PRIVATE KEY-----\n\(body)\n\(body)\n-----END OPENSSH PRIVATE KEY-----\ndespués"
        let output = scrub(complete)
        #expect(!output.contains("b3BlbnNz") && !output.contains("BEGIN") && !output.contains("END OPENSSH"))
        #expect(output.hasPrefix("antes\n") && output.hasSuffix("\ndespués"))

        let rsa = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n-----END RSA PRIVATE KEY-----"
        #expect(!scrub(rsa).contains("MIIEow"))
        let flattened = "log ⏎ -----BEGIN PRIVATE KEY----- ⏎ \(body) ⏎ -----END PRIVATE KEY----- ⏎ fin"
        #expect(!scrub(flattened).contains("b3BlbnNz"))
        #expect(scrub(flattened).hasSuffix("⏎ fin"))
        // Cortado: sin pie, se retira hasta el final.
        #expect(!scrub("x -----BEGIN OPENSSH PRIVATE KEY-----\n\(body)").contains("b3BlbnNz"))
        // Cabecera perdida: el cuerpo base64 que precede al pie también se retira.
        let tail = "ruido normal \(body)\n\(body)\nQUJDRA==\n-----END OPENSSH PRIVATE KEY-----\nsigue"
        let tailOutput = scrub(tail)
        #expect(!tailOutput.contains("b3BlbnNz") && !tailOutput.contains("QUJDRA=="))
        #expect(tailOutput.hasPrefix("ruido normal ") && tailOutput.hasSuffix("sigue"))
        // Un pie suelto sin cuerpo no se come la prosa anterior.
        #expect(scrub("hola mundo -----END RSA PRIVATE KEY-----").hasPrefix("hola mundo "))
    }

    @Test("JWT")
    func jwts() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        expectHidden("sesión \(jwt) ok", secrets: ["eyJhbGciOiJIUzI1NiJ9", "SflKxwRJSMe"])
        expectHidden("truncado eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0", secrets: ["eyJzdWIi"])
    }

    @Test("Cabeceras Authorization, Bearer y Basic")
    func authorizationHeaders() {
        expectHidden("Authorization: Bearer abc.def-ghi_jkl", secrets: ["abc.def-ghi_jkl"])
        expectHidden("authorization=Basic dXNlcjpwYXNz", secrets: ["dXNlcjpwYXNz"])
        expectHidden(#"{"Authorization": "token ghx_secretvalue"}"#, secrets: ["ghx_secretvalue"])
        expectHidden("Proxy-Authorization: Digest realm123", secrets: ["realm123"])
        expectHidden("curl -H 'x: y' Bearer 0123456789abcdef", secrets: ["0123456789abcdef"])
        expectHidden("usó Basic dXNlcjEyMzpwYXNz== en la petición", secrets: ["dXNlcjEyMzpwYXNz"])
        #expect(scrub("Basic configuration y Bearer token caducado") == "Basic configuration y Bearer token caducado")
    }

    @Test("Cookies")
    func cookies() {
        expectHidden("Cookie: sid=abc123; theme=dark; _gh_sess=zzz999", secrets: ["abc123", "theme=dark", "zzz999"])
        expectHidden("Set-Cookie: session=qwerty987; Path=/; HttpOnly", secrets: ["qwerty987"])
    }

    @Test("Prefijos de token conocidos")
    func tokenPrefixes() {
        let tokens = [
            "sk-ant-api03-AbCdEfGhIjKlMnOpQr", "sk-ant-oat01-ZZZZ1111yyyy2222", "sk-proj-AbCdEfGhIjKlMnOpQrStUv123",
            "ghp_abcdefghijklmnop1234", "gho_abcdefghijklmnop1234", "ghu_abcdefghijklmnop1234", "ghs_abcdefghijklmnop1234",
            "github_pat_11ABCDEFGHIJKLMNOP_abc", "glpat-AbCdEfGhIjKlMn", "xoxb-1234567890-abcdefgh", "xoxp-1234567890-abcdefgh",
            "AKIAIOSFODNN7EXAMPLE", "npm_abcdefghijklmnopqrstuvwxyz123456", "AIzaSyA-abcdefghijklmnopqrstuvwxyz12345",
            "sk_live_abcdefghij123456",
        ]
        for token in tokens {
            expectHidden("antes \(token) después", secrets: [token])
            #expect(scrub("antes \(token) después") == "antes \(DiagnosticSecretScrubber.marker) después", "\(token)")
        }
    }

    @Test("Rutas de claves privadas")
    func keyPaths() {
        let output = scrub("lee /Users/ana/.ssh/id_ed25519 y ~/.ssh/config y /srv/deploy.pem y /home/b/id_rsa.pub y /etc/ssl/server.key")
        for leaked in ["id_ed25519", ".ssh/config", "deploy.pem", "id_rsa", "server.key"] { #expect(!output.contains(leaked)) }
        #expect(scrub("/usr/bin/tmux y ~/proyectos/app") == "/usr/bin/tmux y ~/proyectos/app")
    }

    // MARK: - Negativos

    @Test("Texto normal, hashes y huellas no se tocan")
    func negatives() {
        let normal = [
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
        ]
        for text in normal { #expect(scrub(text) == text, "cambió: \(scrub(text))") }
    }

    @Test("Un resultado de Doctor sano no se altera")
    func healthyDoctorUntouched() {
        let facts = DoctorFacts.parse(DoctorFacts.sampleHealthyOutput)
        let checks = DoctorEvaluator.evaluate(facts, context: .init(deviceNow: Date(timeIntervalSince1970: 1_800_000_000), hooksUpToDate: true))
        let text = DoctorResult(checks: checks, finishedAt: Date()).plainText(serverLabel: "servidor-1")
        #expect(scrub(text) == text)
    }

    @Test("Es idempotente")
    func idempotent() {
        let input = "token=abc123 https://u:p@h.io/x Bearer abcdefgh12345678 -----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----"
        #expect(scrub(scrub(input)) == scrub(input))
    }

    // MARK: - Humo

    @Test("Registro de ejemplo con todos los formatos: ninguno sobrevive, ni con datos personales")
    func smoke() {
        let key = String(repeating: "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo", count: 3)
        let secrets = [
            "hunter2pass", "p4ssw0rdURL", "tok-json-123", "AAAaccess111", "cookievalue9", "dXNlcjpwYXNzMTIz",
            "eyJhbGciOiJIUzI1NiJ9", "SflKxwRJSMeKKF2QT4fwpMe", "sk-ant-oat01-ZZZZ1111yyyy2222", "ghp_abcdefghijklmnop1234",
            "glpat-AbCdEfGhIjKlMn", "xoxb-1234567890-abcdefgh", "AKIAIOSFODNN7EXAMPLE", "npm_abcdefghijklmnopqrstuvwxyz123456",
            "sk-proj-AbCdEfGhIjKlMnOpQrStUv123", "bearerValue12345678", key, "id_ed25519", "flagsecret77",
        ]
        let log = """
        10:00:01.000 [error] ssh: git push https://ana:p4ssw0rdURL@github.com/org/repo.git falló
        10:00:02.000 [error] store: {"token": "tok-json-123", "access_token": "AAAaccess111", "password": "hunter2pass"}
        10:00:03.000 [notice] ssh: Cookie: sid=cookievalue9; theme=dark
        10:00:04.000 [error] ssh: Authorization: Basic dXNlcjpwYXNzMTIz y Bearer bearerValue12345678
        10:00:05.000 [error] ssh: jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMe_x
        10:00:06.000 [error] agent: CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-ZZZZ1111yyyy2222 gh=ghp_abcdefghijklmnop1234 gl=glpat-AbCdEfGhIjKlMn
        10:00:07.000 [error] ssh: slack xoxb-1234567890-abcdefgh aws AKIAIOSFODNN7EXAMPLE npm npm_abcdefghijklmnopqrstuvwxyz123456 sk-proj-AbCdEfGhIjKlMnOpQrStUv123
        10:00:08.000 [error] ssh: clave -----BEGIN OPENSSH PRIVATE KEY----- ⏎ \(key) ⏎ -----END OPENSSH PRIVATE KEY----- leída de /Users/ana/.ssh/id_ed25519
        10:00:09.000 [error] ssh: cli --token flagsecret77 sigue
        10:00:10.000 [notice] ssh: el token caducó; commit a3f5c9d1e2b4a3f5c9d1e2b4a3f5c9d1e2b4a3f5; SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8
        """
        for personal in [false, true] {
            var redactor = DiagnosticRedactor(includesPersonalData: personal)
            let output = redactor.redact(log)
            for secret in secrets { #expect(!output.contains(secret), "sobrevivió «\(secret)» (personal=\(personal))") }
            // Lo que no es secreto se conserva.
            #expect(output.contains("el token caducó"))
            #expect(output.contains("a3f5c9d1e2b4a3f5c9d1e2b4a3f5c9d1e2b4a3f5"))
            #expect(output.contains("SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8"))
        }
    }
}
