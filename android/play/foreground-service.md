# Declaración del servicio en primer plano `specialUse`

Play Console → Contenido de la app → **Permisos de servicios en primer plano** → tipo
`FOREGROUND_SERVICE_SPECIAL_USE`. Servicio: `com.iaportafolio.argos.background.TerminalKeepAliveService`
(`android:foregroundServiceType="specialUse"`, no exportado). La revisión es manual y puede
rechazarse: si ocurre, se puede retirar el servicio y los avisos de agentes siguen por WorkManager
(ver `android/README.md` → Segundo plano).

## Descripción (pegar en el formulario; inglés, como la `property` del manifiesto)

> Argos is an SSH client for the user's own servers. While the user has an interactive terminal
> session open (a live SSH connection attached to tmux), this service keeps the app process alive
> when the user switches to another app, so that long-running remote commands stay visible and the
> session resumes instantly when they return. It starts only from a user action (opening a
> terminal) while the app is in the foreground, only if the in-app setting "Keep the terminal
> connected in the background" is on (Settings → Notifications and background), always shows an
> ongoing notification with the number of connected terminals and a "Disconnect all" action, and
> stops by itself when the last terminal is closed or disconnected. It does not run at boot, does
> not do periodic work and does not collect data.

Versión en español (por si el formulario o el revisor la piden):

> Argos es un cliente SSH para los servidores del propio usuario. Mientras el usuario tiene abierto
> un terminal interactivo (una conexión SSH viva enganchada a tmux), este servicio mantiene vivo el
> proceso al cambiar de app, para que los comandos largos sigan visibles y la sesión se retome al
> instante al volver. Solo arranca por una acción del usuario (abrir un terminal) con la app en primer
> plano, solo si el ajuste «Mantener el terminal conectado en segundo plano» está activado (Ajustes →
> Avisos y segundo plano), siempre muestra una notificación permanente con el número de terminales
> conectados y la acción «Desconectar todo», y se detiene solo al cerrar o desconectar el último
> terminal. No arranca al iniciar el dispositivo, no hace trabajo periódico y no recoge datos.

## Por qué no vale otro tipo

- **`dataSync`**: es para transferir datos (subir/bajar/sincronizar) y Android 15+ lo limita a 6 h
  al día. Una sesión SSH interactiva no es una transferencia: es una conexión abierta a la espera
  de lo que haga el usuario, que puede durar horas.
- **`remoteMessaging`**: es para apps de mensajería (llamadas/mensajes entre personas). Un terminal no
  es un servicio de mensajería.
- **`connectedDevice`**: exige un dispositivo externo (Bluetooth, USB, NFC, red local con permisos de
  dispositivos). Un servidor en Internet no lo es.
- **`shortService`**: se corta a los ~3 minutos; un comando de compilación o un despliegue duran más.
- **`mediaPlayback`, `location`, `camera`, `microphone`, `phoneCall`, `health`, `systemExempted`,
  `mediaProjection`**: no aplican.
- **WorkManager / trabajos programados**: no mantienen un socket abierto ni un PTY interactivo; Argos
  ya usa WorkManager para lo que sí es periódico (comprobar agentes cada 15 min).

## Cómo lo ve el usuario

1. Abre un terminal (pestaña Terminal de un proyecto o una sesión suelta): al adjuntarse el primero
   aparece la notificación permanente **«Argos mantiene 1 terminal conectado»** (canal «Terminal en
   segundo plano») con el botón **«Desconectar todo»**.
2. Cambia a otra app: la conexión sigue; al volver, el terminal está igual.
3. «Desconectar todo» cierra las conexiones (las sesiones tmux siguen vivas en el servidor) y la
   notificación desaparece. También desaparece al cerrar el último terminal.
4. Se puede desactivar en Ajustes (icono de engranaje de la pantalla Servidores) → **Avisos y segundo
   plano** → «Mantener el terminal conectado en segundo plano».

## Guion del vídeo (30–60 s, grabación de pantalla del teléfono, subir a YouTube como «no listado»)

Antes: instala la versión de la pista interna, añade el servidor de demostración (ver
`review-notes.md`) y deja las notificaciones permitidas. Activa «Mostrar toques» en las opciones de
desarrollador para que se vean las pulsaciones.

| Tiempo | Qué se ve | Texto en pantalla (opcional) |
|---|---|---|
| 0–5 s | Pantalla Servidores → engranaje → «Avisos y segundo plano»: el interruptor «Mantener el terminal conectado en segundo plano» activado | «El usuario activa la opción» |
| 5–15 s | Tocar el servidor de demo → proyecto `web/tienda-online` → pestaña Terminal. Se conecta y aparece el prompt. Escribir `top` (o `ping -c 100 localhost`) para que haya salida continua | «El usuario abre un terminal SSH» |
| 15–22 s | Bajar la cortina: se ve la notificación «Argos mantiene 1 terminal conectado» con «Desconectar todo» | «Notificación visible mientras dure» |
| 22–32 s | Ir a la pantalla de inicio, abrir otra app unos segundos, volver a Argos: el comando sigue corriendo, sin reconectar | «La sesión sigue viva al cambiar de app» |
| 32–42 s | Bajar la cortina y pulsar «Desconectar todo»: la notificación desaparece y el terminal muestra «Lo desconectaste desde la notificación…» | «El usuario lo detiene cuando quiere» |
| 42–50 s | Volver a abrir el terminal y salir con atrás hasta cerrarlo: la notificación desaparece sola | «Se detiene al cerrar el último terminal» |

Pega el enlace del vídeo en el formulario junto a la descripción.
