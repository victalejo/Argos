# CLAUDE.md

Orientación para Claude Code al trabajar en este repositorio.

## Proyecto

**Argos** es una app nativa de **macOS** (SwiftUI), **iPhone/iPad** y **Android** que actúa
como **gestor de proyectos y sesiones tmux remotas vía SSH**: cada proyecto está anclado a
una carpeta del servidor y ofrece Terminal en vivo (PTY sobre SSH + `tmux attach`),
Archivos, Cambios (git/GitHub), puertos y agentes de Claude Code. Es **multi-servidor**: los
servidores se configuran y persisten desde la UI (no hay servidor hardcodeado).

- Bundle ID: `com.iaportafolio.argos`
- Target de despliegue: **macOS 15.0** (Citadel `withPTY`/`TTYOutput` son `@available(macOS 15.0, *)`) e **iOS 18.0**
- Lenguaje: Swift 5 mode con concurrencia (`actor`, `@MainActor`, `Sendable`)
- Dependencias SPM: **Citadel** (SSH, pin minor 0.12.x), **SwiftTerm** (terminal, 1.18.x:
  1.19+ añade un plugin que `xcodebuild` rechaza y 1.99+ exige tools 6.2), **Sparkle**
  (solo canal GitHub, 2.10.x) y **MarkdownUI**

## Compilar / Ejecutar / Probar

`project.yml` es la **fuente de verdad** del proyecto (XcodeGen). El `.xcodeproj`
se versiona como artefacto generado.

```bash
# Tras editar project.yml (añadir archivos, deps, settings): regenerar SIEMPRE.
# También al añadir o quitar archivos Swift: el .pbxproj los lista.
xcodegen generate

# Tres esquemas: Argos (Mac, canal GitHub), ArgosAppStore (Mac App Store) y ArgosiOS
xcodebuild -project Argos.xcodeproj -scheme Argos -configuration Debug build
xcodebuild -project Argos.xcodeproj -scheme ArgosAppStore -configuration Debug build
xcodebuild -project Argos.xcodeproj -scheme ArgosiOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build

# Tests (Swift Testing). ArgosTests es host-less y cuelga del esquema Argos;
# ArgosiOSUITests (interfaz, sin red) cuelga de ArgosiOS y necesita un simulador concreto.
xcodebuild -project Argos.xcodeproj -scheme Argos test

# Ejecutar la app compilada
open ~/Library/Developer/Xcode/DerivedData/Argos-*/Build/Products/Debug/Argos.app
```

La **CI** (`.github/workflows/ci.yml`, tres trabajos en paralelo: Mac, Mac App Store e iOS)
y el **release** compilan con **Xcode 16.4 (Swift 6.1, SDK de macOS 15 / iOS 18)** aunque en
local haya un Xcode más nuevo. Lo que compila en local puede no compilar allí:
- No uses sintaxis ni API de Swift 6.2+ (p. ej. `nonisolated(nonsending)`; si un API nuevo
  es imprescindible, `#if compiler(>=6.2)` con una alternativa para 6.1).
- Los **cuerpos de vista SwiftUI deben ser pequeños**: parte `body` en propiedades y
  funciones de vista por tema y da tipo explícito a cierres y `Binding`; el compilador de la
  CI abandona las expresiones que tardan en comprobarse.
- En `String(localized:)` interpola **solo `String` o números**: el SDK antiguo no admite
  `Error`, `Substring` ni `Character` (conviértelos con `String(…)`). Un test
  (`LocalizationInterpolationTests`) escanea las fuentes y lo comprueba.

Pruebas y puertas de la CI que conviene conocer:
- **Cobertura del núcleo**: `scripts/coverage_core.py` mide solo `ArgosCore/` y falla si baja
  de `CORE_COVERAGE_MIN` (en `ci.yml`; sube cuando sube la cobertura, nunca se baja para
  que pase un cambio).
