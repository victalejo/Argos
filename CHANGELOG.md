# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es/1.1.0/).
El detalle por commit vive en el historial git (Conventional Commits):
`git log --oneline`.

## [Unreleased]

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
