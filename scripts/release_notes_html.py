#!/usr/bin/env python3
"""Convierte las últimas versiones de CHANGELOG.md en HTML para el appcast de Sparkle.

Uso: release_notes_html.py CHANGELOG.md VERSION [N]
Imprime las notas de VERSION y de las N-1 anteriores (por defecto 4 en total), para que
quien salte varias versiones vea también lo que se perdió. Solo admite el subconjunto de
Markdown que usa el CHANGELOG: `##`/`###`, viñetas con continuación, **negrita** y `código`.
"""

import html
import re
import sys

STYLE = """<style>
:root { color-scheme: light dark; }
body { font: 13px -apple-system, system-ui, sans-serif; line-height: 1.45; margin: 0 4px; }
h2 { font-size: 15px; margin: 14px 0 4px; }
h2 small { font-weight: normal; opacity: .6; }
h3 { font-size: 12px; text-transform: uppercase; letter-spacing: .04em; opacity: .7; margin: 10px 0 2px; }
ul { margin: 0; padding-left: 18px; }
li { margin: 2px 0; }
code { font: 12px ui-monospace, SFMono-Regular, monospace; background: rgba(127,127,127,.15); padding: 0 3px; border-radius: 3px; }
</style>"""

HEADER = re.compile(r"^## \[(?P<version>[^\]]+)\](?: - (?P<date>\S+))?\s*$")


def inline(text: str) -> str:
    escaped = html.escape(text, quote=False)
    escaped = re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)
    return re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", escaped)


def sections(changelog: str) -> list[tuple[str, str, list[str]]]:
    """[(versión, fecha, líneas)] en orden del archivo, sin 'Unreleased'."""
    result: list[tuple[str, str, list[str]]] = []
    for line in changelog.splitlines():
        match = HEADER.match(line)
        if match:
            result.append((match["version"], match["date"] or "", []))
        elif result and line.startswith("## "):
            result.append(("", "", []))  # otra sección de nivel 2: se ignora
        elif result:
            result[-1][2].append(line)
    return [s for s in result if s[0] and s[0].lower() != "unreleased"]


def render_body(lines: list[str]) -> str:
    out: list[str] = []
    items: list[str] = []

    def flush() -> None:
        if items:
            out.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
            items.clear()

    for raw in lines:
        line = raw.rstrip()
        if line.startswith("### "):
            flush()
            out.append(f"<h3>{inline(line[4:])}</h3>")
        elif line.startswith("- "):
            items.append(line[2:])
        elif line.startswith("  ") and items:
            items[-1] += " " + line.strip()
        elif line.strip():
            flush()
            out.append(f"<p>{inline(line.strip())}</p>")
    flush()
    return "".join(out)


def render(changelog: str, version: str, count: int) -> str:
    all_sections = sections(changelog)
    start = next((i for i, s in enumerate(all_sections) if s[0] == version), None)
    if start is None:
        raise SystemExit(f"CHANGELOG.md no tiene la sección [{version}]")
    parts = [STYLE]
    for name, date, lines in all_sections[start:start + count]:
        date_html = f" <small>{html.escape(date)}</small>" if date else ""
        parts.append(f"<h2>Argos {html.escape(name)}{date_html}</h2>{render_body(lines)}")
    result = "".join(parts)
    # Va dentro de un CDATA del appcast: nunca puede contener su cierre.
    return result.replace("]]>", "]]&gt;")


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)
    with open(sys.argv[1], encoding="utf-8") as handle:
        text = handle.read()
    print(render(text, sys.argv[2], int(sys.argv[3]) if len(sys.argv) == 4 else 4))