- **Integración contra un `sshd` real y temporal** (`ArgosTests/Integration*`, activadas
  solo si el entorno trae el servidor). `scripts/sshd-test-start.sh [--max-sessions N]
  [--port P] [--dir D] [--force-sh]` arranca un `sshd` sin root en 127.0.0.1 con claves y
  `HOME` aislados e instala un `claude` simulado (`scripts/argos-fake-claude`: no es el real;
  lo que no reproduce queda sin probar); imprime `ARGOS_E2E_SSH_*`, `ARGOS_E2E_SSHD_DIR` y
  `ARGOS_E2E_SERVER_OS`, que `xcodebuild` solo pasa a los tests con el prefijo
  `TEST_RUNNER_`. Hace falta `tmux` local. Para pararlo: `scripts/sshd-test-stop.sh [--keep] <dir>`.
  ```bash
  eval "$(scripts/sshd-test-start.sh --max-sessions 4 | sed 's/^/export TEST_RUNNER_/')"
  xcodebuild test -scheme Argos -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
    -only-testing:ArgosTests/IntegrationSSHDTests \
    -only-testing:ArgosTests/IntegrationServerSuites
  scripts/sshd-test-stop.sh "$TEST_RUNNER_ARGOS_E2E_SSHD_DIR"
  ```
- **Goldens de paridad con Android**: `GoldenParityTests` compara cada archivo de
  `android/core/src/test/resources/swift-golden/` con lo que genera el Swift real
  (`GoldenCatalog*`). Tras cambiar un script o formato remoto, ejecuta
  `scripts/regenerate-swift-goldens.sh` (reescribe los goldens; `--check` falla si quedan
  desfasados, como hace la CI), commitéalos y ajusta Kotlin. Los goldens sin función pura
  o aún sin portar a Android (hoy, los puntos de restauración) van en listas explícitas de
  excepciones del propio test.
- **Idioma de los tests**: el esquema `Argos` los fija en español (`language: es`) porque
  comparan cientos de mensajes en español y la CI corre en inglés; los tests de inglés
  fuerzan su idioma ellos mismos y los de interfaz de iOS pasan el español al lanzar la app.

## Arquitectura y convenciones

**Estructura de carpetas (multiplataforma):**

- `ArgosCore/` — **núcleo compartido** Mac + iPhone/iPad: modelo, servicio SSH, stores,
  protocolo del agente, view models. Lo compilan los targets `Argos`/`ArgosAppStore` y
  `ArgosiOS`. **Prohibido** importar AppKit/SwiftUI/SwiftTerm/Sparkle o usar APIs
  solo-macOS aquí (si hace falta, `#if os(macOS)`). La CI compila `ArgosiOS` para
  garantizarlo. Subcarpetas: `Agent/` (protocolo, agentes persistentes, guardia de
  memoria, inventario), `Attention/` (bandeja «Te necesita»), `ClaudeStatus/` (indicador y
  hooks de Claude), `CloudSync/` (iCloud), `Doctor/` (Doctor y redacción del diagnóstico),
  `Files/`, `Git/` (cambios, worktrees y **puntos de restauración**), `GitHub/`,
  `Lifecycle/` (vuelta de segundo plano), `Monitor/`, `PortForwarding/`, `Projects/`
  (`projects.json`), `Shortcuts/` (lógica de los atajos de iOS), `Sync/`, `Tabs/`,
  `Terminal/` (reconexión y teclas) y `Workspace/` (sondeador compartido, impacto de
  editar un servidor, cierre ordenado). En la raíz: `SSHService` y sus extensiones,
  `ChannelGate`, `ConnectionHealth`, `LinkLiveness`, `RemoteTimeout`, `Deadline`, stores.
- `android/` — app de **Android**, Kotlin + Jetpack Compose (Gradle, NO XcodeGen). El
  módulo `core` es Kotlin/JVM puro (sin Android) y porta `ArgosCore`: los tests de
  `ArgosTests/` y los goldens son su especificación de paridad. Ver `android/README.md`
  (comandos, pila, fases). CI aparte: `.github/workflows/android.yml`.
- `ArgosUI/` — **vistas SwiftUI compartidas** Mac + iPhone/iPad (sin AppKit/UIKit):
  mascota de Claude, iconos de agentes, insignias, diff y estado de GitHub.
