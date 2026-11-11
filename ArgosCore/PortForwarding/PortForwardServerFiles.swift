//
//  PortForwardServerFiles.swift
//  ArgosCore
//
//  Lo que Argos deja en el SERVIDOR para que Claude sepa qué puertos hay (comandos puros):
//   - `~/.config/argos/forwards/<dispositivo>.tsv`: túneles abiertos por cada dispositivo
//     (Mac, iPhone, Android), con la hora del servidor de la última actualización.
//   - `~/.claude/skills/argos-puertos/SKILL.md`: skill que le dice a Claude cuándo usarla.
//   - `~/.claude/skills/argos-puertos/argos-ports`: su script (puertos en escucha y túneles).
//     Va DENTRO de la skill: si `~/.claude` se sincroniza entre equipos (p. ej. Syncthing),
//     viajan juntos y nunca queda una skill apuntando a un script que no existe.
//  Android genera byte a byte los mismos comandos (golden).
//

import Foundation
#if os(macOS)
import SystemConfiguration
#endif

/// Identidad de este dispositivo en los archivos del servidor.
enum PortForwardDevice {
    static let idKey = "portForwardDeviceID"

    /// Nombre visible («Mac de Santiago», «iPhone»). En el Mac, el nombre del equipo; en
    /// iPhone/iPad lo fija la app al arrancar (UIKit no entra en el núcleo).
    nonisolated(unsafe) static var name: String = defaultName

    private static var defaultName: String {
        #if os(macOS)
        // Nombre de «Compartir» (rápido: sin resolver DNS como `Host.current()`).
        return (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        #else
        return "iPhone/iPad"
        #endif
    }

    /// UUID estable de la instalación (UserDefaults).
    static var id: String {
        if let stored = UserDefaults.standard.string(forKey: idKey) { return stored }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: idKey)
        return fresh
    }
}

enum PortForwardServerFiles {

    /// Versión de la skill y el script: se reinstalan si la instalada es otra.
    static let toolVersion = "argos-ports v3"

    /// Cada cuánto el dispositivo renueva su archivo mientras tiene túneles (el script los
    /// marca como dudosos pasado el triple).
    static let refreshInterval: TimeInterval = 60

    private static let forwardsDir = "$HOME/.config/argos/forwards"

    /// Solo `[A-Za-z0-9-]`: el id va en una ruta.
    static func safeID(_ id: String) -> String {
        let allowed = id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" }
        let cleaned = String(String.UnicodeScalarView(allowed))
        return cleaned.isEmpty ? "dispositivo" : cleaned
    }

    /// Una línea por túnel: `puertoRemoto<TAB>puertoLocal<TAB>host`.
    static func forwardLines(_ forwards: [ActivePortForward]) -> String {
        forwards
            .sorted { $0.remotePort < $1.remotePort }
            .map { "\($0.remotePort)\t\($0.localPort)\t\(sanitized($0.targetHost))\n" }
            .joined()
    }

    /// Escribe (atómico) el archivo del dispositivo. Primera línea: nombre y hora del servidor.
    static func publishCommand(deviceID: String, deviceName: String, forwards: [ActivePortForward]) -> String {
        let id = safeID(deviceID)
        let q = ShellQuoting.singleQuoted
        return ShellQuoting.posixShell(
            "d=\"\(forwardsDir)\"; mkdir -p \"$d\" && "
            + "{ printf '%s\\t%s\\n' \(q(sanitized(deviceName))) \"$(date +%s)\"; printf '%s' \(q(forwardLines(forwards))); } "
            + "> \"$d/\(id).tmp\" && mv \"$d/\(id).tmp\" \"$d/\(id).tsv\""
        )
    }

    /// Borra el archivo del dispositivo (sin túneles abiertos).
    static func unpublishCommand(deviceID: String) -> String {
        ShellQuoting.posixShell("rm -f \"\(forwardsDir)/\(safeID(deviceID)).tsv\"")
    }

