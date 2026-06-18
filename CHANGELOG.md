# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es/1.1.0/).
El detalle por commit vive en el historial git (Conventional Commits):
`git log --oneline`.

## [Unreleased]

### Añadido
- **Comprobador de actualizaciones**: consulta el último GitHub Release, compara con
  la versión instalada y, si hay una nueva, ofrece descargar el DMG (hoja de aviso).
  Comando de menú "Buscar actualizaciones…" + chequeo silencioso al arrancar.

## [1.0.2] - 2026-06-18

### Añadido
- **Autenticación por contraseña** además de clave Ed25519: selector en el
  formulario; la contraseña se guarda en Keychain (namespace separado).
- **Vista unificada de sesiones**: las de todos los servidores en una sola lista,
  agrupadas por servidor y con su estado de conexión; **búsqueda/filtrado**.
- **Subida de archivos por SFTP**: pegar una imagen (⌘V) o **arrastrar archivos**
  desde Finder al terminal → se suben a `/tmp` y la ruta remota se inserta en la
  línea de comandos.
- **Apariencia configurable**: tamaño de fuente y tema (claro/oscuro/Solarized)
  desde Preferencias (⌘,), persistidos y aplicados en vivo.
- **Reconexión automática** con backoff exponencial ante caídas de red/SSH.
- Menú **Edición** (⌘C/⌘V/⌘X/⌘A) para copiar/pegar en el terminal.
- **LICENSE** (Apache-2.0) y workflow de **Release** que publica el `.dmg` con notas
  generadas automáticamente desde los Conventional Commits.

### Corregido
- **Portapapeles OSC 52**: la copia desde apps remotas (p. ej. "c to copy" de Claude
  Code) ahora llega al portapapeles del Mac (handler propio en el parser; el
  `TerminalView` de SwiftTerm en macOS no reenvía OSC 52 al delegate). El bootstrap
  habilita `set-clipboard on` en el tmux del servidor.
- **Scroll del ratón** reenviado al PTY cuando hay mouse reporting (tmux/apps); antes
  solo desplazaba el buffer local.
- Lectura de claves en `~/.ssh` mediante entitlement de excepción (el App Sandbox
  bloqueaba la ruta y la conexión fallaba).
- El terminal ya no queda tapado por la barra de título; pantalla de carga mientras
  se conecta la sesión.

## [1.0.1] - 2026-06-17

### Añadido
- Workflow de **Release DMG**: build Release con firma ad-hoc + empaquetado `.dmg`
  e instalación arrastrando a Applications.

## [1.0.0] - 2026-06-17

### Añadido
- Gestor **multi-servidor**: modelo `Server` + `ServerStore` persistente; alta/
  edición/borrado de servidores desde una UI de 3 columnas.
- **Keychain** para passphrases de clave SSH (`KeychainStore`).
- **App Sandbox + Hardened Runtime** con entitlements (notarización-ready); la
  clave SSH se lee por security-scoped bookmark.
- `protocol SSHServicing` para inyección de dependencias y tests con mock.
- Target de **tests** (Swift Testing) + **CI** (GitHub Actions) con cobertura y
  verificación de sincronía XcodeGen.
- Acción **"Olvidar host key"** para resetear el TOFU tras reinstalar un servidor.
- Logging estructurado con `os.Logger`.

### Cambiado
- `project.yml` (XcodeGen) es la **fuente de verdad**; el `.xcodeproj` se versiona
  como artefacto generado.
- Buffer de salida del PTY acotado (`bufferingNewest`) para salidas muy grandes.
- Sheets de crear/renombrar unificados en `SessionNameSheet`.

### Seguridad
- Eliminado el *footgun* de passphrase hardcodeada en el código fuente.
- `SessionNameValidator` rechaza caracteres de control y el prefijo `-`.
- Persistencia de host key: los fallos de decode/escritura ya se registran.

## [Inicial] - 2026-06-14
- Commit inicial y fases 0-1.
