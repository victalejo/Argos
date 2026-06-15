# CLAUDE.md

Este archivo proporciona orientación a Claude Code (claude.ai/code) al trabajar con código en este repositorio.

## Proyecto

**Argos** es una aplicación nativa de **macOS** construida con **SwiftUI**. Actualmente es la plantilla recién generada por Xcode (punto de entrada `ArgosApp.swift` + `ContentView.swift`) — el código de las funcionalidades reales aún no se ha escrito.

- Bundle ID: `dev.victalejo.Argos`
- Target de despliegue: macOS 26.2, SDK `macosx`
- Un único target de Xcode `Argos` (sin Swift Package Manager; sin dependencias de terceros)

## Compilar / Ejecutar / Probar

Hay un solo esquema: `Argos`. Usa `xcodebuild` desde la raíz del repositorio (o compila en Xcode con ⌘B / ⌘R).

```bash
# Compilar (Debug)
xcodebuild -project Argos.xcodeproj -scheme Argos -configuration Debug build

# Compilar para Release
xcodebuild -project Argos.xcodeproj -scheme Argos -configuration Release build

# Ejecutar la app compilada (después de un build Debug)
open ~/Library/Developer/Xcode/DerivedData/Argos-*/Build/Products/Debug/Argos.app

# Pruebas — TODAVÍA NO existe un target de tests. `xcodebuild test` fallará hasta que se agregue uno.
```

## Arquitectura y convenciones

- **Proyecto sincronizado con el sistema de archivos** (`PBXFileSystemSynchronizedRootGroup`, pbxproj `objectVersion = 77`, Xcode 26). Cualquier archivo agregado dentro de la carpeta `Argos/` se incluye **automáticamente** en el target — **no** edites a mano `project.pbxproj` para registrar nuevos archivos fuente. Simplemente crea el archivo en `Argos/`.
- **Concurrencia:** el proyecto activa `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` y `SWIFT_APPROACHABLE_CONCURRENCY = YES`. Los nuevos tipos quedan aislados a `@MainActor` por defecto; marca los tipos como `nonisolated` / `Sendable` explícitamente cuando deban cruzar fronteras de aislamiento. (`SWIFT_VERSION = 5.0`.)
- **App Sandbox está ACTIVADO** (`ENABLE_APP_SANDBOX = YES`) con `ENABLE_USER_SELECTED_FILES = readonly`. Cualquier capacidad que requiera entitlements (cliente de red, lectura/escritura de archivos, etc.) debe agregarse vía Signing & Capabilities, o la app será bloqueada en tiempo de ejecución.
- La firma de código es `Automatic`.

## Agregar pruebas

No existe un target de tests. Para seguir las reglas de testing del proyecto (Swift Testing, `import Testing`, `@Test`/`#expect`), agrega primero un target de tipo Unit Testing Bundle en Xcode, y luego ejecuta `xcodebuild test -project Argos.xcodeproj -scheme Argos`.