    /// Instala el script y la skill si faltan o son de otra versión (idempotente).
    static var installCommand: String {
        let dir = "$HOME/.claude/skills/argos-puertos"
        let script = "\(dir)/argos-ports"
        let skill = "\(dir)/SKILL.md"
        return ShellQuoting.posixShell(
            "grep -qs \(ShellQuoting.singleQuoted(toolVersion)) \"\(script)\" && "
            + "grep -qs \(ShellQuoting.singleQuoted(toolVersion)) \"\(skill)\" && exit 0\n"
            + "mkdir -p \"\(dir)\" || exit 1\n"
            + "cat > \"\(script)\" <<'ARGOS_PORTS_SCRIPT'\n\(scriptContent)ARGOS_PORTS_SCRIPT\n"
            + "chmod 755 \"\(script)\" || exit 1\n"
            + "cat > \"\(skill)\" <<'ARGOS_PORTS_SKILL'\n\(skillContent)ARGOS_PORTS_SKILL\n"
            // v1 dejaba el script fuera de la skill.
            + "rm -f \"$HOME/.config/argos/bin/argos-ports\"\n"
        )
    }

    // MARK: - Solicitudes de Claude («argos-ports open PUERTO [NOTA]»)

    /// Una solicitud caduca a los 10 minutos (el script y Argos la ignoran).
    static let requestMaxAge: Int = 600

    private static let requestsDir = "$HOME/.config/argos/forward-requests"

    /// Hora del servidor y una línea por solicitud: `puerto<TAB>creada<TAB>nota`. Borra antes
    /// las caducadas.
    static var listRequestsCommand: String {
        ShellQuoting.posixShell(
            "r=\"\(requestsDir)\"; find \"$r\" -name '*.req' -mmin +10 -exec rm -f {} + 2>/dev/null; "
            + "date +%s; for f in \"$r\"/*.req; do [ -f \"$f\" ] || continue; "
            + "p=${f##*/}; printf '%s\\t' \"${p%.req}\"; head -n 1 \"$f\"; done"
        )
    }

    /// Retira una solicitud (aceptada o rechazada).
    static func dismissRequestCommand(port: Int) -> String {
        ShellQuoting.posixShell("rm -f \"\(requestsDir)/\(port).req\"")
    }