- `Argos/` — app de **macOS**: vistas SwiftUI/AppKit, terminal SwiftTerm, Sparkle,
  "Enviar al Mac" (`Sync/`), pool `TerminalSessionStore`. Subcarpetas por función
  (`Agent/`, `Attention/` con el extra de barra de menús y la insignia del Dock, `Doctor/`,
  `Files/`, `Git/`, `Projects/`, `Workspace/`…). `Workspace/ArgosAppModel` es el
  **modelo único de la app** (vive en el delegado): es dueño de servidores, iCloud, view
  models, terminales, agentes, solicitudes de puertos y sondeo; la ventana (`Window`, única)
  solo lo observa, y cerrarla no cierra la app (`TerminationCoordinator` hace la salida
  ordenada con plazo). Se compila en **dos variantes** (plantilla `ArgosMac`): `Argos`
  (canal GitHub, Sparkle, excepciones temporales de sandbox) y `ArgosAppStore` (Mac App
  Store, flag `APPSTORE`, sin Sparkle ni excepciones: ~/.ssh por carpeta concedida y
  Terminal por script de usuario; ver `Argos/AppStore/` y `scripts/appstore/README.md`).
  Ambas deben tener las MISMAS funciones: usa `#if APPSTORE` solo para elegir el mecanismo.
- `ArgosiOS/` — app de **iPhone/iPad** (mismo bundle id → compra universal): servidores
  (contraseña, clave importada/pegada/creada en el dispositivo con `ImportedKeyStore`,
  `SSHKeyInspector`), proyectos/sesiones (`SessionsViewModel` compartido), y por proyecto
  Terminal (SwiftTerm, `TouchTerminalController`, `TerminalKeyBar`) · Archivos · Cambios ·
  Agentes. Una sola raíz de navegación restaurable (`AppNavigation`); en iPad, tres
  columnas (`SplitRootView`). `ServerHub` reparte una conexión por servidor. Atajos de
  Siri/Spotlight en `Shortcuts/` (App Intents), Doctor en `Doctor/`, bloqueo con Face ID en
  `AppLock`. iOS mata el SSH en segundo plano: el terminal hace detach/reattach y los
  agentes son **persistentes** (`PersistentAgentScript`/`PersistentAgentSession`: claude
  corre en el servidor leyendo de una FIFO y escribiendo un log; la app se engancha al log;
  el Mac también puede seguirlos y crearlos). Avisos «terminó / espera tu permiso» con
  notificaciones locales (`AgentNotifier`, BGAppRefreshTask; sin push porque no hay servidor
  intermedio).
- **iCloud** (`ArgosCore/CloudSync/`): servidores y huellas TOFU sincronizados por iCloud
  clave-valor entre la variante App Store del Mac y el iPhone/iPad (nunca secretos). La
  variante GitHub no lo incluye (sin perfil no hay entitlement de iCloud).
- `Localization/` — catálogos de cadenas (`Localizable.xcstrings`, `InfoPlist.xcstrings`);
  `ArgosiOS/AppShortcuts.xcstrings` lleva las frases de Atajos.
- `scripts/` — CI y utilidades (cobertura, localización, `sshd` de pruebas, goldens,
  notas de release); `scripts/appstore/` sube a App Store Connect.
- No es un módulo Swift aparte (sin `public`): son fuentes compartidas por ambos
  targets. Los tests (`@testable import Argos`) siguen cubriendo el núcleo.

Capas (archivos pequeños y cohesivos, lógica pura separada de red/UI):

- **Modelo / lógica pura** (sin dependencias de red/UI, testeable): `TmuxSession`,
  `SessionGroup`, `VisibleProjectListing` (búsqueda, filtro y grupos), `SessionNameValidator`
  (valida ':' '.', control, prefijo '-'), `ShellQuoting` (entrecomillado POSIX
  anti-inyección), `Server`, `ReconnectPolicy`, `AttentionList`, `DoctorEvaluator`.
