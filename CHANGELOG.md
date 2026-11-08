# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es/1.1.0/).
El detalle por commit vive en el historial git (Conventional Commits):
`git log --oneline`.

## [Unreleased]

## [1.7.16] - 2026-11-08

### Añadido
- **Conceder `~/.ssh` desde el error de conexión** en la versión de Mac App Store: un botón
  abre el panel para dar acceso y reconecta al confirmar, sin pasar por Ajustes.

### Corregido
- **Seleccionar y copiar texto en el terminal del Mac**: arrastrar o hacer doble/triple clic
  selecciona y ⌘C copia, aunque tmux tenga el ratón activado. El clic simple sigue llegando a
  tmux y ⌥ Option + arrastrar usa la selección de tmux (más allá de lo visible).

## [1.7.15] - 2026-11-08

### Añadido
- **Modo de permisos de los agentes configurable** en Ajustes y por proyecto (Mac, iPhone y
  iPad). Es «todos los permisos» por defecto; con root, los agentes preguntan.

### Cambiado
- **Los agentes nuevos de iPhone y iPad arrancan con todos los permisos**, como en el Mac: ya
  no preguntan antes de cada acción. Para que pregunten, cámbialo en Ajustes o en el proyecto.
  Los agentes que ya existían conservan su modo.

### Corregido
- **Menos avisos del llavero al abrir el Agente en el Mac**: comprobar si hay token ya no lo
  descifra y, con sesión de Claude iniciada en el servidor, no se lee. Si dependes del token
  guardado, macOS volverá a pedir permiso una vez tras cada actualización: pulsa «Permitir
  siempre».

### Seguridad
- El token de Claude del agente del Mac viaja por stdin: en la línea de comandos lo podía
  leer cualquier usuario del servidor.
- Las subidas a `/tmp` usan nombre aleatorio, apertura exclusiva y permisos 0600.
- Reanudar un agente persistente que actúa sin preguntar pide confirmación: su modo se guarda
  en el servidor, donde el propio agente podría cambiarlo.
- Un modo de permisos guardado que no se reconoce pregunta cada acción en vez de dar más
  permisos.

## [1.7.14] - 2026-11-07

### Corregido
- **Modo Agente del iPhone/iPad con servidores zsh** (p. ej. un Mac): fallaba con «No se
  pudieron leer los agentes … no matches found». Los scripts del agente persistente, sus
  avisos y la detección de agentes instalados se ejecutan ahora siempre con `sh`.

## [1.7.13] - 2026-11-07

