# Checklist de publicación en Google Play (cuenta de organización Impulse Vibes)

En orden. Lo marcado con ⚠️ no lo puede hacer la CI ni este repo.

## 0. Cuenta de desarrollador (organización)

- [ ] ⚠️ Cuenta de Play Console de **organización** a nombre de Impulse Vibes S.A.S.: requiere
      **número D-U-N-S** de la empresa (los datos deben coincidir con los de Dun & Bradstreet), pago
      único de registro, verificación de identidad de la organización y de la persona de contacto, y
      un **sitio web** de la organización verificado en Search Console si Play lo pide.
- [ ] ⚠️ Datos de contacto públicos de la organización (correo, teléfono y, al tener la app gratuita
      sin compras, la dirección puede no mostrarse; revisa lo que exige Play Console en tu caso). El
      correo de la ficha debe ser real y atendido: **TODO** decidir cuál. La ficha de Apple solo usa
      GitHub Issues; la política de privacidad usa `marketing@iaportafolio.com`. Escríbelo en Play
      Console → Ficha de Play Store → Detalles de contacto (o crea `app/src/main/play/contact-email.txt`).
- [ ] Las cuentas de **organización** no tienen el requisito de «prueba cerrada con 12 testers durante
      14 días» que se aplica a las cuentas personales nuevas: se puede pasar de prueba interna a
      producción directamente cuando esté lista.
- [ ] ⚠️ Verificación de desarrollador de Android (registro del nombre de paquete
      `com.iaportafolio.argos` con la clave de firma): Play Console la gestiona para apps de Play;
      sigue los avisos de la consola si aparecen.

## 1. Clave de subida (upload key) — una sola vez, en tu Mac

```bash
keytool -genkeypair -v -keystore ~/claves/argos-upload.jks -alias argos-upload \
  -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=Impulse Vibes S.A.S., O=Impulse Vibes, C=CO"
```

- [ ] Guarda el `.jks` y sus contraseñas en un gestor de contraseñas (fuera del repo: `.gitignore`
      ya ignora `*.jks`, `*.keystore` y `play-service-account*.json`).
- [ ] Firma local: ver `android/README.md` → Publicación → «Firmar en local».

## 2. Crear la app en Play Console

- [ ] Crear app: nombre «Argos — Terminal SSH y tmux», idioma predeterminado **Español
      (Latinoamérica) – es-419**, App, Gratis.
- [ ] Aceptar las declaraciones (políticas del programa, leyes de exportación de EE. UU.: la app usa
      cifrado estándar de SSH).

## 3. Primera subida MANUAL del AAB (GPP no puede crear la app)

La API de publicación no registra una app nueva: el **primer** AAB se sube a mano.

```bash
cd android
# sube ARGOS_VERSION_CODE en gradle.properties si ya se subió alguno
./gradlew :app:bundleRelease -PARGOS_REQUIRE_SIGNING=true   # con las 4 ARGOS_UPLOAD_* definidas
ls app/build/outputs/bundle/release/app-release.aab
```

(o lanza el workflow «Android release» y descarga el artefacto `argos-android-aab`).

- [ ] Prueba → **Prueba interna** → Crear versión → al subir el primer AAB, **activar Play App
      Signing** («Firma de apps de Google Play», opción por defecto: Google genera y custodia la
      clave de la app; tu `.jks` queda como clave de SUBIDA, revocable si se pierde).
- [ ] Notas de la versión: copia `app/src/main/play/release-notes/es-419/internal.txt`.
- [ ] Testers: crea una lista de correos (p. ej. «Equipo») y comparte el enlace de participación.
- [ ] Guardar como borrador → revisar → «Iniciar el lanzamiento en Prueba interna».

## 4. Contenido de la app (Play Console → Política → Contenido de la app)

- [ ] **Política de privacidad:** `https://iaportafolio.com/privacidad#argos`. ⚠️ Antes, actualiza la
      página: hoy dice «App Argos (macOS, iPhone y iPad)» y habla del Llavero; añade Android
      (Keystore, cámara solo para el QR, notificaciones, sin copias de seguridad).