- **Servicio SSH**: `actor SSHService` (+ extensiones: autenticación, ejecución de comandos,
  PTY, CRUD de sesiones, vigilancia de la conexión). Abstraído tras `protocol SSHServicing`
  para inyección de dependencias / tests con mock. Reglas de conexión: `ChannelGate`
  limita los canales cortos (tope adaptativo, turnos de usuario y de fondo); los
  sondeos van como fondo (`ConnectionPriority`) y respetan `ConnectionHealth` (credenciales
  o host key rechazadas bloquean los reintentos hasta una acción del usuario); cada comando
  lleva plazo (`CommandTimeout`/`RemoteTimeout`); las conexiones dedicadas (terminal,
  agente, túnel) las vigila un monitor (`LinkLiveness`). Una acción del usuario que
  reintenta debe levantar el bloqueo (`resetConnectionHealth`).
- **Sondeo**: `WorkspacePoller` (una tarea por servidor) agrupa estado de Claude, sesiones y
  solicitudes de puertos en un solo `exec` (`WorkspacePollCommand`). No añadas sondeos
  sueltos: engánchalos ahí.
- **Persistencia / seguridad**: `ServerStore` (servers.json), `KeychainStore`
  (passphrases), `TOFUHostKeyValidator` (verificación de host key Trust-On-First-Use).
- **Datos compartidos en el servidor** (`~/.config/argos/projects.json`, `agents/`, y los
  hooks en `~/.claude/settings.json`): los escriben Mac, iPhone/iPad y Android con cerrojo y
  comprobación de huella (`RemotePrivateFile`, `PosixChecksum`); conserva claves
  desconocidas y no escribas un formato más nuevo del que entiendes.
- **UI**: Mac: `ContentView` (NavigationSplitView), `SessionsColumn`, `SessionTerminalView` +
  `LiveTerminalController`, `ServerFormSheet`…; iOS: `SplitRootView`, `ProjectScreen`… (ver
  arriba).
- **Observabilidad**: `os.Logger` vía `Log` (categorías ssh/terminal/hostkey/store). El texto
  que viene del servidor se registra como privado.

Convenciones:
- **Concurrencia**: tipos aislados a `@MainActor` por defecto; el `SSHClient`
  (no-Sendable) queda protegido por el `actor SSHService`; datos que cruzan
  fronteras son `Sendable`. Marca `nonisolated`/`Sendable` explícitamente cuando aplique.
- **Inmutabilidad**: `struct` con value semantics; estados como `enum`.
- **Errores**: enums tipados `LocalizedError` con mensajes accionables; `Error.userMessage`
  para presentarlos en UI. Nunca tragar errores sin loguear.
- **Tests**: Swift Testing (`import Testing`, `@Test`/`#expect`). La lógica pura debe
  ir cubierta. El target es host-less (no lanza la app).

### Localización (español e inglés)

El **español es el idioma de origen**; el **inglés** es la traducción y el idioma de
reserva (`CFBundleDevelopmentRegion: en`; la app sigue el idioma del sistema). Todo texto
visible pasa por el catálogo: literal de SwiftUI o `String(localized:)` en modelos y errores
(una sola frase con marcadores, nunca concatenaciones; plurales con las reglas del catálogo).
Para añadir una cadena: escríbela en español en el código, ejecuta
`scripts/localization.sh extract` (compila Argos, ArgosAppStore y ArgosiOS y vuelca las
claves nuevas), traduce las claves nuevas al inglés en `Localization/Localizable.xcstrings`
(estado `translated`) y ejecuta `scripts/localization.sh check` (falta de traducción,
marcadores de formato distintos, claves obsoletas; los tests `LocalizationCatalogTests` lo
repiten en la CI).

**No se traduce** lo que viaja al servidor o se persiste: scripts y comandos remotos,
marcadores (`ARGOS_*`), prompts a Claude, la skill de puertos, identificadores guardados
(«General», «Sesiones sueltas», que se muestran traducidos) ni los logs. Lo que se queda en
español a propósito va en `ArgosTests/LocalizationWhitelist.swift`; que siga corta.

### Scripts remotos y compatibilidad

- Los scripts y formatos que comparten **Swift y Kotlin** (agentes persistentes, `projects.json`,
  hooks de Claude, sondeo, Doctor, monitor, puntos de restauración…) se cambian **en los dos
  lados a la vez**, con sus goldens regenerados (ver arriba). Mac, iPhone/iPad y Android
  comparten servidor.
