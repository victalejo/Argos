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

La CI (`.github/workflows/android.yml`) corre lo mismo cuando cambia `android/**`, más los tests de
`app` y un `bundleRelease` sin firmar (R8 + comprobación `checkReleaseR8Keeps`).

## Módulos

| Módulo | Qué es | Regla |
|---|---|---|
| `core` | Kotlin/JVM puro, port de `ArgosCore` | **Sin dependencias de Android** (como `ArgosCore/` sin AppKit) |
| `ssh` | Kotlin/JVM puro: `SshjConnector`/`SshjSSHService` (sshj), TOFU, `JsonHostKeyTrustStore` | Sin Android; MINA SSHD solo en `testFixtures` |
| `app` | Compose, navegación, servicios, notificaciones | — |

Paquetes de `core`: raíz (`Server`, `SSHServicing`, `ShellQuoting`, `FuzzyMatcher`…),
`tmux` (sesiones, ventanas, comandos y parsers), `projects` (`projects.json` del servidor),
`agent` (stream-json, reducer, lanzador persistente), `status` (actividad de claude y
hooks), `files`, `git` (panel «Cambios» y resumen de la lista: git corre en el servidor), `github` (PR, CI y clonado con el `gh` del servidor), `monitor` y `keys` (Ed25519/OpenSSH con BouncyCastle, QR `ServerTransfer`).

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

### QR de prueba sin Mac (importar servidor)

```bash
./gradlew :ssh:devTransferLink              # enlace válido 5 min (-Pcaducado: ya caducado)
```

Hace lo mismo que «Enviar al iPhone…» del Mac para el `devServer`: crea una clave Ed25519 nueva,
la autoriza en `ssh/build/dev/home/.ssh/authorized_keys` (el servidor embebido relee ese archivo en
cada intento, como OpenSSH, así que vale con el `devServer` ya en marcha) y escribe
`ssh/build/dev/transfer-link.txt` (enlace `argos://add-server?d=…` con la huella real del host y
`127.0.0.1:2222`) y `ssh/build/dev/transfer-qr.png` (ábrelo en la pantalla y escanéalo). Deep link:

```bash
adb shell "am start -W -a android.intent.action.VIEW -d '$(cat ssh/build/dev/transfer-link.txt)' com.iaportafolio.argos"
```

## Importar desde el Mac (`ui/importer/`)

Servidores → «Importar desde el Mac (QR)»: escáner con **CameraX + ZXing core** (solo QR, sin ML
Kit ni servicios de Google ni red), enlace pegado o deep link `argos://add-server` (abre la
confirmación; **nunca importa sin que el usuario la acepte**). El permiso `CAMERA` se pide en el
momento; la cámara es opcional (`uses-feature required="false"`) y se libera al salir. La
confirmación replica la de iOS (huella, duplicado, conflicto de identidad bloqueante).
`ServerImporter` guarda la clave cifrada con el Keystore, la huella del QR si el endpoint no tenía
ninguna y deshace lo escrito si falla algún paso. El enlace con la semilla no se guarda en el
estado de navegación ni en logs.

## Segundo plano (`background/`)

**Avisos de agentes** (`AgentNotifier`, como `AgentNotifier.swift`): sin push ni servidores
intermedios. Para cada servidor apuntado (al crear o abrir un agente) abre una conexión nueva, lee
`PersistentAgentScript.snapshots()` y avisa de lo nuevo. Corre con WorkManager cada 15 min (con
red) y, mientras viva el servicio del terminal, cada ~60 s. En segundo plano **nunca se confía en
una huella nueva**: un endpoint sin huella guardada se salta hasta conectar desde la app.

**Terminal vivo** (`TerminalKeepAliveService`, servicio en primer plano `specialUse`): mantiene el
proceso mientras haya terminales adjuntos; la conexión sigue en los `TerminalViewModel`. Se arranca
con la app en primer plano al adjuntar el primero; si el sistema no lo deja, el terminal vuelve a
hacer detach/reattach. Se desactiva en Ajustes → Avisos y segundo plano.

**Limitación conocida:** a propósito no se usa WifiLock ni WakeLock. El servicio protege al proceso
de que lo maten, no al móvil de dormirse: en Doze el sistema puede cortar la red y parar la CPU, así
que la conexión puede caer y los `delay` retrasarse. Al despertar, o al volver a la app, el
reintento con backoff reengancha (tmux conserva la sesión); si los intentos se agotan en segundo
plano, el servicio se para y se reengancha al volver. Los avisos dependen de cuándo deje correr el
sistema el trabajo periódico: 15 min es un mínimo, no una garantía.

