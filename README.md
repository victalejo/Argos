# Argos

**Gestor de proyectos y sesiones [tmux](https://github.com/tmux/tmux) remotas vía SSH**, con
terminal en vivo y agente de Claude Code integrado. Nativo de **macOS** e **iPhone/iPad**
(SwiftUI), con una app de **Android** en camino.

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
**Archivos** (explorador SFTP con visor) y **Agente** (Claude Code en la carpeta del
proyecto). Cerrar la app nunca mata nada: tmux sigue corriendo en el servidor.

```
┌────────────────────┬─────────────────────────────────────────────────────────┐
│ Proyectos   🔍  [+]│  tienda-online   Terminal · Archivos · Agente           │
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
| **macOS** (Mac App Store) | En revisión | Variante `ArgosAppStore`: mismas funciones, sin Sparkle, con iCloud |
| **iPhone / iPad** | En revisión | App universal (mismo bundle id que el Mac) |
| **Android** | En desarrollo (fase 0) | Kotlin + Jetpack Compose en [`android/`](android/README.md) |

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
- **Reconexión automática** con backoff exponencial; una conexión SSH dedicada por terminal y
  por agente (no agota `MaxSessions`).

### Proyectos
- Cada sesión es un **proyecto anclado a una carpeta** del servidor, guardado en
  `~/.config/argos/projects.json` (compartido entre todos tus Macs y dispositivos).
- **Abrir** crea la sesión tmux en la carpeta y lanza el comando de arranque (por defecto
  `cc --continue`, configurable global y por proyecto). **Desconectar** (sigue corriendo),
  **Detener** (cierra la sesión y libera RAM; el proyecto se conserva), **Editar**, **Quitar**.
- **Grupos** colapsables, **búsqueda** y **filtro por estado**: Abiertas, Dormidas, Detenidas,
  En el Mac y Segundo plano. Importa sesiones sueltas como proyectos.
- **Cambiador rápido ⌘K** entre proyectos de cualquier servidor y **envío de un comando a
  varias sesiones a la vez** (broadcast con `tmux send-keys`).

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

### Archivos
- Árbol de la carpeta del proyecto con **iconos por tipo de carpeta** (src, docs, tests,
  .github…), visor de **Markdown renderizado**, **código resaltado**, imágenes y **PDF**.
- **⌘P** para buscar por nombre y **descargar al Mac** cualquier archivo. Solo lectura, sin
  salir nunca de la carpeta del proyecto.

### Agente de Claude Code
- Panel **Agente** que trabaja en la carpeta del proyecto, con **varias conversaciones en
  pestañas**, respuestas en Markdown, herramientas plegables y tarjeta de permisos.
- **Login guiado** (y si `claude` no está instalado en el servidor, Argos lo instala).
- **Indicador de Claude Code** por sesión y por pestaña (esperando tu respuesta / terminó /
  trabajando) con notificación del sistema.
- En iPhone/iPad los agentes son **persistentes**: `claude` sigue corriendo en el servidor
  aunque iOS corte el SSH, y la app avisa con notificaciones locales cuando termina o espera
  tu permiso.

### Enviar al Mac
- **Enviar al Mac** copia la carpeta del proyecto a este Mac (con `.git` y `.env`, sin
  `node_modules` ni builds) para trabajar en local; **Enviar al servidor** devuelve los
  cambios detectando conflictos. En segundo plano, con progreso en la fila del proyecto.
- **Abrir en Terminal con Claude Code** retoma la última conversación de esa carpeta.
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

## Requisitos

- **macOS 15.0+** (el terminal usa `Citadel.withPTY` / `TTYOutput`, `@available(macOS 15.0, *)`)
  o **iOS/iPadOS 18.0+**.
- Para compilar: **Xcode 16+** y **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**
  (`brew install xcodegen`; la CI usa la 2.46.0 — usa la misma para evitar *drift*).
- Un **servidor accesible por SSH** (el bootstrap de tmux y el monitor asumen Linux; la
  instalación automática, Ubuntu/Debian con `apt`).

## Dependencias (Swift Package Manager)

| Paquete | Uso | Versión |
|---|---|---|
| [Citadel](https://github.com/orlandos-nl/Citadel) | Cliente SSH (conexión, comandos, PTY, SFTP) | `minorVersion: 0.12.0` |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Emulador de terminal (AppKit y UIKit) | `minorVersion: 1.13.0` |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Actualizaciones automáticas (solo canal GitHub) | `majorVersion: 2.9.3` |
| [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) | Markdown en el visor y en el agente | `minorVersion: 2.4.1` |

## Configurar un servidor

1. Pulsa **+** en la barra lateral ("Añadir servidor") o importa un host de `~/.ssh/config`.
2. Rellena nombre, host, puerto y usuario.
3. Elige la **autenticación**:
   - **Clave SSH**: en el canal GitHub las claves de `~/.ssh` se leen directamente; en la
     variante App Store concedes la carpeta `~/.ssh` una vez. Para otra ruta, "Elegir…"
     guarda un *security-scoped bookmark*. Si tiene passphrase, escríbela.
   - **Contraseña**: la de login.
4. En iPhone/iPad: contraseña, clave importada o **escanea el QR** que genera el Mac.

## Compilar y ejecutar

`project.yml` es la **fuente de verdad** (XcodeGen). `Argos.xcodeproj` se versiona como
artefacto generado; **si cambias `project.yml`, regenera**.

```bash
xcodegen generate                                                       # tras editar project.yml
xcodebuild -project Argos.xcodeproj -scheme Argos -configuration Debug build
xcodebuild -project Argos.xcodeproj -scheme Argos test                  # Swift Testing
open ~/Library/Developer/Xcode/DerivedData/Argos-*/Build/Products/Debug/Argos.app

# iPhone/iPad (simulador)
xcodebuild -project Argos.xcodeproj -scheme ArgosiOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build
```

Android: ver [`android/README.md`](android/README.md) (`./gradlew :core:test :app:assembleDebug`).

**CI** (GitHub Actions): `ci.yml` compila el Mac, corre los tests con cobertura, compila
`ArgosiOS` (guardián de portabilidad de `ArgosCore/`) y verifica que `xcodegen generate` no
produzca *drift*; `android.yml` corre cuando cambia `android/**`; `release.yml` publica el
DMG y el feed de Sparkle. La subida a las tiendas está en
[`scripts/appstore/`](scripts/appstore/README.md).

## Estructura del repositorio

| Carpeta | Contenido |
|---|---|
| `ArgosCore/` | Núcleo compartido Mac + iPhone/iPad: modelo, `SSHService`, stores, proyectos, protocolo del agente, iCloud, view models. Sin AppKit/SwiftUI-mac. |
| `ArgosUI/` | Vistas SwiftUI compartidas (mascota de Claude, iconos de agentes). |
| `Argos/` | App de macOS (dos variantes: `Argos` GitHub+Sparkle y `ArgosAppStore`). |
| `ArgosiOS/` | App de iPhone/iPad (tres columnas en iPad, agentes persistentes, avisos). |
| `ArgosTests/`, `ArgosiOSUITests/` | Tests (Swift Testing, host-less) y E2E de iOS. |
| `android/` | App de Android (Gradle; `core` Kotlin/JVM puro porta `ArgosCore`). |
| `scripts/` | Notas de release y scripts de App Store Connect. |

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
- **Ciclo de vida del terminal** con `.task(id:)`: al cambiar de proyecto se cancela la tarea
  y tmux hace *detach*. En iOS, detach al ir a segundo plano y reattach al volver.

Detalle de arquitectura y convenciones en [CLAUDE.md](CLAUDE.md).

## Notas de seguridad

- **App Sandbox + Hardened Runtime** activados; entitlements generados desde `project.yml`.
  La variante App Store no usa ninguna excepción temporal.
- **Secretos** (passphrase / contraseña / claves importadas) en **Keychain**, nunca en código,
  en el modelo persistido ni en iCloud.
- **Host key TOFU** en `~/Library/Application Support/Argos/known_hosts.json`. Ni iCloud ni un
  QR pueden cambiar la huella de un servidor ya conocido.
- **Anti-inyección**: nombres de sesión validados y entrecomillados (POSIX, `ShellQuoting`);
  objetivos tmux exactos (`=nombre`).
- **`sudo` no interactivo** (`sudo -n`): la app nunca pide ni guarda la contraseña de `sudo`.
- **Archivos y sincronización** confinados a la carpeta del proyecto; el Markdown no carga
  imágenes remotas y los enlaces piden confirmación.

## Convención de commits

[Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `refactor:`,
`test:`, `build:`, `chore:`, `perf:`, `docs:`). El changelog vive en
[CHANGELOG.md](CHANGELOG.md) y el detalle en `git log`.
