---
name: argos-puertos
description: Puertos de este servidor y túneles que la app Argos tiene abiertos hacia el Mac, iPhone/iPad o Android del usuario; y cómo pedirle que abra uno. Úsala al arrancar o buscar un servidor de desarrollo (npm run dev, vite, next, rails, python -m http.server…), cuando el usuario quiera ver una web que corre aquí o pregunte qué puertos están en uso o reenviados.
---

<!-- argos-ports v3 — instalado por la app Argos; se reinstala solo. -->

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
