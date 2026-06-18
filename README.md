# Argos

**Gestor visual de sesiones [tmux](https://github.com/tmux/tmux) remotas vía SSH**, nativo de macOS y construido con SwiftUI.

[![CI](https://github.com/victalejo/Argos/actions/workflows/ci.yml/badge.svg)](https://github.com/victalejo/Argos/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/victalejo/Argos?sort=semver)](https://github.com/victalejo/Argos/releases/latest)
[![Descargas](https://img.shields.io/github/downloads/victalejo/Argos/total)](https://github.com/victalejo/Argos/releases)
[![Licencia](https://img.shields.io/github/license/victalejo/Argos)](LICENSE)
![macOS 15.0+](https://img.shields.io/badge/macOS-15.0%2B-blue?logo=apple)

Argos gestiona **varios servidores**: se conecta por SSH, garantiza que tmux esté instalado y configurado, lista las sesiones de cada servidor y abre un **terminal en vivo** (`tmux attach`) sobre un PTY remoto. Permite crear, renombrar y matar sesiones sin salir de la app.

```
┌───────────────┬──────────────────────┬─────────────────────────────────┐
│ Servidores [+]│  Sesiones tmux    [+] │  main · tmux attach             │
│ ───────────── │ ──────────────────────│ ─────────────────────────────── │
│ ● dev         │  ▸ magic-agents       │  $ tail -f /var/log/app.log     │
│ ○ producción  │      backend  ● Activa│  ...                            │
│               │      frontend ○       │  (terminal en vivo, PTY sobre   │
│               │  ▸ General            │   SSH + SwiftTerm)              │
│               │      main     ● Activa│                                 │
└───────────────┴──────────────────────┴─────────────────────────────────┘
```

---

## Descarga e instalación

Descarga el `.dmg` más reciente desde **[Releases](https://github.com/victalejo/Argos/releases/latest)**, ábrelo y arrastra **Argos** a *Applications*.

Las builds son **ad-hoc (sin notarizar)**, así que en la primera ejecución Gatekeeper la bloquea. Para abrirla:

```sh
xattr -dr com.apple.quarantine /Applications/Argos.app
```

o clic derecho sobre la app → **Abrir** (solo la primera vez).

> ¿Prefieres compilarla tú? Ve a [Compilar y ejecutar](#compilar-y-ejecutar).

## Características

- **Multi-servidor** — añade, edita y borra servidores desde la UI; se persisten en `servers.json`. Sin servidor hardcodeado. Las sesiones de **todos** los servidores se ven en una sola lista, agrupadas por servidor, con su estado de conexión.
- **Autenticación por clave o contraseña** — clave privada Ed25519 OpenSSH (con passphrase opcional) o usuario + contraseña (vía [Citadel](https://github.com/orlandos-nl/Citadel)). El secreto se guarda en **Keychain**, nunca en disco plano ni en el código.
- **Verificación de host key TOFU** (*Trust-On-First-Use*) — la huella SHA256 se guarda en la primera conexión y se valida en las siguientes; si cambia, la conexión se aborta (protección MitM). Reset desde la app: clic derecho en el servidor → **"Olvidar host key"**.
- **Bootstrap automático de tmux** — detecta tmux; si falta y hay `sudo` sin contraseña, lo instala con `apt`; crea un `~/.tmux.conf` base si no existe. Habilita el reenvío de portapapeles (OSC 52). Idempotente y no interactivo (nunca pide ni guarda la contraseña de `sudo`).
- **Lista de sesiones agrupada y con búsqueda** — por convención de nombres: el prefijo antes del primer `/` define el grupo (`magic-agents/backend` → grupo *magic-agents*); las que no tienen `/` caen en *General*. Campo de búsqueda para filtrar por nombre.
- **Terminal en vivo** — PTY interactivo sobre SSH ejecutando `tmux attach`, renderizado con [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). Teclado, *resize* (window-change), **scroll del ratón** reenviado a tmux/la app, **copia/pega** (⌘C/⌘V) y **portapapeles OSC 52** (p. ej. "c to copy"), y buffer de salida acotado (resiste salidas enormes).
- **Subir archivos e imágenes** — **pega una imagen** (⌘V) o **arrastra archivos** desde Finder al terminal: se suben por **SFTP** a `/tmp` y la ruta remota se inserta en la línea de comandos (ideal para pasarle imágenes a herramientas como Claude Code).
- **Apariencia configurable** — tamaño de fuente y tema (claro/oscuro/Solarized) desde Preferencias (⌘,), persistidos y aplicados en vivo.
- **Reconexión automática** — ante una caída de red/SSH reintenta solo con backoff exponencial; el *detach* limpio no reconecta.
- **Gestión de sesiones** — crear / renombrar / matar, con validación de nombres y manejo de errores en la propia UI.
- **Detach, no kill** — cerrar el terminal o cambiar de sesión hace *detach*: la sesión tmux sobrevive en el servidor.

## Requisitos

- **macOS 15.0+** (el terminal en vivo usa `Citadel.withPTY` / `TTYOutput`, marcados `@available(macOS 15.0, *)`).
- **Xcode 16+** (Swift 5.0, `MainActor` por defecto).
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** para regenerar el proyecto desde `project.yml` (`brew install xcodegen`).
- Un **servidor accesible por SSH** (el bootstrap de tmux asume Ubuntu/Debian: usa `apt`).
- Credenciales: una **clave Ed25519** en formato OpenSSH **o** usuario + contraseña.

> **App Sandbox + Hardened Runtime ACTIVADOS** (distribución/notarización-ready). Las claves en `~/.ssh` se leen directamente (entitlement de excepción de solo-lectura); para una clave en otra ruta, la app guarda un *security-scoped bookmark* al elegirla. Red saliente vía entitlements.

## Dependencias (Swift Package Manager)

| Paquete | Uso | Versión |
|---|---|---|
| [Citadel](https://github.com/orlandos-nl/Citadel) | Cliente SSH (conexión, comandos, PTY) | `minorVersion: 0.12.0` |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Emulador de terminal (NSView de AppKit) | `minorVersion: 1.13.0` |

## Configurar un servidor

1. Pulsa **+** (en la barra lateral, "Añadir servidor").
2. Rellena nombre, host, puerto, usuario.
3. Elige el método de **autenticación**:
   - **Clave SSH:** indica la ruta de la clave privada (las de `~/.ssh` se leen directamente; para otra ubicación usa "Elegir…", que concede un *security-scoped bookmark*). Si tiene **passphrase**, escríbela.
   - **Contraseña:** escribe la contraseña de login.
4. El secreto (passphrase o contraseña) se guarda en **Keychain**, nunca en disco plano ni en el código.

> Al primer arranque hay un servidor de ejemplo ("dev"). Edítalo con tus datos para conectar.

## Compilar y ejecutar

`project.yml` es la **fuente de verdad** (XcodeGen). `Argos.xcodeproj` se versiona como artefacto generado; **si cambias `project.yml` debes regenerarlo**.

```bash
xcodegen generate                                                       # tras editar project.yml
xcodebuild -project Argos.xcodeproj -scheme Argos -configuration Debug build
xcodebuild -project Argos.xcodeproj -scheme Argos test                  # Swift Testing
open ~/Library/Developer/Xcode/DerivedData/Argos-*/Build/Products/Debug/Argos.app
```

O abre `Argos.xcodeproj` en Xcode y pulsa ⌘R. La **CI** (GitHub Actions) corre build + test con cobertura y verifica que `xcodegen generate` no produzca *drift* en el `.pbxproj`.

## Arquitectura

Capas de concurrencia bien separadas: la red en un `actor`, la UI en `@MainActor`. La lógica pura no depende de red/UI (y está cubierta por tests).

```
ContentView (UI, @MainActor)  ── NavigationSplitView de 3 columnas
   │  ServerStore ── servidores persistidos (servers.json)
   │  SessionsViewModel ── load / refresh / crear / renombrar / matar
   │
   ├─ SessionTerminalView ──> LiveTerminalController (@MainActor)
   │                              │  une SwiftTerm.TerminalView con un PTY remoto
   │                              ▼
   └────────────────────────> any SSHServicing  ◀── SSHService (actor)
                                  ├─ connectedClient()      conexión SSH compartida
                                  ├─ listSessions()         tmux list-sessions -F
                                  ├─ ensureTmux*            detectar / instalar / configurar
                                  ├─ create/rename/kill     canal de comandos
                                  └─ attachTerminal(...)    PTY + `exec tmux attach`

   KeychainStore (passphrases)   TOFUHostKeyValidator (known_hosts.json, SHA256)
   ShellQuoting (anti-inyección) SessionNameValidator (':' '.' control '-')
```

- **`SSHService`** es un `actor` que protege el `SSHClient` (no `Sendable`); abstraído tras **`protocol SSHServicing`** para inyección de dependencias y tests con mock.
- **El estado de carga** se modela como enum (`SessionsLoadState`) que la UI refleja fase a fase.
- **La gestión de sesiones** va por el *canal de comandos* (`executeCommandStream`), separada del *PTY*.
- **El ciclo de vida del terminal** lo gobierna `.task(id:)`: al cambiar de sesión/cerrar la vista, la tarea se cancela y tmux hace *detach* (la sesión persiste).

Detalle de arquitectura y convenciones en [CLAUDE.md](CLAUDE.md).

## Notas de seguridad

- **App Sandbox + Hardened Runtime** activados; entitlements generados desde `project.yml`.
- **Clave privada:** las de `~/.ssh` se leen por un entitlement de excepción de solo-lectura; las de otra ruta, por security-scoped bookmark que concedes al elegirla. No se copia ni se persiste su contenido.
- **Secretos (passphrase / contraseña):** en Keychain (`KeychainStore`), en namespaces separados, nunca en código ni en el modelo persistido.
- **Host key TOFU:** huella en `~/Library/Application Support/Argos/known_hosts.json`; reset desde la app con "Olvidar host key".
- **Anti-inyección:** los nombres de sesión se validan y se entrecomillan (POSIX, `ShellQuoting`) antes de enviarse a tmux.
- **`sudo` no interactivo:** la instalación de tmux usa `sudo -n`; la app nunca pide ni guarda la contraseña de `sudo`.

## Convención de commits

[Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `refactor:`, `test:`, `build:`, `chore:`, `perf:`, `docs:`). El changelog se mantiene en [CHANGELOG.md](CHANGELOG.md) y el detalle vive en `git log`.
