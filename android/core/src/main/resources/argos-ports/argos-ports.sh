#!/bin/sh
# argos-ports v2 — instalado por la app Argos.
# Puertos en escucha en este servidor y túneles que Argos tiene abiertos hacia los
# dispositivos del usuario (Mac, iPhone/iPad, Android).
dir="$HOME/.config/argos/forwards"
now=$(date +%s)
tab=$(printf '\t')
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
