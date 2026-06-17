# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es/1.1.0/).
El detalle por commit vive en el historial git (Conventional Commits):
`git log --oneline`.

## [Unreleased]

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
