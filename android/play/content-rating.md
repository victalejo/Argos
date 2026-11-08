# Clasificación de contenido (cuestionario IARC)

Play Console → Contenido de la app → Clasificación del contenido → Iniciar cuestionario.

- **Correo electrónico de contacto de IARC:** el de la cuenta de desarrollador (recibe el certificado).
- **Categoría:** «Todas las demás tipos de aplicaciones» (*All other app types*; no es juego, ni red
  social, ni tienda, ni app de noticias). Si el formulario ofrece «Utilidades, productividad,
  comunicación u otras», elige esa.

## Respuestas

| Pregunta (resumen) | Respuesta | Por qué |
|---|---|---|
| Violencia, sangre, contenido sexual, desnudos | No | La app no incluye contenido propio: muestra la salida del servidor del usuario |
| Lenguaje soez u ofensivo | No | |
| Sustancias controladas (drogas, alcohol, tabaco) | No | |
| Contenido sobre apuestas / juegos de azar simulados | No | |
| Contenido de terror o miedo | No | |
| ¿Los usuarios pueden interactuar o intercambiar contenido entre ellos? | **No** | No hay chat entre personas, perfiles ni contenido compartido entre usuarios: cada usuario se conecta a SUS servidores |
| ¿La app comparte la ubicación del usuario con otros usuarios? | No | No usa ubicación |
| ¿Permite compras de bienes digitales? | No | App gratuita, sin compras integradas |
| ¿Acceso sin restricciones a Internet (navegador web)? | **No** | No tiene navegador; los enlaces se abren en el navegador del sistema tras confirmar. El terminal SSH se conecta solo a servidores que configura el usuario |
| ¿Contenido generado por IA? (si aparece) | Sí, indirectamente: muestra respuestas de Claude Code ejecutado en el servidor del usuario y con su propia cuenta de Claude. La app no genera contenido por sí misma | Políticas de contenido generado por IA de Play: las respuestas no se comparten con otros usuarios |
| ¿Es una app de noticias / educativa / dirigida a niños? | No | |

Resultado esperado: **IARC 3+ / PEGI 3 / ESRB «Everyone»** (o equivalente). Si sale distinto,
revisa la pregunta sobre interacción entre usuarios.

## Público objetivo (sección aparte: «Público objetivo y contenido»)

- Grupos de edad: **18 años o más** (herramienta para profesionales con servidores propios). No
  marques franjas de menores: evita los requisitos de la política de Familias.
- ¿Atrae a niños? **No.**