- Las carpetas y archivos del servidor (`~/.config/argos/`, incluidos los agentes y sus
  logs) los comparten **versiones publicadas** de las tres apps: los cambios deben ser
  aditivos (claves y marcadores nuevos que las versiones viejas ignoren) y los scripts
  deben funcionar bajo `/bin/sh` (dash), sin depender del locale (`tmux -u`) y con plazo.

## Seguridad y distribución

- **App Sandbox + Hardened Runtime ACTIVADOS** (notarización-ready). Entitlements
  (generados desde `project.yml`): `app-sandbox`, `network.client` (SSH saliente),
  `files.user-selected.read-only` y `bookmarks.app-scope`.
- La **clave privada SSH** se lee por **security-scoped bookmark** que el usuario
  concede al elegir el archivo en `ServerFormSheet`. Bajo sandbox NO se puede leer
  `~/.ssh` por ruta: hay que elegir la clave en el formulario.
- La **passphrase** se guarda en **Keychain** (`KeychainStore`), nunca en código ni
  en el modelo persistido.
- El **token de Claude** viaja por stdin, nunca en la línea de comandos (`ps`); igual el
  encargo de los atajos y las líneas largas de los agentes. Las subidas
  a `/tmp` usan `RemoteUpload`: nombre aleatorio, apertura exclusiva y 0600.
- Los agentes arrancan en **`bypassPermissions`** por defecto; se cambia en Ajustes o por
  proyecto (`AgentPermissionPreferences`, en el dispositivo). Con root o un valor guardado
  que no se reconoce, pasan a preguntar.
  Un agente persistente guarda su modo en `meta.json` y lo conserva al reanudar. Parar un
  agente nunca mata un PID sin comprobar antes su línea de comandos/id.
- **Atajos de Siri («Pedir a Claude»)**: confirman servidor, proyecto y modo si el agente
  actúa sin preguntar (salvo «Permitir atajos sin confirmar», desactivado por defecto), releen
  el modo justo antes de enviar, exigen el dispositivo desbloqueado y respetan el **bloqueo
  con Face ID** (`AppLockPolicy`, lógica pura): con él, enlaces y avisos esperan al
  desbloqueo y los nombres de proyecto no salen en Spotlight/Siri sin permiso.
- **Puntos de restauración** (opcionales, **desactivados por defecto**, por proyecto con
  `argos.checkpoints`): almacén aparte en `<gitdir>/argos-checkpoints.git`, nada en `refs/`.
  Restaurar hace una copia previa y **no pisa ni borra nada que no esté en ella**
  (verificación por hash justo antes de cada escritura); no toca archivos ignorados y
  se niega ante carpetas, repos anidados o enlaces en el camino. Cualquier cambio aquí
  exige conservar esas garantías y sus tests.
- **Diagnóstico** (`DiagnosticRedactor`, `DiagnosticSecretScrubber`): «Copiar diagnóstico»
  redacta SIEMPRE claves, tokens y contraseñas y, por defecto, también servidores, usuarios
  e IPs. El Doctor del servidor es de solo lectura y no escribe en el `HOME` del servidor.
- Verificación de **host key TOFU**: la primera conexión confía y guarda la huella
  SHA256; un cambio posterior aborta (posible MitM). Para re-confiar tras una
  reinstalación legítima: menú contextual del servidor → "Olvidar host key". Ni iCloud ni un
  QR pueden cambiar la huella de un servidor ya conocido.
- Sincronización y Archivos tratan al servidor como no confiable: rutas confinadas a la
  carpeta del proyecto, nombres saneados, sin hooks de git.

## Convención de commits

**Conventional Commits** (`feat:`, `fix:`, `refactor:`, `test:`, `build:`,
`chore:`, `perf:`, `docs:`). El changelog (`CHANGELOG.md`, sección `[Unreleased]` hasta
publicar) se escribe para el usuario de la app y las notas de release salen de él; el
detalle por commit vive en `git log`.
