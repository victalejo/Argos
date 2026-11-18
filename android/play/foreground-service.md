# Declaración del servicio en primer plano `specialUse`

Play Console → Contenido de la app → **Permisos de servicios en primer plano** → tipo
`FOREGROUND_SERVICE_SPECIAL_USE`. Servicio: `com.iaportafolio.argos.background.TerminalKeepAliveService`
(`android:foregroundServiceType="specialUse"`, no exportado). Cubre dos usos: terminales abiertos y
reenvíos de puertos abiertos (pantalla «Puertos» o una solicitud de Claude aceptada). La revisión es manual y puede
rechazarse: si ocurre, se puede retirar el servicio y los avisos de agentes siguen por WorkManager
(ver `android/README.md` → Segundo plano).

## Descripción (pegar en el formulario; inglés, como la `property` del manifiesto)

> Argos is an SSH client for the user's own servers. This service keeps the app process alive while
> the app is in the background and the user has either an interactive terminal session open (a live
> SSH connection attached to tmux) or a local port forward they opened to view, in the phone's
> browser, a web app that runs on their own server (for example a development server on port 3000).
> Without it, long-running remote commands are interrupted and the forwarded page stops loading as
> soon as the user switches to the browser. It starts only from a user action (opening a terminal or
> forwarding a port) while the app is in the foreground, only if the in-app setting "Keep the
> terminal connected in the background" is on (Settings → Notifications and background), always
> shows an ongoing notification with the number of connected terminals and forwarded ports and a
> "Disconnect all" / "Close all" action, and stops by itself when the last terminal is closed and the
> last port forward is closed (by the user, from the notification, or automatically after the
> user's idle limit without connections). It does not run at boot and does not collect data. The
> service itself does no periodic work: agent and CI notifications are checked by WorkManager, not
> by this service. The only recurring activity while it runs belongs to the open port forwards:
> once a minute Argos checks whether they are still open (to stop the service with the last one),
> reopens one whose SSH connection dropped, and refreshes a small file on the user's own server that
> lists the open forwards, over the SSH connection the user already opened.

Versión en español (por si el formulario o el revisor la piden):

> Argos es un cliente SSH para los servidores del propio usuario. Este servicio mantiene vivo el
> proceso con la app en segundo plano mientras el usuario tiene abierto un terminal interactivo (una
> conexión SSH viva enganchada a tmux) o un reenvío de puerto local que abrió para ver, en el
> navegador del teléfono, una web que corre en su propio servidor (por ejemplo un servidor de
> desarrollo en el puerto 3000). Sin él, los comandos largos se interrumpen y la página reenviada deja
> de cargar en cuanto el usuario cambia al navegador. Solo arranca por una acción del usuario (abrir
> un terminal o reenviar un puerto) con la app en primer plano, solo si el ajuste «Mantener el
> terminal conectado en segundo plano» está activado (Ajustes → Avisos y segundo plano), siempre
> muestra una notificación permanente con el número de terminales conectados y de puertos
> reenviados y la acción «Desconectar todo» / «Cerrar todo», y se detiene solo al cerrar el último
> terminal y el último reenvío (el usuario, desde la notificación o automáticamente tras el límite
> de inactividad que elige el usuario). No arranca al iniciar el dispositivo y no recoge datos. El
> servicio en sí no hace trabajo periódico: los avisos de agentes y de CI los revisa WorkManager, no
> este servicio. Lo único recurrente mientras corre es de los reenvíos abiertos: una vez por minuto
> Argos comprueba si siguen abiertos (para pararse con el último), reabre el que perdió su conexión
> SSH y actualiza en el servidor del usuario un archivo pequeño con los reenvíos abiertos, por la
> conexión SSH que el usuario ya abrió.

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
- **WorkManager / trabajos programados**: no mantienen un socket abierto, un PTY interactivo ni un
  puerto local escuchando para el navegador; Argos ya usa WorkManager para lo que sí es periódico
  (comprobar agentes y CI cada 15 min como mínimo).
- **`connectedDevice` para los reenvíos**: el reenvío escucha en `127.0.0.1` del propio teléfono y va
  a un servidor de Internet del usuario; no hay ningún dispositivo externo.

## Cómo lo ve el usuario

1. Abre un terminal (pestaña Terminal de un proyecto o una sesión suelta): al adjuntarse el primero
   aparece la notificación permanente **«Argos mantiene 1 terminal conectado»** (canal «Terminal en
   segundo plano») con el botón **«Desconectar todo»**.
2. Cambia a otra app: la conexión sigue; al volver, el terminal está igual.
3. «Desconectar todo» cierra las conexiones (las sesiones tmux siguen vivas en el servidor) y la
   notificación desaparece. También desaparece al cerrar el último terminal.
4. Reenvía un puerto (pantalla «Puertos» → «Reenviar y abrir»): el navegador abre la web y la
   notificación pasa a **«Argos mantiene 1 puerto reenviado»** (o «1 terminal conectado · 1 puerto
   reenviado») con **«Cerrar todo»**. La web sigue cargando mientras el navegador está delante; la
   notificación desaparece al cerrar el último reenvío.
5. Se puede desactivar en Ajustes (icono de engranaje de la pantalla Servidores) → **Avisos y segundo
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
| 50–65 s | Proyecto → menú → «Puertos» → «Reenviar y abrir» en un puerto web: se abre el navegador con la web; bajar la cortina: «Argos mantiene 1 puerto reenviado» con «Cerrar todo». Navegar por la web unos segundos | «La web del servidor sigue cargando en el navegador» |
| 65–75 s | Pulsar «Cerrar todo»: la notificación desaparece y la web deja de cargar | «El usuario cierra el reenvío cuando quiere» |

Pega el enlace del vídeo en el formulario junto a la descripción. **El vídeo publicado
(2026-11-08) solo muestra el terminal:** al enviar esta versión hay que grabar y subir uno nuevo con
las dos últimas filas, porque la descripción ahora incluye los reenvíos de puertos.