### Corregido
- **Sin tráfico SSH con el Mac dormido**: mientras el Mac está en reposo, Argos pausa el
  keep-alive, el sondeo de ventanas y la reconexión automática del terminal. Al despertar
  comprueba la conexión enseguida y, si el terminal cayó, se reconecta solo. Cambiar a otra
  app no pausa nada (el keep-alive sigue evitando el «terminal congelado» al volver).
  Gracias a **Kevin Jovy ([@AloreBB](https://github.com/AloreBB))**, que detectó el problema
  y propuso la solución en la PR #2.

## [1.7.12] - 2026-11-07

### Añadido
- **Pestañas del terminal renovadas (Mac, iPhone y iPad)**: `>_ 1`, `>_ 2` para las
  ventanas normales y, si corre un agente, su icono y nombre (la mascota de Claude Code,
  Codex o Grok).
- **Menú «+»**: abre un terminal o lanza Claude Code, Codex o Grok en una ventana nueva,
  en la carpeta del proyecto; los que no están instalados en el servidor salen atenuados.
- **Atajos de pestañas** (Mac y iPad con teclado): ⌘T nueva ventana (o conversación en
  Agente), ⌘W cerrar, ⌘1…⌘9 ir a una pestaña, ⌘⇧[ / ⌘⇧] anterior/siguiente y ⌘⌥1…3
  lanzar un agente. En el Mac viven en el nuevo menú «Pestañas».
- **Cerrar con cuidado**: una ventana con solo el shell se cierra directamente; si corre
  algo, se pide confirmación; la última ventana nunca se cierra (cerraría la sesión).
- **Tarjeta del terminal**: cabecera con lo que corre y la carpeta; barra inferior con
  servidor · rama git · agentes activos (Mac e iPad).
- **Dispositivos autorizados**: en el Mac, menú del servidor → «Dispositivos autorizados…»
  lista los iPhone/iPad con acceso por «Enviar al iPhone» (fecha y huella de su clave) y
  permite revocar cada uno, p. ej. si pierdes el teléfono. Las claves nuevas llevan la
  fecha en su comentario (`argos-iphone-AAAAMMDD-…`).

## [1.7.11] - 2026-11-07

### Añadido
- **Enviar un servidor al iPhone por QR**: en el Mac, menú del servidor → «Enviar al
  iPhone…». Argos crea una clave Ed25519 solo para ese iPhone, la añade al
  `~/.ssh/authorized_keys` del servidor y muestra un QR que el iPhone acepta durante 5
  minutos (con la huella de host key ya verificada). En el iPhone se escanea desde
  Servidores o con la cámara del sistema. El código contiene la clave del iPhone: si
  alguien más lo vio, «Cancelar» la retira del servidor. La clave del Mac nunca sale de él.

### Seguridad
- Un código o enlace `argos://` nunca puede cambiar la identidad (host key) de un servidor
  que el iPhone ya conoce: si no coincide, se avisa y no se añade.

## [1.7.10] - 2026-11-07

### Añadido
- **Cerrar ventanas tmux** desde la barra de pestañas: una «×» en la pestaña activa o al
  pasar el ratón, y «Cerrar ventana…» en el menú contextual, con confirmación. No se
  ofrece en la última ventana (cerraría la sesión entera).

## [1.7.9] - 2026-11-06

### Corregido
- **«Enviar al servidor» decía «Este Mac no tiene la copia»** aunque el proyecto estuviera
  en este Mac: cualquier fallo al leer el registro local del envío se ocultaba. Ahora la
  hoja muestra la causa real (y la registra en el log) y avisa aparte si la carpeta de la
  copia local se movió o se borró.

### Interno
- Nueva variante **Mac App Store** (`ArgosAppStore`) con las mismas funciones; el canal
  GitHub + Sparkle no cambia.

## [1.7.8] - 2026-11-05

### Añadido
- **Filtro por estado** bajo el buscador de proyectos, con el número de cada uno:
  Abiertas (terminal abierto en Argos), Dormidas (corren sin nadie conectado), Detenidas
  (sin sesión en el servidor), En el Mac (enviadas al Mac) y Segundo plano (abiertas en
  otro cliente). Se combina con la búsqueda; pulsar el filtro activo vuelve a «Todos».

## [1.7.7] - 2026-11-04

### Corregido
- **«Abrir en Terminal con Claude Code» no encontraba la conversación** cuando la copia del
  Mac está en otra ruta que en el servidor (p. ej. `~/Desarrollo/entrelingo/revib-agent`
  frente a `~/Desarrollo/revib-agent`). Ahora busca en las dos rutas, trae la más reciente a
  la carpeta local y la reanuda.

## [1.7.6] - 2026-11-04

### Mejorado
- **«Abrir en Terminal con Claude Code» retoma la conversación**: en la copia local de un
  proyecto, Argos reanuda la conversación más reciente de esa carpeta por su ID
  (`claude --dangerously-skip-permissions --resume <id>`), o arranca una nueva si no hay.
  Funciona aunque la conversación se empezara con otra cuenta de Claude (el selector de
  `--resume` no la mostraba).

## [1.7.5] - 2026-11-04

### Cambiado
- **Agente con todos los permisos**: las conversaciones nuevas del panel Agente arrancan en
  modo `bypassPermissions`, así que Claude ejecuta herramientas (Bash, ediciones…) sin pedir
  aprobación.

### Corregido
- **«No se pudo preparar el agente» (NIOSSHError)** con varios proyectos abiertos: el
  servidor SSH limita a 10 los canales por conexión (`MaxSessions`) y Argos los metía todos
  en una sola. Ahora cada terminal y cada conversación del agente usan su propia conexión.
- Los enlaces dentro de un PDF ya no se abren sin control al verlo en Archivos.

## [1.7.4] - 2026-11-03

### Añadido
- **Ver PDFs** en la pestaña Archivos (PDFKit: desplazamiento continuo y texto seleccionable).
- **Descargar al Mac** cualquier archivo del proyecto: botón en la cabecera del visor, clic
  derecho en el árbol o desde la vista de binario. Guarda en Descargas por defecto y avisa
  con «Abrir» / «Mostrar en Finder».

## [1.7.3] - 2026-11-03

### Mejorado
- **Envíos en segundo plano**: «Enviar al Mac» y «Enviar al servidor» ya no bloquean Argos.
  Con «Seguir en segundo plano» la copia continúa mientras trabajas; la fila del proyecto
  muestra el progreso (y el resultado al terminar) y reabre la ventana del envío al pulsarla.
  Si termina con Argos en segundo plano, llega una notificación.
- **Grupos más claros**: el menú del campo Grupo ofrece «Nuevo grupo…» y «Sin grupo», y
  una etiqueta «Nuevo» avisa cuando el nombre escrito creará un grupo.

### Añadido
- **Crear carpeta** en el selector de carpetas del servidor («Nueva carpeta»): la crea
  dentro de la carpeta actual y entra en ella, lista para usarla en el proyecto.

## [1.7.2] - 2026-10-31

### Añadido
- **Abrir en Terminal con Claude Code**: tras «Enviar al Mac» (y desde el menú del proyecto
  que está en este Mac) abre Terminal en la carpeta del proyecto y arranca `claude`.

### Mejorado
- Si la carpeta del proyecto está vacía en el servidor, «Enviar al Mac» lo dice claramente.

## [1.7.1] - 2026-10-31

### Corregido
- **Enviar al servidor** ya no vuelve a subir los enlaces simbólicos que no cambiaron.

## [1.7.0] - 2026-10-31

### Mejorado
- Nueva identidad visual adaptable a los modos claro y oscuro, con navegación de proyectos
  más clara, búsqueda siempre visible y estados de conexión con texto.
- Formularios guiados, búsqueda rápida con ayuda de teclado y acciones más accesibles.
- Paneles de terminal, archivos y agente renovados; animaciones sutiles que respetan
  Reducir movimiento, y acción de abrir proyecto visible antes de los detalles.
- Ajustes de apariencia de la aplicación y vista previa del tema y tamaño del terminal.
- El monitor avisa cuando muestra datos anteriores tras un fallo de actualización.

## [1.6.0] - 2026-10-30

### Añadido
- **Enviar al Mac**: clic derecho en un proyecto → copia su carpeta del servidor a este Mac para
  trabajar en un dispositivo real (incluye `.git` y `.env`; no `node_modules`, builds ni cachés).
  Se marca "en el Mac" (💻) para todos tus Macs y puede detener la sesión del servidor.
- **Enviar al servidor**: devuelve los cambios (sube lo modificado, borra lo borrado, conserva lo
  que cambió en el servidor) y detecta conflictos para que elijas qué versión gana.

### Seguridad
- La sincronización trata al servidor como no confiable: nunca escribe fuera de la carpeta del
  proyecto (rutas y enlaces simbólicos validados), no trae hooks de git y reconstruye
  `.git/config` con una lista blanca (remotos, ramas, usuario).

## [1.5.0] - 2026-10-30

### Añadido
- **Agente de Claude Code integrado con el proyecto**: trabaja en la carpeta del proyecto (sin
  elegir carpetas) y arranca solo al abrir la pestaña Agente.
- **Varias conversaciones en pestañas** por proyecto (+ o ⌘T), con el título de su primer mensaje.
- **Login guiado**: abre la página de autorización en tu navegador, pegas el código en un campo
  y se verifica solo. Si Claude no está instalado en el servidor, Argos lo instala.
- Interfaz renovada: respuestas en Markdown, herramientas con icono y resultados plegables,
  indicador de trabajo y tarjeta de permisos.

### Corregido
- Los agentes ya no dejan procesos `claude` huérfanos en el servidor: al cerrar una conversación
  o detener el proyecto se detiene su proceso.
- El agente no arranca si el servidor tiene poca memoria libre (avisa y permite forzarlo).

### Seguridad
- Un permiso nunca se aprueba con ⏎ por accidente: requiere clic o ⌘⏎.

## [1.4.0] - 2026-10-30

### Añadido
- **Pestaña Archivos** en cada proyecto (también detenido) y sesión suelta: árbol de la carpeta
  del servidor con **iconos por tipo de carpeta** (src, docs, tests, .github, public…) y archivo,
  visor de **Markdown renderizado** (con modo Fuente), **código resaltado** con números de línea,
  imágenes, y **⌘P** para buscar archivos por nombre. Solo lectura.
- Oculta por defecto archivos ocultos y carpetas generadas (`node_modules`, `.git`, `dist`…).

### Seguridad
- El visor nunca sale de la carpeta del proyecto (los symlinks se resuelven y se comprueban).
- El Markdown no carga imágenes remotas y solo abre enlaces http/https/mailto tras confirmar.

## [1.3.0] - 2026-10-30

### Añadido
- **Proyectos**: cada sesión pasa a ser un proyecto anclado a una carpeta del servidor
  (guardados en `~/.config/argos/projects.json`, compartidos entre Macs).
  - **Abrir** un proyecto detenido crea su sesión en la carpeta y lanza el comando de
    arranque (por defecto `cc --continue`; configurable en Ajustes → Proyectos y por proyecto).
  - **Desconectar** (sigue corriendo) o **Detener** (cierra la sesión y libera memoria; el
    proyecto se conserva). **Editar** y **Quitar** (no toca archivos).
  - **Importar sesiones como proyectos** (con la carpeta en la que están) y "Convertir en
    proyecto" para sesiones sueltas.
  - **Detener proyectos en segundo plano** desde el menú del servidor (⋯).

### Corregido
- "Matar" y "Renombrar" usaban coincidencia por prefijo de tmux y podían actuar sobre otra
  sesión cuyo nombre empezara igual; ahora usan el nombre exacto.

## [1.2.11] - 2026-10-30

### Añadido
- **Grupos de sesiones colapsables**: clic en el encabezado del grupo. Se recuerda por
  servidor y grupo; colapsado muestra cuántas sesiones tiene y el aviso de Claude más
  urgente. Con búsqueda activa los grupos se expanden.

## [1.2.10] - 2026-10-30

### Añadido
- **Indicador de Claude Code** por sesión (barra lateral) y por ventana (pestañas):
  esperando tu respuesta, terminó o trabajando, más notificación de macOS con la app en
  segundo plano. Se activa por servidor: clic derecho → "Activar indicador de Claude
  Code…" (añade hooks a `~/.claude/settings.json` conservando los existentes, con copia
  `.argos-backup` y permisos 600).

## [1.2.9] - 2026-10-30

### Seguridad
- **Monitor de recursos más robusto**: valores anómalos del servidor (infinitos, negativos o
  enormes) se rechazan con un aviso en vez de cerrar la app.

## [1.2.8] - 2026-10-30

### Añadido
- **Monitor de recursos del servidor** (botón de la toolbar o ⌥⌘I): CPU, memoria, swap,
  disco, carga, uptime y los procesos que más CPU consumen del servidor activo, refrescado
  cada 3 s mientras está abierto. Requiere servidor Linux.

## [1.2.7] - 2026-10-30

### Añadido
- **Nueva ventana en el mismo directorio**: el botón "+" de la barra de ventanas abre la
  ventana en el directorio del panel activo (como `prefix c`), no en `~`.
- **Renombrar ventanas**: clic derecho en una pestaña → "Renombrar…".
- **Color por ventana**: clic derecho → "Color". Se guarda en tmux (`@argos_color`), así
  que persiste en el servidor y se ve desde cualquier Mac.

## [1.2.6] - 2026-10-30

### Corregido
- **El terminal mostraba `malloc(): invalid size (unsorted)` y no abría la sesión**: durante
  el layout, el terminal reportaba tamaños transitorios (p. ej. 2x1) que se enviaban al
  servidor; zsh 5.9 corrompe su memoria con terminales tan pequeños y abortaba antes de
  `tmux attach`. Ahora se ignoran tamaños menores de 20x5 y el PTY arranca en 80x24 si aún
  no hay un tamaño utilizable.

## [1.2.5] - 2026-06-20

### Corregido
- **El agente se quedaba en "Conectando…" para siempre** (deadlock): `claude` en modo
  stream-json no emite el evento `init` hasta recibir el primer mensaje, pero la UI
  bloqueaba el input hasta "conectar". Ahora la sesión está **lista para escribir desde el
  arranque** (con una pista "Escribe tu primer mensaje para empezar").

## [1.2.4] - 2026-06-20

### Añadido
- **Selector visual de carpeta del servidor**: botón "Elegir…" que abre un navegador de
  directorios remotos (entras/sales de carpetas con clics) en vez de teclear la ruta de
  memoria. Empieza en la última carpeta usada.
- **Recuerda la última carpeta por servidor**: el directorio de trabajo se precarga con el
  último que usaste en ese servidor.
- **Validación del directorio de trabajo** antes de arrancar el agente: si la ruta no
  existe en el servidor, el formulario lo avisa ("El directorio 'X' no existe…") en vez de
  arrancar y fallar con `cd: No such file or directory`.

## [1.2.3] - 2026-06-20

### Corregido
- **Detección de `claude` en el servidor mucho más robusta**: antes el badge podía decir
  "no instalado" aunque `claude` estuviera (si el server usa otra shell o el perfil de login
  imprime texto antes de la ruta). Ahora prueba la shell de login del usuario y varias más,
  comprueba rutas de instalación conocidas (`~/.local/bin`, `~/.claude/local`, …) y descarta
  el ruido del perfil al parsear la ruta.
- **Estado de autenticación tolerante a ruido**: el JSON de `claude auth status` se extrae
  aunque el servidor imprima avisos alrededor.

## [1.2.2] - 2026-06-20

### Corregido
- **Agente: `cd` al directorio `~` fallaba** (se entrecomillaba y `~` no se expande entre
  comillas). Ahora `~` y `~/...` se traducen a `"$HOME"`, así el agente arranca en el home.
- **Errores del agente ahora muestran el stderr real de `claude`** (p. ej. "not logged in",
  opción desconocida) en vez del críptico `NIOCore.ChannelError`.

### Añadido
- **Aviso "(alfa)"** en la pestaña Agente: es una función experimental que puede fallar o
  cambiar.

### Añadido
- **Botón "Iniciar sesión en el servidor"** en el panel de Agente: abre `claude auth
  login --claudeai` en un terminal embebido para autenticar el servidor con tu
  suscripción (sin copiar/pegar tokens). El panel también **detecta y muestra** si el
  servidor ya tiene sesión de Claude (`claude auth status`) y de qué tipo (p. ej. `max`).

### Cambiado
- **Panel de Agente: token opcional**. Ya no obliga a pegar un token. Si el servidor
  tiene sesión de `claude` (botón de login o `claude auth login`), el agente funciona
  sin token. El token de `claude setup-token` queda como alternativa avanzada.
- Se aclara en la UI que el agente usa **siempre tu suscripción, nunca la API**: el
  comando hace `env -u ANTHROPIC_API_KEY`, por lo que es imposible que facture contra la API.

## [1.2.0] - 2026-06-20

### Añadido
- **Panel de Claude Code (opción "Agente")**: nueva pestaña en la columna de detalle, junto
  al terminal tmux (que sigue siendo el modo por defecto). Ejecuta `claude` en el servidor
  remoto vía SSH y muestra la conversación como UI nativa: mensajes, llamadas a herramientas
  y **permisos con botones Permitir/Denegar** (estilo extensión de VS Code).
- **Autenticación con tu suscripción Plan Max** (sin API key): pega el token de
  `claude setup-token` una vez; se guarda en el Keychain y se usa en todos los servidores.
- **Multi-agente**: cada sesión mantiene su propio agente vivo aunque cambies de sesión o de
  modo.

## [1.1.0] - 2026-06-20

### Añadido
- **Zoom de fuente del terminal**: ⌘+ / ⌘− para ajustar el tamaño y ⌘0 para volver al
  original (acotado a 9–24 pt), desde el menú Visualización.
- **Probar conexión**: el formulario de servidor tiene un botón "Probar conexión" que
  conecta, autentica y ejecuta `whoami` con los datos tecleados (sin guardar), mostrando
  éxito (usuario remoto) o el error concreto. Evita guardar un servidor "a ciegas".
- **Enviar comando / broadcast**: envía un comando (vía `tmux send-keys`) a una o varias
  sesiones a la vez (p. ej. `git pull` a backend+frontend) sin teclear en cada terminal.
  Botón en la toolbar (⌥⌘K) y entrada en el menú contextual de cada sesión; el sheet
  permite elegir varias sesiones (agrupadas por servidor) y si pulsar Enter.
- **Gestión de paneles tmux**: menú "Panel" en la barra del terminal para dividir
  (derecha/abajo), navegar entre paneles (↑↓←→), hacer zoom y cerrar el panel activo
  (con confirmación; solo si la ventana tiene más de un panel), sin teclear el prefijo.
- **Agrupamiento de sesiones por prefijo**: la columna central agrupa las sesiones por el
  prefijo `grupo/nombre` (encabezados solo cuando hay grupos reales). Conecta la lógica
  `SessionGrouping`, que ya existía y estaba testeada pero la UI no usaba.
- **Atajos de teclado**: ⌘N (nueva sesión) y ⌘R (refrescar todo) en la columna de sesiones.
- **Reapertura donde lo dejaste**: el servidor seleccionado se recuerda entre arranques.
- **tmux no instalado**: la fila ahora muestra el comando de instalación copiable y un botón
  de "Reintentar".

### Cambiado
- **Feedback de errores que antes se tragaban**: los fallos de "Matar sesión" (y otras
  operaciones sin formulario) se muestran ahora en una alerta en vez de fallar en silencio.
- **Identidad de servidor cambiada (posible MitM)**: se presenta como un caso de seguridad
  con la acción "Olvidar host key y reintentar" junto al error, no como un fallo genérico.

### Rendimiento
- **Tope del pool de terminales (LRU)**: con muchas sesiones abiertas a la vez, el terminal
  menos usado se desengancha automáticamente (vuelve a "dormido" y se reconecta al instante
  al reabrirlo) en vez de mantener PTYs y scrollback creciendo sin límite.
- **Arranque perezoso**: al abrir la app ya no se conecta a TODOS los servidores a la vez;
  solo se carga el seleccionado (los demás se conectan al seleccionarlos o pulsar "Conectar").
- **Keepalive SSH**: un heartbeat mantiene viva la conexión idle (evita el "terminal
  congelado" al volver tras un rato) y detecta antes una caída en vez de al próximo uso.
- **Sondeo de ventanas adaptativo**: el polling de la barra de ventanas usa backoff (3→12s)
  y solo re-renderiza si hay cambios, en vez de un sondeo fijo cada 3s.

### Accesibilidad
- **VoiceOver**: las filas de servidor y de sesión, las pestañas de ventana y el cambiador
  rápido exponen etiquetas con nombre y estado (antes no había ningún modificador de
  accesibilidad).
- **Estado por forma además de color** (daltonismo): el indicador de cada sesión usa una
  forma distinta por estado (viva = punto, error = exclamación, adjunta por otro = persona,
  conectando = spinner, dormida = luna), no solo color.
- **Reducir movimiento**: el cambiador rápido (⌘K) respeta el ajuste del sistema.

### Seguridad
- **Sin servidor sembrado**: se elimina el servidor de desarrollo hardcodeado que viajaba en
  cada build; el primer arranque muestra la lista vacía con un botón para añadir.
- **Keychain más estricto**: las passphrases/contraseñas usan `WhenUnlocked` (no legibles con
  la pantalla bloqueada) y se marcan como no sincronizables (nunca a iCloud).
- **`servers.json` corrupto**: se respalda a un `.corrupt-<epoch>` antes de continuar, en vez
  de sobrescribirse de forma irreversible en el siguiente guardado.

### Interno
- **Concurrencia estricta (data-race safety)**: se activa `SWIFT_STRICT_CONCURRENCY: complete`
  para comprobar nuestro código. Los tipos no-Sendable de Citadel se reconocen con
  `@preconcurrency import`; queda una sola fricción conocida de AppKit (`NSEvent`), documentada.

### Pruebas / CI
- Tests de `SessionsViewModel` (con un `MockSSHService`), de `TOFUHostKeyValidator` y del
  arranque vacío/corrupto de `ServerStore`.
- CI publica la cobertura de líneas en el resumen del job (antes se recolectaba y se descartaba).
- El workflow de release corre la suite como gate y verifica que la versión del binario
  coincida con el tag antes de publicar.

## [1.0.8] - 2026-06-19

### Añadido
- **Cambiador rápido (⌘K)**: buscador difuso para saltar a cualquier sesión de cualquier
  servidor al instante (teclado o clic).
- **Ventanas de tmux**: barra sobre el terminal con las ventanas de la sesión (índice,
  nombre, paneles); clic para cambiar y **+** para crear una nueva.
- Menús **Acerca de Argos**, **Ajustes** (pestañas Terminal + Actualizaciones) y **Ayuda**
  (Documentación / Novedades / Reportar un problema) ahora funcionales.

### Cambiado
- **App en español**: los menús del sistema (Archivo, Edición, Visualización, Ventana,
  Ayuda…) y diálogos ahora se muestran en español.

## [1.0.7] - 2026-06-18

### Añadido
- **Icono de la app**: ojo "todo-vidente" con un prompt de terminal (`>_`) — guiño a
  Argos Panoptes. Reemplaza el icono genérico.

## [1.0.6] - 2026-06-18

### Añadido
- **Conexiones persistentes**: las sesiones abiertas mantienen su terminal vivo en un
  pool; volver a una sesión ya cargada es **instantáneo** (no se re-attacha cada vez).
- **Estado visual por sesión** (el puntito): 🟢 viva · 🟡 conectando · 🔴 error ·
  🔵 adjunta por otro cliente · 🌙 dormida. Menú contextual **"Desconectar (dormir)"**
  para liberar recursos.

## [1.0.5] - 2026-06-18

### Corregido
- La build ad-hoc no arrancaba con Sparkle embebido (Hardened Runtime rechazaba el
  framework por distinto Team ID). Añadido `disable-library-validation`. **v1.0.4 estaba
  rota; usa v1.0.5+.**

## [1.0.4] - 2026-06-18

### Cambiado
- **Actualizaciones OTA con [Sparkle](https://sparkle-project.org/)**: reemplaza el
  comprobador propio. Ahora descarga e instala el update dentro de la app ("Instalar y
  reiniciar") sin pasar por el navegador, evitando la cuarentena de Gatekeeper en cada
  versión. Firma EdDSA propia (sin cuenta Apple). El release publica un ZIP + `appcast.xml`
  firmado además del DMG.

## [1.0.3] - 2026-06-18

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
