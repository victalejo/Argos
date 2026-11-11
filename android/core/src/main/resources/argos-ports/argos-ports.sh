#!/bin/sh
# argos-ports v3 — instalado por la app Argos.
# Uso:
#   argos-ports                     puertos en escucha y túneles abiertos por Argos
#   argos-ports open PUERTO [NOTA]  pide al usuario (en Argos) abrir ese puerto en su dispositivo
dir="$HOME/.config/argos/forwards"
req="$HOME/.config/argos/forward-requests"
now=$(date +%s)
tab=$(printf '\t')

if [ "$1" = "open" ]; then
  port=$2
  case "$port" in
    ''|*[!0-9]*) echo "Uso: argos-ports open PUERTO [NOTA]" >&2; exit 2 ;;
  esac
  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "Puerto fuera de rango: $port" >&2; exit 2
  fi
  shift 2
  note=$(printf '%s' "$*" | tr '\t\n\r' '   ' | cut -c1-200)
  mkdir -p "$req" || exit 1
  printf '%s\t%s\n' "$now" "$note" > "$req/$port.req.tmp" && mv "$req/$port.req.tmp" "$req/$port.req" || exit 1
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
