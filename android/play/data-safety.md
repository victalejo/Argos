# Seguridad de los datos (Play Console → Contenido de la app → Seguridad de los datos)

Respuestas basadas en el código de `android/` (revisado el 2026-11-08). Si cambia el código
(analítica, informes de fallos, un servidor propio…), **revisa este documento antes de subir**.

## Resumen para el formulario

| Pregunta | Respuesta |
|---|---|
| ¿Tu app recopila o comparte alguno de los tipos de datos de usuario obligatorios? | **No** |
| ¿Todos los datos de usuario recopilados por tu app están encriptados en tránsito? | (no aplica al responder «No»; si Play lo pide: **Sí**, todo viaja por SSH) |
| ¿Ofreces a los usuarios una forma de solicitar que se borren sus datos? | (no aplica: no hay cuentas ni datos en servidores del desarrollador; se borran desinstalando la app o borrando el servidor en la app) |

Con «No» Play muestra en la ficha «No se recopilan datos» y «No se comparten datos con terceros».

## Por qué «no se recopila nada»

Para Google, *recopilar* es transmitir datos fuera del dispositivo **al desarrollador o a terceros**.
Argos no tiene servidores propios ni SDK de terceros que envíen nada:

- **Sin analítica, sin informes de fallos, sin publicidad, sin cuentas.** No hay Firebase, Crashlytics,
  Google Play Services ni ningún SDK de red aparte de sshj (SSH). Dependencias: ver la pantalla
  «Licencias de código abierto» o `app/build/generated/aboutLibraries/`.
- **Las únicas conexiones de red son SSH a los servidores que el propio usuario configura**
  (`INTERNET`). No hay peticiones HTTP desde la app.
- Los enlaces (política de privacidad, repositorio, webs de licencias, enlaces de un Markdown, URL de
  inicio de sesión de Claude) se abren en el navegador del sistema **solo tras confirmar la URL**.
- El token de suscripción de Claude (si el usuario lo pega) solo sale del dispositivo hacia el
  servidor SSH del propio usuario, por la conexión cifrada, al lanzar un agente.

**Punto discutible (para que lo decidas tú):** lo que el usuario escribe en el terminal o al agente
viaja a SU servidor. Es el propósito de la app (como cualquier cliente SSH) y no llega al
desarrollador, por eso no se declara. Si un revisor lo cuestiona, la alternativa conservadora es
declarar «Mensajes de la app» / «Otro contenido generado por el usuario» como *recopilado*, **no
compartido**, *procesado de forma efímera: no*, *obligatorio*, finalidad «Funciones de la app», y
cifrado en tránsito «Sí».

## Qué se guarda SOLO en el dispositivo

Nada de esto sale del dispositivo ni entra en copias de seguridad: `allowBackup="false"` y
`data_extraction_rules.xml` excluye todo de la copia en la nube y de la transferencia entre
dispositivos.

| Dato | Dónde | Protección |
|---|---|---|
| Servidores (nombre, host, puerto, usuario, método) | `servers.json` en el almacenamiento privado de la app | Sandbox de Android |
| Contraseñas, passphrases, claves privadas importadas, token de Claude | Archivos `.bin` en el almacenamiento privado | **Cifrados con AES-256-GCM** con una clave por servidor generada dentro del **Android Keystore** (TEE/StrongBox si existe), no exportable (`KeystoreSecretCipher`) |
| Huellas de host (TOFU, SHA-256) | Almacenamiento privado | Sandbox de Android |
| Preferencias (tamaño de letra, permisos de agentes, avisos, agentes vigilados) | SharedPreferences privadas | Sandbox de Android |
| Archivos descargados del servidor | Donde el usuario elija con el selector del sistema (SAF) | Lo decide el usuario |
| Imágenes de la cámara | Solo en memoria, para decodificar el QR del Mac; no se guardan | — |

## Permisos y para qué

| Permiso | Origen | Uso |
|---|---|---|
| `INTERNET` | app | Conexiones SSH a los servidores del usuario |
| `CAMERA` | app | Solo para leer el QR de «Enviar al iPhone…» del Mac; se pide en el momento; opcional (`uses-feature required=false`) |
| `POST_NOTIFICATIONS` | app | Avisos «el agente terminó / espera tu permiso» y la notificación del terminal en segundo plano |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_SPECIAL_USE` | app | Mantener conectados los terminales abiertos en segundo plano (ver `foreground-service.md`) |
| `WAKE_LOCK` | WorkManager | Lo usa WorkManager internamente al ejecutar la comprobación periódica de agentes. Argos no toma WakeLocks propios |
| `ACCESS_NETWORK_STATE` | WorkManager | Restricción «solo con red» de la comprobación periódica |
| `RECEIVE_BOOT_COMPLETED` | WorkManager | Reprogramar la comprobación periódica tras reiniciar el dispositivo |
| `com.iaportafolio.argos.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` | AndroidX Core | Permiso interno de firma para receptores no exportados; no es visible al usuario |

## Lo que no he podido verificar

- La política de privacidad web cubre Android desde el 2026-11-08 (Keystore, cámara solo para el QR,
  avisos locales).
- Correo de contacto de la ficha de Play: `alejo@iaportafolio.com`.
