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
| `core` | Kotlin/JVM puro: modelo, validadores, `ShellQuoting`, protocolo del agente | **Sin dependencias de Android** (como `ArgosCore/` sin AppKit) |
| `app` | Compose, navegación, servicios, notificaciones | — |

Se añadirán `ssh` (sshj), `data` (DataStore + Keystore) y módulos `feature-*` según avancen
las fases.

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
| 1 | Núcleo puro: portar la lógica de `ArgosCore` con sus tests | ⏳ (`ShellQuoting` hecho) |
| 2 | SSH + servidores: sshj, TOFU, contraseña/clave importada, CRUD de sesiones tmux | |
| 3 | Terminal en vivo: PTY + `tmux attach`, fila de teclas, reattach | |
| 4 | Proyectos + navegador de archivos SFTP | |
| 5 | Agentes persistentes (stream-json, permisos, login guiado) | |
| 6 | Segundo plano y avisos («terminó / espera tu permiso») | |
| 7 | QR desde el Mac (`ServerTransfer`) | |
| 8 | Publicación en Google Play (cuenta de organización **Impulse Vibes**) | |

MVP = fases 0–3.
