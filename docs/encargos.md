# Encargos: cola, tareas programadas y «Pedir a Claude que lo arregle»

Diseño del motor común de las funciones 5 (cola de encargos), 6 (tareas programadas) y 8
(CI y PR → Claude). Decisiones del usuario del 2026-11-26; lo que aquí se llama
«por defecto» lo decidió el asistente y se puede cambiar.

## Idea

Un **encargo** es un prompt para Claude en un proyecto, con instrucciones de cómo
ejecutarlo. Los encargos de un proyecto forman una **cola**: se ejecutan de uno en uno y en
orden. Lo que cambia entre las funciones es solo **quién los crea**:

| Función | Quién crea el encargo | Cuándo empieza |
|---|---|---|
| 5. Cola | El usuario («cuando termine esto, haz esto otro») | Al quedar Claude libre en el proyecto |
| 6. Programadas | El despachador, según `schedules` | A su hora (con frenos) |
| 8. CI/PR | El botón de la bandeja | Como 5 |

El siguiente encargo lo lanza **el servidor**, no la app: así la cola avanza con el Mac
cerrado o el iPhone dormido.

## Dónde se ejecuta

- **Terminal** (por defecto en la cola y en CI/PR): el Claude interactivo del proyecto en
  tmux. El despachador le pega el prompt con *bracketed paste* (`tmux load-buffer` +
  `paste-buffer -p`) y Enter. Contexto por encargo: «misma conversación» o «limpio»
  (`/clear` antes).
- **Agente persistente** (tareas programadas, opcional en la cola): `claude` headless de
  `PersistentAgentScript`, en un **worktree y rama propios** por ejecución.

## Datos en el servidor (aditivos, compartidos por Mac, iPhone/iPad y Android)

```
~/.config/argos/tasks/
  dispatch.sh                 # el despachador (POSIX sh, golden)
  <proyecto>/                 # clave = ruta del proyecto como la codifica Claude Code
    <seq>-<id>/               # seq de 6 dígitos: orden de la cola
      prompt                  # texto del encargo, tal cual
      meta                    # clave=valor, una por línea (ver abajo)
      state                   # pending | running | done | failed | paused | cancelled
      reason                  # por qué se pausó o falló (una línea)
      started, finished       # epoch
      pane                    # panel tmux donde corre (modo terminal)
```

`meta` (claves desconocidas se ignoran):

```
v=1
title=<primera línea del prompt, recortada>
source=manual|schedule|ci|review|issue
ref=<run id, url del comentario…>
target=terminal|agent
session=<sesión tmux del proyecto>        # target=terminal
window=<índice de la ventana con Claude>   # target=terminal (la app propone la libre)
context=same|clear
dir=<ruta absoluta del proyecto>
commit=0|1                                # commit al terminar
push=0|1                                  # push a main (solo si pasan los tests en tareas programadas)
attempts=<n>                              # CI: intentos hasta verde
max_minutes=<n>                           # tiempo máximo
```

Un archivo por encargo y un cerrojo por proyecto (`mkdir lock`) evitan que la app (al
encolar) y el despachador (al avanzar) se pisen. El texto del prompt nunca pasa por la
línea de comandos (`ps`): se sube por SFTP.

## El despachador

`sh ~/.config/argos/tasks/dispatch.sh <evento> [panel]`, siempre con plazo y saliendo
con 0:

- `tick`: lo llama la app al encolar y (función 6) el temporizador cada minuto. Para cada
  proyecto sin encargo `running`, toma el primer `pending` y lo lanza si pasa los frenos.
- `stop <panel>` (hook `Stop` de Claude): el encargo `running` de ese panel pasa a `done`
  (commit/push si toca) y se lanza el siguiente del proyecto.
- `failure <panel>` (hook `StopFailure`): pasa a `paused` con el motivo. Si fue el límite
  de uso, se reanuda solo cuando se reinicia la ventana (lee `claude-limits.json`).

Los hooks de Argos ganan entradas nuevas para `Stop` y `StopFailure` que llaman al
despachador solo si existe (`[ -f … ] &&`): versiones viejas de los hooks no se rompen y
servidores sin cola no hacen nada.

### Frenos antes de lanzar

1. Claude libre en el panel: `@argos_claude` en `done` o sin valor y sin «esc to
   interrupt» ni «Waiting for … background» en pantalla (mismo criterio que el sondeo).
2. Límite de uso < 85 % (si la statusline de límites está puesta).
3. Memoria del servidor fuera de aviso (mismo umbral que la app: < 20 % libre → espera).
4. Tareas programadas: proyecto sin Claude trabajando en ese momento; tiempo máximo.

Un encargo que no pasa los frenos sigue `pending` y se reintenta en el siguiente `tick`.

## Puntos de restauración

Cada encargo es un turno de Claude: con los puntos de restauración activados en el
proyecto, el hook `UserPromptSubmit` ya guarda uno antes. Al encolar el primer encargo de
un proyecto sin puntos de restauración, la app ofrece activarlos.

## La app

- Proyecto → «Encargos»: lista (pendientes, en curso, hechos), añadir (prompt, contexto,
  commit), cancelar, reordenar y reintentar uno pausado o fallido.
- Insignia «3 en cola» en la fila del proyecto (sección nueva `tasks` del sondeo, solo
  recuento y estados).
- Bandeja «Te necesita»: encargo pausado o fallido; resumen al vaciarse la cola.

## Fases

1. **Motor + cola en terminal** (Mac e iPhone/iPad): `dispatch.sh`, hooks, encolar,
   sondeo, pantalla de encargos, bandeja. Android lo porta un subagente.
2. **Agentes persistentes y worktrees** (hecho): encargos con `target=agent`. Al encolar, la
   app deja `launch.sh` (crea el worktree `<proyecto>-encargo-<id>` con la rama
   `argos/encargo-<id>` y arranca claude headless con el modo de permisos de Ajustes) y
   `send.sh` (entrega el encargo por la FIFO). El hook `Stop` de un agente headless no
   tiene `$TMUX_PANE`: el despachador lo reconoce por el `session_id` del JSON del hook.
3. **Tareas programadas** (hecho): `tasks/schedules/<id>/` con `config` y plantillas
   (`launch.tpl` con un id de agente centinela y los datos del agente en `$ARGOS_META_B64`,
   `meta.tpl`/`task.tpl`/`send.tpl`/`stop.tpl` con huecos `@@RUN@@` y `@@NOW@@`). El
   temporizador (launchd en macOS, systemd --user en Linux, cron si no) llama a `tick`
   cada minuto; `tick` crea la ejecución si es su día y ya pasó su hora (hasta 12 h tarde,
   una vez), salvo con Claude trabajando en el proyecto, y corta las que pasan de su
   tiempo máximo. Push a main desde el worktree (`HEAD:main`) solo si pasa la
   comprobación. Pendiente: el resumen de la ejecución anterior en el encargo.
4. **CI/PR → Claude**: botón en la bandeja (CI fallida con referencia + extracto, revisiones
   de PR, bots, comentarios en commits, issues asignados), vigilar hasta verde con 3
   intentos como máximo.

## Seguridad

- El servidor no es de fiar: la app valida lo que lee de `tasks/` (estados conocidos,
  tamaños acotados) como hace con el resto de archivos.
- Nada de `eval`: el prompt va a tmux por un búfer, nunca se interpreta en el shell.
- El modo de permisos de un encargo nunca es más permisivo que el del Claude que lo recibe;
  en tareas programadas (agente persistente) se elige al crear la tarea y se guarda en el
  dispositivo, no en el servidor (como `AgentPermissionPreferences`).