    private static func sanitized(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Contenido

    /// Script POSIX que ejecuta Claude (o el usuario) en el servidor.
    static let scriptContent = """
    #!/bin/sh
    # \(toolVersion) — instalado por la app Argos.
    # Uso:
    #   argos-ports                     puertos en escucha y túneles abiertos por Argos
    #   argos-ports open PUERTO [NOTA]  pide al usuario (en Argos) abrir ese puerto en su dispositivo
    dir="$HOME/.config/argos/forwards"
    req="$HOME/.config/argos/forward-requests"
    now=$(date +%s)
    tab=$(printf '\\t')

    if [ "$1" = "open" ]; then
      port=$2
      case "$port" in
        ''|*[!0-9]*) echo "Uso: argos-ports open PUERTO [NOTA]" >&2; exit 2 ;;
      esac
      if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "Puerto fuera de rango: $port" >&2; exit 2
      fi
      shift 2
      note=$(printf '%s' "$*" | tr '\\t\\n\\r' '   ' | cut -c1-200)
      mkdir -p "$req" || exit 1
      printf '%s\\t%s\\n' "$now" "$note" > "$req/$port.req.tmp" && mv "$req/$port.req.tmp" "$req/$port.req" || exit 1
      echo "Pedido enviado: Argos mostrará al usuario «Claude quiere mostrarte el puerto ${port}» y debe aceptarlo."
      echo "Caduca en 10 minutos. Comprueba después con «argos-ports» si ya está reenviado."
      exit 0
    fi

    echo "Puertos TCP en escucha en $(hostname):"
    if command -v ss >/dev/null 2>&1; then
      ss -Htlnp 2>/dev/null || ss -tln
    elif command -v lsof >/dev/null 2>&1; then
      lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null
    else
      netstat -tln 2>/dev/null
    fi | sed 's/^/  /'
    echo
    echo "Reenviados por Argos a los dispositivos del usuario:"
    found=0
    for f in "$dir"/*.tsv; do
      [ -f "$f" ] || continue
      found=1
      {
        IFS="$tab" read -r name updated
        age=$((now - ${updated:-0}))
        note=""
        [ "$age" -gt 180 ] && note=" (sin noticias de Argos desde hace $((age / 60)) min: puede que ya no esté abierto)"
        echo "- $name$note"
        while IFS="$tab" read -r remote local host; do
          [ -n "$remote" ] && echo "    puerto $remote del servidor -> http://localhost:$local en ese dispositivo"
        done
      } < "$f"
    done
    [ "$found" = 1 ] || echo "  (ninguno: el usuario puede abrir uno desde Argos -> Puertos)"
    echo
    echo "Pedidos pendientes de que el usuario los acepte en Argos:"
    pending=0
    for f in "$req"/*.req; do
      [ -f "$f" ] || continue
      IFS="$tab" read -r created note < "$f"
      age=$((now - ${created:-0}))
      [ "$age" -gt 600 ] && continue
      pending=1
      p=${f##*/}
      echo "  puerto ${p%.req}${note:+ - $note} (hace $((age / 60)) min)"
    done
    [ "$pending" = 1 ] || echo "  (ninguno)"

    """

    /// Skill de Claude Code (en el servidor) que explica cuándo y cómo usar el script.
    static let skillContent = """
    ---
    name: argos-puertos
    description: Puertos de este servidor y túneles que la app Argos tiene abiertos hacia el Mac, iPhone/iPad o Android del usuario; y cómo pedirle que abra uno. Úsala al arrancar o buscar un servidor de desarrollo (npm run dev, vite, next, rails, python -m http.server…), cuando el usuario quiera ver una web que corre aquí o pregunte qué puertos están en uso o reenviados.
    ---

    <!-- \(toolVersion) — instalado por la app Argos; se reinstala solo. -->

    # Puertos y túneles de Argos

    El usuario trabaja contigo desde **Argos**, una app que se conecta a este servidor por SSH.
    Argos puede reenviar un puerto de este servidor a su dispositivo (como `ssh -L`): lo que
    escucha aquí en el puerto N lo abre él en `http://localhost:<puerto local>` en su Mac,
    iPhone/iPad o Android.

    ## Ver qué hay

    ```sh
    ~/.claude/skills/argos-puertos/argos-ports
    ```

    Muestra los puertos en escucha en este servidor, por dispositivo los que Argos tiene
    reenviados (puerto del servidor → URL local en ese dispositivo) y los pedidos pendientes.

    ## Pedir que lo abra

    Cuando arranques algo que el usuario querrá ver (una web, una API con interfaz…), pídeselo:

    ```sh
    ~/.claude/skills/argos-puertos/argos-ports open 5173 "La web de inventario"
    ```

    Argos le muestra «Claude quiere mostrarte el puerto 5173» con tu nota; si acepta, se abre el
    túnel y su navegador. No se abre nada sin su confirmación. El pedido caduca a los 10 minutos.
    Pide solo puertos que tengan sentido para el usuario y una vez por servidor arrancado.

    ## Cómo usarlo

    - Tras arrancar un servidor de desarrollo, comprueba que escucha y pídele abrirlo (o dile el
      puerto si ya está reenviado).
    - Si ya está reenviado, dale la URL local de su dispositivo
      (p. ej. «ya lo tienes en http://localhost:3001 en tu Mac»).
    - También puede abrirlo él con el botón **Puertos** de Argos → «Reenviar y abrir»
      (Mac: cabecera del proyecto; iPhone/iPad: icono de red en la barra; Android: menú ⋮ →
      Puertos).
    - Arranca los servidores escuchando en `127.0.0.1` o `0.0.0.0`. No abras puertos a internet
      ni toques el firewall para que el usuario los vea: el túnel de Argos ya va cifrado por SSH.
    - Los túneles se cierran solos tras un rato sin conexiones (el usuario lo configura en Argos).
      Una entrada marcada «sin noticias» puede estar cerrada.
    - Los túneles se anotan en la máquina donde corren los servidores. Si en esta no aparece
      ninguno pero el usuario dice tener uno abierto, puede ser de otro servidor.

    """
}