**Google Play:** `FOREGROUND_SERVICE_SPECIAL_USE` exige declarar el servicio en Play Console
(Contenido de la app → Permisos de servicios en primer plano) con justificación y un vídeo. La
descripción está en la `property` del manifiesto. La revisión de `specialUse` es manual y puede
rechazarse: si ocurre, se puede retirar el servicio y los avisos siguen por WorkManager.

### Probar por adb (teléfono físico)

```bash
adb shell dumpsys jobscheduler | grep 'JOB .*iaportafolio'   # id: número tras u0aNNN/ (WorkManager no adelanta un periódico antes de su hora)
adb shell cmd jobscheduler run -f -n androidx.work.systemjobscheduler com.iaportafolio.argos <id>  # dispara la comprobación
adb shell dumpsys activity services com.iaportafolio.argos         # ¿servicio en marcha? isForeground
adb logcat -s Argos.agent Argos.terminal                           # fallos, sin secretos ni contenido
adb shell dumpsys deviceidle force-idle                            # simula Doze (`unforce` para salir)
```

## Publicación (Google Play)

Cuenta de organización **Impulse Vibes**, `applicationId` `com.iaportafolio.argos`. Pasos en Play
Console, en orden: [`play/checklist.md`](play/checklist.md). Formularios: [`play/data-safety.md`](play/data-safety.md),
[`play/foreground-service.md`](play/foreground-service.md) (con guion del vídeo),
[`play/review-notes.md`](play/review-notes.md), [`play/content-rating.md`](play/content-rating.md).

### Versión

`android/gradle.properties`: `ARGOS_VERSION_NAME` (lo que ve el usuario, p. ej. `1.0.0`) y
`ARGOS_VERSION_CODE` (entero). **Antes de cada subida a Play sube `ARGOS_VERSION_CODE`** (Play
rechaza un código repetido o menor). El tag de la CI debe ser `android-v<ARGOS_VERSION_NAME>`.

### Firma

`signingConfigs.release` lee cuatro valores, primero como propiedad de Gradle (`-P…` o
`~/.gradle/gradle.properties`, **nunca** el `gradle.properties` del repo) y si no, como variable de
entorno: `ARGOS_UPLOAD_STORE_FILE` (ruta al `.jks`; relativa a `android/`), `ARGOS_UPLOAD_STORE_PASSWORD`,
`ARGOS_UPLOAD_KEY_ALIAS`, `ARGOS_UPLOAD_KEY_PASSWORD`.

- **Ninguno definido:** el release se construye SIN firmar (CI de PR) y `assembleRelease`/`bundleRelease`
  lo avisan. Con `ARGOS_REQUIRE_SIGNING=true` (la CI de publicación) falla.
- **Algunos sí y otros no**, o el `.jks` no existe: la build falla (casi seguro un error de configuración).
- Es la clave de **subida**: con Play App Signing, Google firma lo que llega a los usuarios. `.gitignore`
  ignora `*.jks`, `*.keystore` y `play-service-account*.json`.

Firmar en local (las contraseñas en `~/.gradle/gradle.properties`, fuera del repo):

```properties
# ~/.gradle/gradle.properties
ARGOS_UPLOAD_STORE_FILE=/Users/<tú>/claves/argos-upload.jks
ARGOS_UPLOAD_STORE_PASSWORD=…
ARGOS_UPLOAD_KEY_ALIAS=argos-upload
ARGOS_UPLOAD_KEY_PASSWORD=…
```

```bash
./gradlew :app:bundleRelease -PARGOS_REQUIRE_SIGNING=true   # app/build/outputs/bundle/release/app-release.aab
```

### R8

Release con `isMinifyEnabled` + `isShrinkResources`. Reglas: las de cada librería (kotlinx.serialization,
WorkManager, CameraX, Navigation, Compose y AboutLibraries traen las suyas), `ssh/consumer-rules.pro`
(sshj, BouncyCastle, slf4j) y `app/proguard-rules.pro`. Termux no usa reflexión y su JNI
(`libtermux.so`) se excluye del APK. `checkReleaseR8Keeps` (corre tras `assembleRelease`/`bundleRelease`)
falla si R8 renombra o elimina lo que se carga por nombre (proveedor BouncyCastle, `AgentCheckWorker`,
el servicio, componentes del manifiesto, sshj, binding de slf4j).

### Licencias y «Acerca de»

