# Argos

**Gestor visual de sesiones [tmux](https://github.com/tmux/tmux) remotas vía SSH**, nativo de macOS y construido con SwiftUI.

Argos se conecta por SSH a un servidor, garantiza que tmux esté instalado y configurado, lista sus sesiones en un sidebar y abre un terminal en vivo (`tmux attach`) sobre un PTY remoto. Permite crear, renombrar y matar sesiones sin salir de la app.

```
┌──────────────────────┬─────────────────────────────────┐
│  Sesiones tmux    [+]│  main · tmux attach             │
│ ─────────────────────│ ─────────────────────────────── │
│  ▸ magic-agents      │  $ tail -f /var/log/app.log     │
│      backend  ● Activa│  ...                            │
│      frontend ○      │  (terminal en vivo, PTY sobre   │
│  ▸ General           │   SSH + SwiftTerm)              │
│      main     ● Activa│                                 │
│      logs     ○      │                                 │
└──────────────────────┴─────────────────────────────────┘
```

---

## Características

- **Conexión SSH con clave Ed25519** — autenticación por clave privada OpenSSH (`~/.ssh/id_ed25519`), con passphrase opcional. Vía [Citadel](https://github.com/orlandos-nl/Citadel).
- **Verificación de host key TOFU** (*Trust-On-First-Use*) — la huella SHA256 del servidor se guarda en la primera conexión y se valida en las siguientes. Si cambia, la conexión se aborta (protección contra MitM). No usa `.acceptAnything()`.
- **Bootstrap automático de tmux** — al conectar, detecta tmux; si falta y hay `sudo` sin contraseña, lo instala con `apt`; crea un `~/.tmux.conf` base si no existe. Todo idempotente y no interactivo (nunca pide ni guarda la contraseña de `sudo`).
- **Lista de sesiones agrupada** — las sesiones se agrupan por convención de nombres: el prefijo antes del primer `/` define el grupo (`magic-agents/backend` → grupo *magic-agents*). Las que no tienen `/` caen en *General*.
- **Terminal en vivo** — PTY interactivo sobre SSH ejecutando `tmux attach`, renderizado con [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). Soporta teclado, *resize* (window-change) y copia al portapapeles (OSC 52).
- **Gestión de sesiones** — crear (`new-session -d`), renombrar (`rename-session`) y matar (`kill-session`), con validación de nombres y manejo de errores en la propia UI.
- **Detach, no kill** — cerrar el terminal o cambiar de sesión hace *detach*: la sesión tmux sobrevive en el servidor.

## Requisitos

- **macOS 15.0+** (el terminal en vivo usa `Citadel.withPTY` / `TTYOutput`, marcados `@available(macOS 15.0, *)`).
- **Xcode 16+** (Swift 5.0, `MainActor` por defecto, *approachable concurrency*).
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** para regenerar el proyecto desde `project.yml` (`brew install xcodegen`).
- Un **servidor accesible por SSH** (pensado para Ubuntu/Debian: el bootstrap de tmux usa `apt`).
- Una **clave Ed25519** en formato OpenSSH para autenticarte.

> **App Sandbox está DESACTIVADO** a propósito (`ENABLE_APP_SANDBOX = NO`): la app necesita leer `~/.ssh` y abrir conexiones de red salientes.

## Dependencias (Swift Package Manager)

| Paquete | Uso | Versión |
|---|---|---|
| [Citadel](https://github.com/orlandos-nl/Citadel) | Cliente SSH (conexión, ejecución de comandos, PTY) | `from: 0.12.0` |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Emulador de terminal (NSView de AppKit) | `from: 1.13.0` |

## Configurar la conexión

Los parámetros de conexión están en [Argos/SSHService.swift](Argos/SSHService.swift), en `Configuration.dev`:

```swift
static let dev = Configuration(
    host: "100.86.237.26",
    port: 2222,
    username: "victalejo",
    privateKeyPath: "~/.ssh/id_ed25519",
    passphrase: nil  // <- inyecta aquí la passphrase si la clave la requiere
)
```

Edita estos valores para apuntar a tu propio servidor. Si tu clave tiene passphrase, asígnala en `passphrase`.

## Compilar y ejecutar

El proyecto se describe en `project.yml` y se genera con XcodeGen. `Argos.xcodeproj` está versionado, así que puedes compilar directamente, pero **si cambias `project.yml` debes regenerarlo**.

```bash
# (Re)generar el proyecto desde project.yml — solo necesario tras editar project.yml
xcodegen generate

# Compilar (Debug)
xcodebuild -project Argos.xcodeproj -scheme Argos -configuration Debug build

# Ejecutar la app compilada
open ~/Library/Developer/Xcode/DerivedData/Argos-*/Build/Products/Debug/Argos.app
```

O simplemente abre `Argos.xcodeproj` en Xcode y pulsa ⌘R.

## Arquitectura

Capas de concurrencia bien separadas: la red en un `actor`, la UI en `@MainActor`.

```
ContentView (UI, @MainActor)
   │  SessionsViewModel  ── orquesta load / refresh / crear / renombrar / matar
   │
   ├─ SessionTerminalView ──> LiveTerminalController (@MainActor)
   │                              │  une SwiftTerm.TerminalView con un PTY remoto
   │                              ▼
   └────────────────────────> SSHService (actor)
                                  ├─ connectedClient()      conexión SSH compartida
                                  ├─ listSessions()         tmux list-sessions -F
                                  ├─ ensureTmux*            detectar / instalar / configurar
                                  ├─ create/rename/kill     canal de comandos
                                  └─ attachTerminal(...)    PTY + `exec tmux attach`
                                  │
                                  └─ TOFUHostKeyValidator   known_hosts.json (SHA256)
```

- **`SSHService`** es un `actor`: protege el `SSHClient` (no `Sendable`) frente a accesos concurrentes. La conexión es **compartida** entre la lista de sesiones y los terminales en vivo.
- **El estado de carga** se modela como un enum (`SessionsLoadState`: `verifying`, `installing`, `configuring`, `loading`, `tmuxMissing`, `loaded`, `failed`) que la UI refleja fase a fase.
- **La gestión de sesiones** (crear/renombrar/matar) va por el *canal de comandos* (`executeCommandStream`), separada del *PTY* del terminal en vivo.
- **El ciclo de vida del terminal** lo gobierna `.task(id:)`: al cambiar de sesión o cerrar la vista, la tarea se cancela, el canal se cierra y tmux hace *detach* del cliente (la sesión persiste).

## Estructura del proyecto

```
Argos/
├── ArgosApp.swift            Punto de entrada (@main, WindowGroup)
├── ContentView.swift         NavigationSplitView + SessionsViewModel + estados de UI
│
├── SSHService.swift          Actor SSH: conexión, comandos y bootstrap de tmux
├── SSHSessionManagement.swift   Extensión: crear / renombrar / matar sesiones
├── SSHTerminalSession.swift     Extensión: PTY sobre SSH + `tmux attach`
├── HostKeyVerifier.swift     Validador de host key TOFU (known_hosts.json)
│
├── TmuxSession.swift         Modelo de sesión + parseo de `list-sessions -F`
├── SessionGroup.swift        Agrupamiento puro por prefijo "grupo/nombre"
├── SessionNameValidator.swift   Validación de nombres (prohíbe ':' y '.')
│
├── LiveTerminalController.swift Une SwiftTerm con el PTY (TerminalViewDelegate)
├── SessionTerminalView.swift    Detalle: terminal en vivo + overlays de estado
├── CreateSessionSheet.swift     Sheet de creación
├── RenameSessionSheet.swift     Sheet de renombrado
└── Assets.xcassets/          Iconos y colores
```

> El proyecto está **sincronizado con el sistema de archivos**: cualquier `.swift` que añadas dentro de `Argos/` entra automáticamente en el target. No edites `project.pbxproj` a mano para registrar fuentes.

## Notas de seguridad

- **Host key TOFU:** la huella SHA256 del servidor se persiste en `~/Library/Application Support/Argos/known_hosts.json`. Si el servidor se reinstala y la huella cambia legítimamente, elimina su entrada de ese fichero para volver a confiar.
- **`sudo` no interactivo:** la instalación de tmux usa `sudo -n` (falla en vez de pedir contraseña). La app **nunca** solicita ni almacena la contraseña de `sudo`.
- **Clave privada:** se lee en tiempo de conexión desde `privateKeyPath`. No se copia ni se persiste.

## Estado del desarrollo

El proyecto avanza por fases (referenciadas en los comentarios del código):

- **Fase 0–1** — Proyecto base, conexión SSH y listado de sesiones.
- **Fase 2** — Terminal en vivo (PTY sobre SSH + `tmux attach`) con SwiftTerm; bootstrap de tmux; verificación TOFU.
- **Fase 3** — Gestión de sesiones (crear/renombrar/matar) y agrupamiento por nombres.

> **Pendiente:** todavía no existe un target de tests. Para añadirlo, crea un *Unit Testing Bundle* (Swift Testing, `import Testing`) y luego ejecuta `xcodebuild test -project Argos.xcodeproj -scheme Argos`.
</content>
</invoke>
