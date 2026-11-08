# Argos en la Mac App Store

Hay **dos variantes** de la app de Mac, generadas desde la plantilla `ArgosMac` de
`project.yml`:

| Target          | Canal                         | Actualizaciones | `~/.ssh`                               | Abrir Terminal con Claude Code                      |
|-----------------|-------------------------------|-----------------|----------------------------------------|-----------------------------------------------------|
| `Argos`         | GitHub (DMG + Sparkle)        | Sparkle         | excepción temporal de sandbox          | Apple Events (excepción temporal)                   |
| `ArgosAppStore` | Mac App Store (flag `APPSTORE`) | App Store     | el usuario concede la carpeta una vez | script de usuario + `NSUserAppleScriptTask`         |

Las dos hacen lo mismo; la de App Store no usa ninguna excepción temporal
(Ajustes → Permisos muestra y revoca lo concedido) y además sincroniza servidores y
huellas con iPhone/iPad por iCloud clave-valor (capacidad ICLOUD del App ID; si se
regeneran los perfiles, deben incluir `com.apple.developer.ubiquity-kvstore-identifier`).

## Subir un build

```bash
scripts/appstore/upload-mac.sh
```

Archiva `ArgosAppStore`, comprueba que no lleva Sparkle ni excepciones temporales y
lo sube a App Store Connect (aparece en TestFlight tras procesarse). La versión sale
de `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` en `project.yml` (comunes a todos
los targets): **sube `CURRENT_PROJECT_VERSION` antes de cada subida**.

## Firma (team Impulse Vibes S.A.S., `L6WGLNT9XZ`)

La clave de API (`AuthKey_576N2X283X.p8`) no tiene acceso a la firma en la nube, así
que `ExportOptions.plist` usa firma **manual** con material del llavero de sesión:

- **Apple Distribution: Impulse Vibes S A S** (`PJ8AR2TRWA`): firma la app.
- **3rd Party Mac Developer Installer: Impulse Vibes S A S** (`22MD2PXSD9`, creado
  por la API el 2026-11-06, caduca 2027-11-06): firma el `.pkg`.
- Perfil **Argos Mac App Store** (`MAC_APP_STORE`, id `BZ8LA6RTY8`, bundle id `YH7WZ4KP29`; regenerado el 2026-11-07 con iCloud) en
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`. Caduca con el
  certificado de distribución (2027-08-19): regénéralo por la API entonces.

App en App Store Connect: id `6831410935`.

## iPhone/iPad (target `ArgosiOS`)

```bash
scripts/appstore/upload-ios.sh
```

Archiva con firma automática y exporta con `ExportOptions-iOS.plist`: certificado
**Apple Distribution** y perfil **Argos iOS App Store** (`IOS_APP_STORE`, id
`6WHKKAQ6K7`, regenerado por la API el 2026-11-07 con iCloud; caduca con el certificado). El grupo
interno de TestFlight «Equipo» recibe todos los builds.

Prueba de extremo a extremo contra la cuenta de demostración (ver
`ArgosiOSUITests/DemoServerFlowTests.swift`):

```bash
TEST_RUNNER_ARGOS_DEMO_HOST=190.102.110.8 TEST_RUNNER_ARGOS_DEMO_PORT=2222 \
TEST_RUNNER_ARGOS_DEMO_PASSWORD=… \
xcodebuild test -project Argos.xcodeproj -scheme ArgosiOS \
  -destination 'platform=iOS Simulator,name=<simulador>'
```

## Ficha y capturas

- `ruby scripts/appstore/push-listing.rb`: textos, categorías, precio y notas de revisión
  desde `listing-es-MX.json`.
- `ruby scripts/appstore/push-screenshots.rb`: sube `screenshots/mac/*.png` (2560×1600,
  sin transparencia) al set `APP_DESKTOP`, reemplazando las anteriores.

Las capturas se hacen con una copia de Argos con otro bundle id (para no tocar los
servidores reales) conectada a la cuenta de demostración `argos-demo` de
`190.102.110.8:2222`, la misma que usa App Review (contraseña solo en App Store Connect).