Ajustes (engranaje de Servidores) → «Acerca de» / «Licencias de código abierto». La lista la genera
en cada build el plugin de AboutLibraries (`com.mikepenz.aboutlibraries.plugin.android`, variante
Android del plugin `com.mikepenz.aboutlibraries.plugin`) con las dependencias del release:

- `strictMode = FAIL`: una dependencia con una licencia no permitida rompe la build. Permitidas:
  Apache 2.0, MIT, BSD, EPL y la de Bouncy Castle.
- Modo offline: los textos de licencia van en `app/config/licenses/` (el plugin no los descarga).
- Termux llega de JitPack con licencia «Other»: se excluye lo detectado y se define a mano en
  `app/config/libraries/termux-*.json` (Apache 2.0). **Si subes `termux` en el catálogo, actualiza
  ahí `artifactVersion`.**
- `OpenSourceLicensesTest` comprueba Termux, las dependencias clave y que cada licencia tenga texto.
- Los enlaces (política de privacidad, repositorio, webs de librerías) se abren solo tras confirmar la
  URL (`ProvideConfirmedLinks` + `SafeLinkPolicy`, lo mismo que los enlaces de un Markdown).

### Ficha (Gradle Play Publisher)

`app/src/main/play/`: `default-language.txt` (`es-419`), `listings/{es-419,es-ES,en-US}/` (título ≤30,
descripción breve ≤80, completa ≤4000), `release-notes/es-419/internal.txt` (≤500) y
`contact-website.txt` y `contact-email.txt` (alejo@iaportafolio.com).
`PlayListingTest` valida longitudes y que la ficha no prometa funciones solo de Apple. La ficha
describe SOLO lo que existe en Android: si quitas o añades una función, actualízala.

Configuración en `app/build.gradle.kts` → `play {}`: pista `internal`, `releaseStatus = DRAFT`,
`defaultToAppBundles = true`, credenciales de `ARGOS_PLAY_SERVICE_ACCOUNT` (**ruta** al JSON de la
cuenta de servicio). El primer AAB se sube a mano en Play Console (la API no crea apps).

```bash
ARGOS_PLAY_SERVICE_ACCOUNT=~/claves/play-service-account-argos.json ./gradlew :app:publishReleaseBundle  # borrador interno
ARGOS_PLAY_SERVICE_ACCOUNT=… ./gradlew :app:publishListing                                               # solo textos
```

### CI de publicación (`.github/workflows/android-release.yml`)

Se lanza con un tag `android-v*` (debe coincidir con `ARGOS_VERSION_NAME`) o a mano. Antes de tocar
la clave pasa el mismo gate que `android.yml` (tests de `core`, `ssh` y `app`, y lint). Después decodifica
la clave, construye el `bundleRelease` firmado, verifica la firma, sube el AAB y el
`mapping.txt` como artefacto `argos-android-aab` y, **solo si existe** `ARGOS_PLAY_SERVICE_ACCOUNT`,
ejecuta `publishReleaseBundle` (borrador en la pista interna). Token con `contents: read`.

| Secreto de GitHub Actions | Contenido |
|---|---|
| `ARGOS_UPLOAD_KEYSTORE_BASE64` | El `.jks` en base64 (`base64 -i argos-upload.jks \| pbcopy`) |
| `ARGOS_UPLOAD_STORE_PASSWORD` | Contraseña del almacén |
| `ARGOS_UPLOAD_KEY_ALIAS` | Alias de la clave |
| `ARGOS_UPLOAD_KEY_PASSWORD` | Contraseña de la clave |
| `ARGOS_PLAY_SERVICE_ACCOUNT` | *(opcional)* contenido del JSON de la cuenta de servicio (permisos mínimos: ver `play/checklist.md`) |

```bash
# subir ARGOS_VERSION_CODE (y ARGOS_VERSION_NAME) en gradle.properties, commit, y:
git tag android-v1.0.0 && git push origin android-v1.0.0
```

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
| 6 | Segundo plano y avisos («terminó / espera tu permiso») | ✅ (probado en teléfono real) |
| 7 | QR desde el Mac (`ServerTransfer`): escáner, enlace pegado, deep link | ✅ (probado en teléfono real; cámara real sin probar con el Mac) |
| 8 | Publicación en Google Play (cuenta de organización **Impulse Vibes**): firma, versión, licencias y «Acerca de», ficha (GPP), documentos de Play Console y CI de publicación | ✅ prueba interna publicada en Play (IA Portafolio); producción 1.0.0 enviada a revisión de Google (2026-11-08) |

MVP = fases 0–3.