- [ ] **Acceso a la app:** `review-notes.md` (servidor demo; contraseña copiada a mano).
- [ ] **Anuncios:** No contiene anuncios.
- [ ] **Clasificación del contenido:** `content-rating.md`.
- [ ] **Público objetivo:** 18+ (ver `content-rating.md`).
- [ ] **Seguridad de los datos:** `data-safety.md`.
- [ ] **Permisos de servicios en primer plano:** `foreground-service.md` (descripción + vídeo en
      YouTube no listado). Sin esta declaración aprobada no se puede pasar a producción.
- [ ] Apps gubernamentales / financieras / de salud / noticias / VPN: **No** en todas.
- [ ] Eliminación de cuenta: la app **no permite crear cuentas** (no aplica).

## 5. Ficha de Play Store

- [ ] Textos: los gestiona GPP desde `app/src/main/play/listings/` (es-419 por defecto, es-ES,
      en-US). Primera vez: pégalos a mano o, con la cuenta de servicio lista,
      `ARGOS_PLAY_SERVICE_ACCOUNT=… ./gradlew :app:publishListing`.
- [ ] ⚠️ Gráficos (no están en el repo): icono 512×512 PNG, gráfico de funciones 1024×500, 2–8
      capturas de teléfono (y de tablet de 7" y 10" para aparecer como app de tablet). Se pueden
      añadir en `app/src/main/play/listings/es-419/graphics/{icon,feature-graphic,phone-screenshots,
      tablet-screenshots,large-tablet-screenshots}/` y GPP los sube. Hazlas contra la cuenta demo.
- [ ] Categoría: **Herramientas** (o Productividad). Etiquetas: SSH, terminal, desarrollo.
- [ ] Sitio web: `https://github.com/victalejo/Argos/issues` (en `contact-website.txt`).

## 6. Cuenta de servicio para GPP (permisos mínimos)

- [ ] Google Cloud Console (proyecto de la organización) → **habilitar «Google Play Android Developer
      API»**.
- [ ] IAM → Cuentas de servicio → Crear (p. ej. `argos-play-publisher`) **sin roles de Cloud**
      (no hacen falta) → Claves → Agregar clave JSON → descargar como
      `play-service-account-argos.json` (ignorado por git; mejor fuera del repo).
- [ ] Play Console → **Usuarios y permisos** → Invitar al correo de la cuenta de servicio →
      permisos **solo de la app Argos** (no de la cuenta): «Ver información de la app», «Publicar en
      pistas de prueba» (*Release to testing tracks*) y, si quieres que GPP suba la ficha,
      «Administrar la presencia en Play Store». **Nada** de producción, finanzas ni administrar
      usuarios. Para producción, añade «Publicar en producción…» solo cuando lo necesites.
- [ ] Prueba local: `ARGOS_PLAY_SERVICE_ACCOUNT=/ruta/al.json ./gradlew :app:publishReleaseBundle`
      (crea un BORRADOR en la pista interna; nada se publica sin que lo lances en la consola).

## 7. CI de publicación (GitHub Actions)

- [ ] ⚠️ Secretos del repo (Settings → Secrets and variables → Actions), ver `android/README.md`:
      `ARGOS_UPLOAD_KEYSTORE_BASE64` (`base64 -i argos-upload.jks | pbcopy`),
      `ARGOS_UPLOAD_STORE_PASSWORD`, `ARGOS_UPLOAD_KEY_ALIAS`, `ARGOS_UPLOAD_KEY_PASSWORD` y,
      opcional, `ARGOS_PLAY_SERVICE_ACCOUNT` (contenido del JSON).
- [ ] Recomendado: un *environment* `play` con revisores obligatorios para el workflow.
- [ ] Publicar: sube `ARGOS_VERSION_CODE`, commit, `git tag android-v1.0.0 && git push --tags` →
      workflow «Android release» → AAB como artefacto y, si hay cuenta de servicio, borrador en la
      pista interna → revisar y lanzar en Play Console.

## 8. Producción

- [ ] Con la declaración del servicio en primer plano aprobada y la prueba interna validada: Prueba
      interna → «Promocionar versión» → Producción (o `--track production` en GPP), países, y
      enviar a revisión. Usa lanzamiento progresivo si quieres.
