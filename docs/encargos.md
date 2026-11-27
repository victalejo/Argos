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
5. Presupuesto del proyecto (si tiene; ver abajo).

Un encargo que no pasa los frenos sigue `pending` y se reintenta en el siguiente `tick`.

### Revisor automático antes del push

La app escribe `push=0` y `review_push=1` (también en la plantilla de las tareas
programadas): un despachador viejo, que reinstala una app publicada, no sube nada; el nuevo
sube con `review_push=1` (o con un `push=1` anterior) y solo tras revisar. Tras el commit y
la comprobación (`check=`), el hook `Stop` lanza `dispatch.sh finish` desacoplado
(`setsid`/`nohup`) y este pasa el encargo por `claude -p --model claude-sonnet-5-5` (alias
`sonnet` con opciones más viejas si el CLI no lo acepta) en la carpeta del encargo:
contexto limpio (`--no-session-persistence`), solo `Read,Grep,Glob` (`--permission-mode
dontAsk`, o `plan` en la reserva; nunca `bypassPermissions`), con plazo
(`ARGOS_REVIEW_SECONDS`, 600 s).

Al empezar fija en `review.head` el commit revisado y el destino del push (en agente,
`origin refs/heads/main`; en la terminal, el remoto y la rama de seguimiento de la rama
actual). Recibe por stdin las instrucciones, el prompt del encargo (y el original si es un
arreglo: `prompt.original`), `git diff --stat` y el diff `merge-base(head, origin/main |
@{u})..head` con `--text --no-ext-diff --no-textconv`, recortado a `ARGOS_REVIEW_MAX_DIFF`
(150 KB, y se le dice). Debe responder un JSON
`{"verdict":"approve|block","summary","findings":[{severity,category,file,line,message}]}`.

- Aprobado y sin `high`/`critical`: se sube EXACTAMENTE `review.head` (`git push <remoto>
  <sha>:<rama>`, sin forzar: falla si no es fast-forward), nunca lo que llegó después a la
  rama. `review.json` queda como registro (`reviewed` en el listado).
- `block` o algún `high`/`critical`: `state=paused`, `reason=review`, sin push; el commit
  queda en su rama. Informe en `review.json` (y la respuesta tal cual en `review.md`). Si
  el informe pasa de 12 000 bytes se guarda uno reducido con `"truncated":true`.
- `reason=review-inconclusive` (`review.json` con `verdict=inconclusive` y `cause`; nunca
  cuenta como aprobado): `timeout`, `invalid` (JSON roto), `no-claude`, `error`, `diff`
  (`git diff` falló), `empty` (nada que revisar), `truncated` (aprobado sin ver todo el
  diff) y `held` (contiene el commit de `review.head` de otro encargo del proyecto que el
  revisor tiene bloqueado). Una revisión que se queda en `reviewing` más de `2 × plazo +
  120 s` (murió el proceso) la pasa `tick` a `timeout`.

En la terminal, un encargo con push no se lanza mientras otro de la misma sesión y ventana
esté revisándose o bloqueado (`reason=review-wait`): trabajaría sobre ese commit.

Salidas (app): `dispatch.sh push-anyway <proyecto> <encargo>` (sube `review.head` en
segundo plano salvo `held`; `reason=pushing` mientras, `pushed_anyway` con la fecha) y
«Pedir a Claude que lo arregle»: un encargo nuevo con `fixes=<encargo>` en el mismo
agente/worktree/rama (o la misma ventana), commit, push y la misma comprobación; al
encolarlo, el bloqueado pasa a `done` con `reason=review-fixing`. Si el arreglo no cambia
nada, se revisa y sube igualmente lo que quedó pendiente en la rama. `retry` no repite un
encargo bloqueado por el revisor. El sondeo trae los bloqueados (sección `reviews`) para la
bandeja «Te necesita» del Mac. Motivos, claves y archivos nuevos: las versiones publicadas
los ignoran (motivo desconocido = sin texto).

### Presupuesto por proyecto (freno 5)

Dos topes opcionales y combinables por proyecto (decisión del 2026-11-26), en
`~/.config/argos/budgets/<proyecto>` (clave = la de `tasks/`), `clave=valor` legible por sh y
aditivo (claves desconocidas se ignoran; la app no pisa un `v` más nuevo):

```
v=1
window_pct=20        # % de la ventana de 5 h que puede gastar el proyecto (1…100)
daily_usd=5.00       # coste equivalente máximo al día (USD)
```

Va fuera de `tasks/` (y no en `projects.json`) para que el despachador no lo tome por un
proyecto y no toque un archivo que comparten otras funciones.

- **Ventana de 5 h**: lo gastado por el proyecto en la ventana actual se estima como
  `used_percentage global × (coste del proyecto / coste de todos los proyectos)`, sumando las
  horas del índice de uso (`usage/ledger.tsv`) desde `resets_at − 5 h` (redondeado a la hora:
  el índice va por horas, así que puede contar un poco de antes). Sin la statusline de
  límites no se puede evaluar: no frena y la app lo dice.
- **Máximo al día**: coste equivalente (`ClaudePricing`) del proyecto desde la medianoche
  del servidor (hora local del servidor, también redondeada a la hora).
- `budget_ok <proyecto> <encargo>` (en `ClaudeBudgetScript`, incluido en `dispatch.sh`) se
  llama justo antes de lanzar el primer `pending` (después de la barrera del revisor, `review-wait`), así que vale para la cola y para las
  ejecuciones de tareas programadas. Pone al día el índice una vez por ejecución (con
  `timeout 20` si existe; si no, en segundo plano, y usa lo que haya; no lo relanza si se
  actualizó hace menos de un minuto). Si el proyecto pasó un tope, el encargo sigue
  `pending` con motivo `budget` (las versiones publicadas ignoran motivos que no conocen) y
  se anota `budgets/<proyecto>.blocked` (`v=1 kind=window|daily used= cap= until= since=`,
  `since` se conserva mientras dure el mismo bloqueo). En cuanto deja de pasarlo (nueva
  ventana, nuevo día o tope cambiado) el `tick` lo lanza y borra el bloqueo.
- Un encargo ya en marcha no se corta; lo lanzado a mano en el terminal no pasa por aquí.
- La app lee los bloqueos en la sección `budget` del sondeo: elemento informativo en la
  bandeja «Te necesita» (Mac) mientras dure y una notificación local por bloqueo (Mac y
  iPhone/iPad; `ClaudeLimitAlertLedger` recuerda los ya avisados). Guardar el presupuesto
  pone al día el despachador y el índice, borra el bloqueo y lanza un `tick`.
- Android aún no lo porta (goldens en `pendingAndroidPort`): sus encargos se frenan igual
  porque frena el servidor, pero no ve el motivo ni avisa.

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
