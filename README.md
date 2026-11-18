# Argos

**Gestor de proyectos y sesiones [tmux](https://github.com/tmux/tmux) remotas vía SSH**, con
terminal en vivo y agente de Claude Code integrado. Nativo de **macOS** e **iPhone/iPad**
(SwiftUI) y de **Android** (Kotlin + Jetpack Compose).

[![CI](https://github.com/victalejo/Argos/actions/workflows/ci.yml/badge.svg)](https://github.com/victalejo/Argos/actions/workflows/ci.yml)
[![Android](https://github.com/victalejo/Argos/actions/workflows/android.yml/badge.svg)](https://github.com/victalejo/Argos/actions/workflows/android.yml)
[![Release](https://img.shields.io/github/v/release/victalejo/Argos?sort=semver)](https://github.com/victalejo/Argos/releases/latest)
[![Descargas](https://img.shields.io/github/downloads/victalejo/Argos/total)](https://github.com/victalejo/Argos/releases)
[![Licencia](https://img.shields.io/github/license/victalejo/Argos)](LICENSE)
![macOS 15.0+](https://img.shields.io/badge/macOS-15.0%2B-blue?logo=apple)
![iOS 18.0+](https://img.shields.io/badge/iOS-18.0%2B-blue?logo=apple)

Argos se conecta a **varios servidores** por SSH, convierte cada sesión tmux en un
**proyecto** anclado a una carpeta del servidor y te deja abrirlo, detenerlo para liberar
memoria y retomarlo después. Cada proyecto tiene **Terminal** (PTY + `tmux attach`),
**Archivos** (explorador SFTP con visor), **Cambios** (git y GitHub en el servidor) y
**Agente** (Claude Code en la carpeta del proyecto). Cerrar la app nunca mata nada: tmux
sigue corriendo en el servidor. La interfaz está en **español e inglés** (sigue el idioma
del sistema).

```
┌────────────────────┬─────────────────────────────────────────────────────────┐
│ Proyectos   🔍  [+]│  tienda-online   Terminal · Archivos · Cambios · Agente │
│ ────────────────── │ ─────────────────────────────────────────────────────── │
│ ● dev              │  >_ 1   >_ 2   ✳ Claude Code   [+]                      │
│   ▾ web            │ ─────────────────────────────────────────────────────── │
│     tienda-online ●│  $ npm run dev                                          │
│     blog         ◐ │  ready on http://localhost:3000                         │
│   ▾ api            │  ...                                                    │
│     api-pagos    ○ │  (terminal en vivo: PTY sobre SSH + SwiftTerm)          │
│ ○ producción       │ ─────────────────────────────────────────────────────── │
│                    │  dev · main · 1 agente activo                           │
└────────────────────┴─────────────────────────────────────────────────────────┘
```

---

## Plataformas

| Plataforma | Estado | Distribución |
|---|---|---|
| **macOS** (canal GitHub) | Estable | DMG en [Releases](https://github.com/victalejo/Argos/releases/latest) + actualizaciones automáticas (Sparkle) |
| **macOS** (Mac App Store) | Publicada | Variante `ArgosAppStore`: mismas funciones, sin Sparkle, con iCloud |
| **iPhone / iPad** | Publicada | App Store; app universal (mismo bundle id que el Mac) |
| **Android** | En revisión | Google Play; Kotlin + Jetpack Compose en [`android/`](android/README.md) |

## Descarga e instalación (macOS)

Descarga el `.dmg` más reciente desde **[Releases](https://github.com/victalejo/Argos/releases/latest)**,
ábrelo y arrastra **Argos** a *Applications*.

Las builds de GitHub son **ad-hoc (sin notarizar)**, así que la primera vez Gatekeeper la
bloquea. Para abrirla:

```sh
xattr -dr com.apple.quarantine /Applications/Argos.app
```

o clic derecho sobre la app → **Abrir** (solo la primera vez).

> **Actualizaciones automáticas:** Argos se actualiza solo vía [Sparkle](https://sparkle-project.org/)
> ("Instalar y reiniciar", sin aviso de Gatekeeper). También en **Argos → Buscar actualizaciones…**.

> ¿Prefieres compilarla tú? Ve a [Compilar y ejecutar](#compilar-y-ejecutar).

## Características

### Servidores y conexión
- **Multi-servidor**: añade, edita y borra servidores desde la UI (`servers.json`); sin
  servidor hardcodeado. Importa hosts desde **`~/.ssh/config`**.
- **Clave o contraseña**: clave privada Ed25519 OpenSSH (con passphrase opcional) o usuario +
  contraseña. Los secretos van al **Keychain**, nunca a disco plano.
- **Host key TOFU** (*Trust-On-First-Use*): la huella SHA256 se fija en la primera conexión;
  si cambia, se aborta (protección MitM). Reset: clic derecho → **"Olvidar host key"**.
- **Bootstrap de tmux**: lo detecta, lo instala con `apt` si hay `sudo` sin contraseña y crea
  un `~/.tmux.conf` base (con OSC 52). Idempotente y no interactivo.
- **Conexión prudente**: reconexión automática con backoff; una conexión SSH dedicada por
  terminal, agente y túnel, que se vigila y se rehace si el servidor deja de responder.
  Los comandos cortos comparten canales con un **tope adaptativo** (baja ante el primer
  rechazo de `MaxSessions`), cada comando tiene **plazo**, y un servidor caído, una
  credencial rechazada o una host key cambiada **no se insisten** hasta que lo pidas
  (Conectar, Reintentar, ⌘R). Los errores se explican en vez de mostrar códigos.
- **Doctor del servidor** (menú del servidor, Mac, iPhone/iPad y Android): comprobación de
  solo lectura de tmux, git, `gh`, Claude Code, hooks y skill, con el arreglo o el comando
  para copiar, y **«Copiar diagnóstico»** con secretos y datos personales redactados.
- **Claves**: al elegir o pegar una clave se revisa al instante (Ed25519, con o sin
  passphrase) y se explica por qué no sirve otra; en iPhone/iPad se puede **crear una en el
  dispositivo** e instalarla en el servidor.

### Proyectos
- Cada sesión es un **proyecto anclado a una carpeta** del servidor, guardado en
  `~/.config/argos/projects.json` (compartido entre todos tus Macs y dispositivos; las
  escrituras llevan cerrojo y comprobación de cambios, conservan lo que una versión no
  conoce y, si se daña, hay «Restaurar copia anterior»).
- **Abrir** crea la sesión tmux en la carpeta y lanza el comando de arranque (por defecto
  `cc --continue`, configurable global y por proyecto). **Desconectar** (sigue corriendo),
  **Detener** (cierra la sesión y libera RAM; el proyecto se conserva), **Editar**, **Quitar**.
- **Grupos** colapsables, **búsqueda** y **filtro por estado**: Abiertas, Dormidas, Detenidas,
  En el Mac y Segundo plano. Importa sesiones sueltas como proyectos.
- **Cambiador rápido ⌘K** entre proyectos de cualquier servidor y **envío de un comando a
  varias sesiones a la vez** (broadcast con `tmux send-keys`).
- **Mac: una sola ventana y bandeja «Te necesita»**: cerrar la ventana no cierra la app;
  un icono en la barra de menús, un botón y la insignia del Dock reúnen lo que espera por
  ti en todos los servidores (Claude esperando, permisos, CI fallida, puertos, envíos) y
  **⌘J** salta al siguiente.

### Terminal
- **PTY interactivo** sobre SSH con `tmux attach`, renderizado con
  [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm): *resize*, scroll del ratón,
  ⌘C/⌘V, **portapapeles OSC 52** y buffer acotado.
- **Pestañas por ventana tmux**: `>_ 1`, `>_ 2`… y, si corre un agente, su icono (Claude Code,
  Codex o Grok). Menú **«+»** para abrir un terminal o lanzar un agente en la carpeta del
  proyecto. Renombrar, color por ventana (persistido en tmux) y cerrar con confirmación.
- **Atajos**: ⌘T nueva ventana, ⌘W cerrar, ⌘1…⌘9 ir a pestaña, ⌘⇧[ / ⌘⇧] anterior/siguiente,
  ⌘⌥1…3 lanzar un agente (menú **Pestañas** en el Mac; también en iPad con teclado).
- **Subir archivos e imágenes**: pega una imagen (⌘V) o arrastra archivos al terminal; se
  suben por SFTP a `/tmp` y la ruta se inserta en la línea de comandos.
- **Detach, no kill**: cerrar el terminal o cambiar de proyecto hace *detach*.
- En **iPhone/iPad y Android**, las mismas pestañas de ventanas con el menú **«+»**, una fila
  de teclas (esc, ctrl, tab, Mayús+Tab, flechas…) y reconexión automática al volver a la app
  o a la red. En iPhone/iPad, además, «Opción como Meta» para teclado físico (ajuste), girar
  la pantalla sin perder el sitio y atajos de Siri («Pedir a Claude», «Abrir proyecto») y
  Spotlight. En Android, **adjuntar** archivos y fotos y **compartir** a Argos desde otras
  apps.

### Archivos
- Árbol de la carpeta del proyecto con **iconos por tipo de carpeta** (src, docs, tests,
  .github…), visor de **Markdown renderizado**, **código resaltado**, imágenes, **PDF**,
  **HTML** aislado (sin JavaScript ni red salvo que lo permitas para esa página) y **hojas
  de cálculo** (Excel y Numbers, con Vista Rápida; en Android, «Abrir con…»).
- **⌘P** para buscar por nombre y **descargar al Mac** cualquier archivo. Solo lectura, sin
  salir nunca de la carpeta del proyecto.

### Cambios (git y GitHub)
- Pestaña **Cambios**: estado del repositorio, diff por archivo, elegir qué entra en el commit
  y **mensaje sugerido por Claude**. git corre en el servidor; la app solo lo muestra.
- **GitHub con el `gh` del servidor**: PR de la rama con su revisión y sus checks, crear el PR,
  relanzar la CI y **clonar un repositorio como proyecto nuevo**. Aviso cuando la CI termina.
- **Ramas en paralelo** (`git worktree`): cada rama en su carpeta, como un proyecto propio.
- **Puntos de restauración por turno** (Mac e iPhone/iPad, **opcionales y desactivados por
  defecto**, se activan por proyecto): guardan cómo estaba la carpeta cuando le escribes a
  Claude, para ver el diff de cada turno y **deshacer hasta ahí** o restaurar un archivo.
  Viven aparte del historial de git y restaurar nunca pisa lo que no esté en la copia
  previa. El diff de Cambios se mantiene al día y pide confirmación si lo que vas a
  commitear cambió desde que lo viste; soporta commits de miles de archivos.

### Puertos
- **Reenvío de puertos** del servidor a tu dispositivo: abre en `localhost` la web que corre
  en el servidor (`npm run dev`, etc.). Detecta lo que está escuchando y cierra los túneles
  sin uso tras el tiempo que elijas. Si la conexión se cae, el túnel se reabre solo.
- **Claude puede pedirlo**: con la skill «argos-puertos», Claude ve los túneles abiertos y
  te propone abrir uno; nada se abre sin que aceptes.

### Agente de Claude Code
- Panel **Agente** que trabaja en la carpeta del proyecto, con **varias conversaciones en
  pestañas**, respuestas en Markdown, herramientas plegables y tarjeta de permisos.
- **Login guiado** en Mac, iPhone/iPad y Android (en el Mac, si `claude` no está instalado
  en el servidor, Argos lo instala).
- **Indicador de Claude Code** por sesión y por pestaña (esperando tu respuesta / terminó /
  trabajando) con notificación del sistema, en el Mac y en iPhone/iPad. Tocar el aviso abre
  el proyecto y la ventana que lo originó.
- Los agentes **persistentes** (iPhone/iPad y Android; en el Mac, con «Mantener en el
  servidor» y «Continuar en el servidor») siguen corriendo en el servidor aunque el sistema
  corte el SSH, y la app avisa con notificaciones locales cuando terminan o esperan tu
  permiso (sin push: no hay servidores intermedios). Un agente quieto se **hiberna solo** y
  se reanuda al escribirle; una **guardia de memoria** avisa antes de lanzar otro cuando el
  servidor va justo; **«Agentes en este servidor»** lista todos con su memoria y permite
  detenerlos o hibernar los inactivos.
- **«Detener»** (Mac, y «Detener el turno» en Android) interrumpe lo que Claude hace sin
  cerrar la conversación; las conversaciones terminadas se pueden reanudar.

### Enviar al Mac
- **Enviar al Mac** copia la carpeta del proyecto a este Mac (con `.git` y `.env`, sin
  `node_modules` ni builds) para trabajar en local; **Enviar al servidor** devuelve los
  cambios detectando conflictos y sin dejar el destino a medias si algo falla. En segundo
  plano, con progreso en la fila del proyecto.
- **Abrir en Terminal con Claude Code** retoma la conversación: viaja con el proyecto al Mac
  y de vuelta al servidor.
- La sincronización trata al servidor como no confiable (rutas y symlinks validados, sin
  hooks de git, `.git/config` reconstruido con lista blanca).

### Monitor y más
- **Monitor de recursos** del servidor (⌥⌘I): CPU, memoria, swap, disco, carga y procesos.
- **Enviar al iPhone por QR**: el Mac crea una clave Ed25519 solo para ese dispositivo, la
  autoriza en el servidor y muestra un QR de un solo uso. Desde el menú del servidor puedes
  ver y **revocar los dispositivos autorizados**.
- **iCloud** (Mac App Store + iPhone/iPad): sincroniza servidores y huellas confiadas, nunca
  secretos.
- **Apariencia**: tema y tamaño de fuente del terminal con vista previa (⌘,).
- **iPhone/iPad**: **bloqueo con Face ID** opcional, hoja de **Avisos** con el estado real del
  sistema, búsqueda y filtros de proyectos y monitor de recursos desde el menú del servidor.

## Requisitos

- **macOS 15.0+** (el terminal usa `Citadel.withPTY` / `TTYOutput`, `@available(macOS 15.0, *)`)
  o **iOS/iPadOS 18.0+**. Android: ver [`android/README.md`](android/README.md).
- Para compilar: **Xcode 16.4 o posterior** y **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**
  (`brew install xcodegen`; usa la misma versión que la CI para evitar *drift*). La CI y el
  release compilan con Xcode 16.4 (Swift 6.1): evita sintaxis y API de Swift 6.2+.
- Un **servidor accesible por SSH** (el bootstrap de tmux y el monitor asumen Linux; la
  instalación automática, Ubuntu/Debian con `apt`).

## Dependencias (Swift Package Manager)

| Paquete | Uso | Versión |
|---|---|---|
| [Citadel](https://github.com/orlandos-nl/Citadel) | Cliente SSH (conexión, comandos, PTY, SFTP) | `minorVersion: 0.12.0` |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Emulador de terminal (AppKit y UIKit) | `minorVersion: 1.18.0` |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Actualizaciones automáticas (solo canal GitHub) | `majorVersion: 2.10.1` |
| [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) | Markdown en el visor y en el agente | `minorVersion: 2.4.1` |

## Configurar un servidor

1. Pulsa **+** en la barra lateral ("Añadir servidor") o importa un host de `~/.ssh/config`.
2. Rellena nombre, host, puerto y usuario.
3. Elige la **autenticación**:
   - **Clave SSH**: en el canal GitHub las claves de `~/.ssh` se leen directamente; en la
     variante App Store concedes la carpeta `~/.ssh` una vez. Para otra ruta, "Elegir…"
     guarda un *security-scoped bookmark*. Si tiene passphrase, escríbela.
   - **Contraseña**: la de login.
4. En iPhone/iPad y Android: contraseña, clave importada o **escanea el QR** que genera el Mac.

## Compilar y ejecutar

`project.yml` es la **fuente de verdad** (XcodeGen). `Argos.xcodeproj` se versiona como
artefacto generado; **si cambias `project.yml`, regenera**.

```bash
xcodegen generate                                                       # tras editar project.yml
xcodebuild -project Argos.xcodeproj -scheme Argos -configuration Debug build
xcodebuild -project Argos.xcodeproj -scheme Argos test                  # Swift Testing
open ~/Library/Developer/Xcode/DerivedData/Argos-*/Build/Products/Debug/Argos.app

# Mac App Store (flag APPSTORE: sin Sparkle, mismas funciones)
xcodebuild -project Argos.xcodeproj -scheme ArgosAppStore -configuration Debug build

# iPhone/iPad (simulador)
xcodebuild -project Argos.xcodeproj -scheme ArgosiOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build
```

Android: ver [`android/README.md`](android/README.md) (`./gradlew :core:test :app:assembleDebug`).

### Tests de integración (sshd temporal)

Algunos fallos solo aparecen contra un servidor SSH de verdad (agotar canales, reconexión,
SFTP en paralelo, túneles) y contra los scripts remotos de Argos (`projects.json`, envío,
git, agentes, tmux, puntos de restauración, Doctor). Esos tests (`ArgosTests/Integration*`)
se saltan solos; para activarlos, `scripts/sshd-test-start.sh` levanta un `sshd` sin root
en `127.0.0.1` con claves y `HOME` propios y un `claude` simulado, e imprime las variables
`ARGOS_E2E_SSH_*` (con `xcodebuild` llevan el prefijo `TEST_RUNNER_`). Hace falta `tmux`.

```bash
eval "$(scripts/sshd-test-start.sh --max-sessions 4 | sed 's/^/export TEST_RUNNER_/')"
xcodebuild test -project Argos.xcodeproj -scheme Argos -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ArgosTests/IntegrationSSHDTests \
  -only-testing:ArgosTests/IntegrationServerSuites
scripts/sshd-test-stop.sh "$TEST_RUNNER_ARGOS_E2E_SSHD_DIR"   # para el sshd y lo que dejaron las sesiones
```

### Utilidades de `scripts/`

| Script | Para qué |
|---|---|
| `sshd-test-start.sh` / `sshd-test-stop.sh` | `sshd` temporal para los tests de integración (`--max-sessions`, `--port`, `--dir`, `--force-sh`; `--keep` al parar) |
| `argos-fake-claude` | `claude` simulado que instala el `sshd` temporal; no es el real |
| `regenerate-swift-goldens.sh` | Regenera con el Swift real los goldens de paridad de Android (`--check` falla si están desfasados; lo usa la CI) |
| `coverage_core.py` | Cobertura de líneas solo de `ArgosCore/` y puerta de mínimo en la CI |
| `localization.sh` / `localization_check.py` | `extract` vuelca las cadenas nuevas a los catálogos y `check` verifica que el inglés esté completo |
| `release_notes_html.py` | Notas del `CHANGELOG.md` en HTML para el feed de Sparkle |
| `appstore/` | Subida a App Store Connect ([README](scripts/appstore/README.md)) |

Los textos de la interfaz están en español (idioma de origen) e inglés
(`Localization/*.xcstrings`); al añadir uno nuevo, ejecuta `scripts/localization.sh extract`,
traduce la clave y `scripts/localization.sh check`. Detalle en [CLAUDE.md](CLAUDE.md).

**CI** (GitHub Actions): `ci.yml` (tres trabajos en paralelo) compila el Mac, corre los tests con cobertura
(con puerta de mínimo sobre `ArgosCore/`), los de integración contra un `sshd` temporal y
los goldens de Android, compila la variante App Store, compila `ArgosiOS` (guardián de
portabilidad de `ArgosCore/`) con sus tests de interfaz y verifica que `xcodegen generate`
no produzca *drift*; `android.yml` corre cuando cambia `android/**`; `release.yml` (tag `v*`)
publica el DMG y el feed de Sparkle, y `android-release.yml` (tag `android-v*`) firma el AAB
y lo deja en borrador en Google Play. Ambos pasan antes la suite completa de tests; el
Release de GitHub nace en borrador y solo se publica con sus tres archivos subidos enteros.
Las acciones van fijadas por SHA y Dependabot las mantiene al día. La subida a las tiendas de
Apple está en [`scripts/appstore/`](scripts/appstore/README.md).

## Estructura del repositorio

| Carpeta | Contenido |
|---|---|
| `ArgosCore/` | Núcleo compartido Mac + iPhone/iPad: modelo, `SSHService` y reglas de conexión, sondeador, stores, proyectos, agentes, bandeja de atención, Doctor, puntos de restauración, iCloud, view models. Sin AppKit/SwiftUI-mac. |
| `ArgosUI/` | Vistas SwiftUI compartidas (mascota de Claude, iconos de agentes, diff, estado de GitHub). |
| `Argos/` | App de macOS (dos variantes: `Argos` GitHub+Sparkle y `ArgosAppStore`); `Workspace/` tiene el modelo único de app y la salida ordenada. |
| `ArgosiOS/` | App de iPhone/iPad (tres columnas en iPad, agentes persistentes, avisos, atajos de Siri, Face ID). |
| `Localization/` | Catálogos de cadenas (español de origen e inglés). |
| `ArgosTests/`, `ArgosiOSUITests/` | Tests (Swift Testing, host-less; incluye integración y goldens de Android) y pruebas de interfaz de iOS. |
| `android/` | App de Android (Gradle; `core` Kotlin/JVM puro porta `ArgosCore`, `ssh` con sshj, `app` en Compose). |
| `scripts/` | Utilidades de CI y pruebas (ver «Utilidades de `scripts/`») y subida a App Store Connect. |

## Arquitectura

La red vive en un `actor`, la UI en `@MainActor` y la lógica pura (validadores,
agrupamiento, entrecomillado, protocolo del agente…) no depende de red ni UI y está
cubierta por tests.

```
UI (@MainActor) ── ContentView (Mac) / SplitRootView (iPad) / NavigationStack (iPhone)
   │  ServerStore (servers.json)    SSHProjects (~/.config/argos/projects.json)
   │  SessionsViewModel ── cargar / abrir / detener / crear / renombrar / matar
   │
   ├─ Terminal ──> LiveTerminalController / TouchTerminalController
   ├─ Archivos ──> SSHFileBrowser (SFTP, confinado a la carpeta del proyecto)
   ├─ Agente ────> ClaudeAgentSession / PersistentAgentSession (claude stream-json)
   │
   └──────────────> any SSHServicing  ◀── SSHService (actor)
                        ├─ listSessions / ensureTmux* / create·rename·kill (canal de comandos)
                        └─ attachTerminal(...)  PTY + `exec tmux attach`

   KeychainStore · TOFUHostKeyValidator · ShellQuoting · SessionNameValidator · CloudServerSync
```

- **`SSHService`** protege el `SSHClient` (no `Sendable`) y se abstrae tras
  **`protocol SSHServicing`** para inyección de dependencias y tests con mock.
- **Gestión de sesiones** por el canal de comandos, separada del PTY.
- **Reglas de conexión**: un tope adaptativo de canales cortos (`ChannelGate`), plazo por
  comando, sondeos de fondo que esperan tras un fallo y bloqueo de reintentos ante
  credenciales o host key rechazadas, hasta una acción del usuario.
- **Sondeo único por servidor** (`WorkspacePoller`): sesiones, estado de Claude y solicitudes
  de puertos en un solo comando. En el Mac, `ArgosAppModel` es el dueño único del estado y
  la ventana solo lo observa.
- **Ciclo de vida del terminal** con `.task(id:)`: al cambiar de proyecto se cancela la tarea
  y tmux hace *detach*. En iOS, detach al ir a segundo plano y reattach al volver.

Detalle de arquitectura y convenciones en [CLAUDE.md](CLAUDE.md).

## Notas de seguridad

- **App Sandbox + Hardened Runtime** activados; entitlements generados desde `project.yml`.
  La variante App Store no usa ninguna excepción temporal.
- **Secretos** (passphrase / contraseña / claves importadas) en **Keychain** (en Android,
  cifrados con el Android Keystore), nunca en código, en el modelo persistido ni en iCloud.
  En iPhone/iPad la contraseña y la passphrase SSH se pueden leer con el dispositivo bloqueado
  tras el primer desbloqueo, para que los avisos en segundo plano funcionen; no salen del
  dispositivo.
- **Host key TOFU** en `~/Library/Application Support/Argos/known_hosts.json`. Ni iCloud ni un
  QR pueden cambiar la huella de un servidor ya conocido, y un archivo de huellas dañado
  bloquea la conexión en vez de volver a confiar a ciegas.
- **Anti-inyección**: nombres de sesión validados y entrecomillados (POSIX, `ShellQuoting`);
  objetivos tmux exactos (`=nombre`).
- **`sudo` no interactivo** (`sudo -n`): la app nunca pide ni guarda la contraseña de `sudo`.
- **Archivos y sincronización** confinados a la carpeta del proyecto; el Markdown no carga
  imágenes remotas, el HTML se muestra aislado y los enlaces piden confirmación.
- **Agentes y atajos**: los agentes arrancan en modo `bypassPermissions` salvo que lo cambies
  (con root pasan a preguntar); «Pedir a Claude» confirma si el agente actuaría sin preguntar
  y respeta el **bloqueo con Face ID**. El encargo y el token de Claude viajan por stdin,
  nunca en la línea de comandos.
- **Puntos de restauración**: opcionales; restaurar nunca pisa ni borra lo que no esté en la
  copia previa.
- **Diagnóstico**: «Copiar diagnóstico» siempre redacta claves, tokens y contraseñas, y por
  defecto también servidores, usuarios e IPs.

## Convención de commits

[Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `refactor:`,
`test:`, `build:`, `chore:`, `perf:`, `docs:`). El changelog vive en
[CHANGELOG.md](CHANGELOG.md) y el detalle en `git log`.
