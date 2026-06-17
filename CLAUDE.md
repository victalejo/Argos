# CLAUDE.md

Orientación para Claude Code al trabajar en este repositorio.

## Proyecto

**Argos** es una app nativa de **macOS** (SwiftUI) que actúa como **gestor de
sesiones tmux remotas vía SSH**: lista las sesiones de cada servidor, abre un
**terminal en vivo** (PTY sobre SSH + `tmux attach`) y permite crear/renombrar/
matar sesiones. Es **multi-servidor**: los servidores se configuran y persisten
desde la UI (no hay servidor hardcodeado).

- Bundle ID: `com.iaportafolio.argos`
- Target de despliegue: **macOS 15.0** (Citadel `withPTY`/`TTYOutput` son `@available(macOS 15.0, *)`)
- Lenguaje: Swift 5 mode con concurrencia (`actor`, `@MainActor`, `Sendable`)
- Dependencias SPM: **Citadel** (SSH, pin minor 0.12.x) y **SwiftTerm** (emulador de terminal, 1.13.x)

## Compilar / Ejecutar / Probar

`project.yml` es la **fuente de verdad** del proyecto (XcodeGen). El `.xcodeproj`
se versiona como artefacto generado.

```bash
# Tras editar project.yml (añadir archivos, deps, settings): regenerar SIEMPRE
xcodegen generate

# Compilar (Debug)
xcodebuild -project Argos.xcodeproj -scheme Argos -configuration Debug build

# Tests (Swift Testing). Existe el target ArgosTests (host-less).
xcodebuild -project Argos.xcodeproj -scheme Argos test

# Ejecutar la app compilada
open ~/Library/Developer/Xcode/DerivedData/Argos-*/Build/Products/Debug/Argos.app
```

La **CI** (`.github/workflows/ci.yml`) corre build + test con cobertura y
**verifica que `xcodegen generate` no produzca drift** en `project.pbxproj`.

## Arquitectura y convenciones

Capas (archivos pequeños y cohesivos, lógica pura separada de red/UI):

- **Modelo / lógica pura** (sin dependencias de red/UI, testeable): `TmuxSession`,
  `SessionGroup` (agrupamiento), `SessionNameValidator` (valida ':' '.', control,
  prefijo '-'), `ShellQuoting` (entrecomillado POSIX anti-inyección), `Server`.
- **Servicio SSH**: `actor SSHService` (+ extensiones `SSHTerminalSession` para el
  PTY y `SSHSessionManagement` para el CRUD). Abstraído tras `protocol SSHServicing`
  para inyección de dependencias / tests con mock.
- **Persistencia / seguridad**: `ServerStore` (servers.json), `KeychainStore`
  (passphrases), `TOFUHostKeyValidator` (verificación de host key Trust-On-First-Use).
- **UI**: `ContentView` (NavigationSplitView de 3 columnas: servidores → sesiones →
  terminal), `SessionsViewModel`, `SessionsColumn`, `SessionTerminalView` +
  `LiveTerminalController`, `ServerFormSheet`, `SessionNameSheet`.
- **Observabilidad**: `os.Logger` vía `Log` (categorías ssh/terminal/hostkey/store).

Convenciones:
- **Concurrencia**: tipos aislados a `@MainActor` por defecto; el `SSHClient`
  (no-Sendable) queda protegido por el `actor SSHService`; datos que cruzan
  fronteras son `Sendable`. Marca `nonisolated`/`Sendable` explícitamente cuando aplique.
- **Inmutabilidad**: `struct` con value semantics; estados como `enum`.
- **Errores**: enums tipados `LocalizedError` con mensajes accionables; `Error.userMessage`
  para presentarlos en UI. Nunca tragar errores sin loguear.
- **Tests**: Swift Testing (`import Testing`, `@Test`/`#expect`). La lógica pura debe
  ir cubierta. El target es host-less (no lanza la app).

## Seguridad y distribución

- **App Sandbox + Hardened Runtime ACTIVADOS** (notarización-ready). Entitlements
  (generados desde `project.yml`): `app-sandbox`, `network.client` (SSH saliente),
  `files.user-selected.read-only` y `bookmarks.app-scope`.
- La **clave privada SSH** se lee por **security-scoped bookmark** que el usuario
  concede al elegir el archivo en `ServerFormSheet`. Bajo sandbox NO se puede leer
  `~/.ssh` por ruta: hay que elegir la clave en el formulario.
- La **passphrase** se guarda en **Keychain** (`KeychainStore`), nunca en código ni
  en el modelo persistido.
- Verificación de **host key TOFU**: la primera conexión confía y guarda la huella
  SHA256; un cambio posterior aborta (posible MitM). Para re-confiar tras una
  reinstalación legítima: menú contextual del servidor → "Olvidar host key".

## Convención de commits

**Conventional Commits** (`feat:`, `fix:`, `refactor:`, `test:`, `build:`,
`chore:`, `perf:`, `docs:`). El changelog se deriva del historial git
(`git log`), no de un hook.
