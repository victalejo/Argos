# Argos en la Mac App Store

Hay **dos variantes** de la app de Mac, generadas desde la plantilla `ArgosMac` de
`project.yml`:

| Target          | Canal                         | Actualizaciones | `~/.ssh`                               | Abrir Terminal con Claude Code                      |
|-----------------|-------------------------------|-----------------|----------------------------------------|-----------------------------------------------------|
| `Argos`         | GitHub (DMG + Sparkle)        | Sparkle         | excepción temporal de sandbox          | Apple Events (excepción temporal)                   |
| `ArgosAppStore` | Mac App Store (flag `APPSTORE`) | App Store     | el usuario concede la carpeta una vez | script de usuario + `NSUserAppleScriptTask`         |

Las dos hacen lo mismo; la de App Store no usa ninguna excepción temporal
(Ajustes → Permisos muestra y revoca lo concedido).

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
- Perfil **Argos Mac App Store** (`MAC_APP_STORE`, bundle id `YH7WZ4KP29`) en
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`. Caduca con el
  certificado de distribución (2027-08-19): regénéralo por la API entonces.

App en App Store Connect: id `6831410935`.
