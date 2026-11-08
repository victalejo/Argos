# Argos para Android

App nativa **Kotlin + Jetpack Compose** de Argos (gestor de sesiones tmux remotas vía
SSH). Vive en este monorepo para compartir con Apple los scripts del servidor y usar
los tests de `ArgosTests/` (Swift) como **especificación de paridad**.

## Compilar / probar

Requisitos: JDK 17 y Android SDK con `platforms;android-37.0` (`local.properties` →
`sdk.dir`, o la variable `ANDROID_HOME`).

```bash
cd android
./gradlew :core:test                            # núcleo puro (JVM, rápido)
./gradlew :app:assembleDebug :app:lintDebug     # APK de debug + lint (avisos = error)
adb install app/build/outputs/apk/debug/app-debug.apk
```

La CI (`.github/workflows/android.yml`) corre lo mismo cuando cambia `android/**`.

## Módulos

| Módulo | Qué es | Regla |
|---|---|---|
| `core` | Kotlin/JVM puro, port de `ArgosCore` | **Sin dependencias de Android** (como `ArgosCore/` sin AppKit) |
| `ssh` | Kotlin/JVM puro: `SshjConnector`/`SshjSSHService` (sshj), TOFU, `JsonHostKeyTrustStore` | Sin Android; MINA SSHD solo en `testFixtures` |
| `app` | Compose, navegación, servicios, notificaciones | — |

Paquetes de `core`: raíz (`Server`, `SSHServicing`, `ShellQuoting`, `FuzzyMatcher`…),
`tmux` (sesiones, ventanas, comandos y parsers), `projects` (`projects.json` del servidor),
`agent` (stream-json, reducer, lanzador persistente), `status` (actividad de claude y
hooks), `files`, `monitor` y `keys` (Ed25519/OpenSSH con BouncyCastle, QR `ServerTransfer`).

**Paridad byte a byte:** comandos, scripts y JSON se fijan contra salidas generadas por el
código Swift real (`core/src/test/resources/swift-golden/`, golden de `projects.json`,
vectores de claves/QR del Mac). Si cambias un script o formato en Swift, regenera el golden
y ajusta Kotlin: Mac, iPhone y Android comparten servidor.

Se añadirán `data` (DataStore + Keystore) y módulos `feature-*` según avancen
las fases.

## Módulo `ssh`

- La app llama a `SshjConnector.installSecurityProvider()` al arrancar (`Application.onCreate`):
  Android trae un "BC" recortado y sshj necesita el BouncyCastle completo (X25519, Ed25519…).
- Reglas R8: `ssh/consumer-rules.pro`, empaquetadas en el jar como
  `META-INF/proguard/argos-ssh.pro` (R8 las aplica solo al minificar la app).
- Logs de sshj: `slf4j-nop` (sin logback ni ruido en Android).
- `./gradlew :ssh:test` levanta un servidor SSH real embebido (Apache MINA SSHD) que ejecuta
  los comandos con `/bin/sh -c` y tmux de verdad, aislado (`HOME` y `TMUX_TMPDIR` temporales).
  **Necesita tmux instalado** (`brew install tmux` / `apt-get install -y tmux`).

### Servidor de desarrollo (teléfono físico)

```bash
./gradlew :ssh:devServer          # 127.0.0.1:2222, usuario argos / contraseña argos-dev
adb reverse tcp:2222 tcp:2222     # el teléfono llega a 127.0.0.1:2222
```

Imprime la huella de host (persistente en `ssh/build/dev/host_key`) y deja una clave Ed25519
de cliente de prueba en `ssh/build/dev/argos_dev_ed25519`. `HOME` y tmux van aislados en
`ssh/build/dev/` (no toca tus sesiones reales). Ctrl+C lo detiene.

## Pila

| Apple | Android |
|---|---|
| Citadel | sshj (SSH, PTY, exec, SFTP) |
| SwiftTerm | Termux `terminal-emulator` + `terminal-view` |
| Keychain | Android Keystore + almacenamiento cifrado |
| `servers.json` | DataStore + kotlinx.serialization (mismo JSON) |
| TOFU | misma lógica (huella SHA256) |
| iCloud | QR de `ServerTransfer` (`argos://add-server`) desde el Mac |
| BGAppRefreshTask | foreground service `specialUse` (SSH vivo) + WorkManager |

## Fases

| Fase | Alcance | Estado |
|---|---|---|
| 0 | Esqueleto Gradle, `core` + `app`, CI, icono | ✅ |
| 1 | Núcleo puro: portar la lógica de `ArgosCore` con sus tests | ✅ (424 tests) |
| 2 | SSH + servidores: sshj, TOFU, contraseña/clave importada, CRUD de sesiones tmux | ✅ (probado en teléfono real) |
| 3 | Terminal en vivo: PTY + `tmux attach`, fila de teclas, reattach | ✅ (probado en teléfono real) |
| 4 | Proyectos + navegador de archivos SFTP | ✅ (probado en teléfono real) |
| 5 | Agentes persistentes (stream-json, permisos, login guiado) | ✅ (probado en teléfono real con claude simulado) |
| 6 | Segundo plano y avisos («terminó / espera tu permiso») | |
| 7 | QR desde el Mac (`ServerTransfer`) | |
| 8 | Publicación en Google Play (cuenta de organización **Impulse Vibes**) | |

MVP = fases 0–3.
