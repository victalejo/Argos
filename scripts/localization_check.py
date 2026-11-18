#!/usr/bin/env python3
"""Comprueba los catálogos .xcstrings: cada clave con inglés traducido y no vacío, los
marcadores de formato iguales en español y en inglés, el español explícito y ninguna
clave obsoleta.

Uso: localization_check.py [--fill-source] catálogo.xcstrings…  (sale con 1 si hay problemas)

El español (idioma de origen) TIENE que estar escrito en cada entrada: la región de
desarrollo del bundle es el inglés (idioma de reserva), y una clave que falte en
es.lproj se buscaría en en.lproj, así que un usuario en español la vería en inglés.
--fill-source lo rellena (valor = clave, o las frases de Atajos marcadas como revisadas).
"""
from __future__ import annotations

import json
import re
import sys
from collections import Counter

SOURCE = "es"
TARGET = "en"
SPECIFIER = re.compile(r"%(?:(\d+)\$)?[-#+ 0]*\d*(?:\.\d+)?(ll|l|h|q|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA])|%%")
SUBSTITUTION = re.compile(r"%#@([A-Za-z0-9_]+)@")


def specifiers(text: str) -> Counter:
    """Marcadores de formato (tipo normalizado por posición) de un valor."""
    found: Counter = Counter()
    position = 0
    for match in SPECIFIER.finditer(text):
        if match.group(0) == "%%":
            continue
        position += 1
        index = int(match.group(1)) if match.group(1) else position
        kind = (match.group(2) or "") + match.group(3)
        found[(index, "d" if kind in ("lld", "ld", "d", "i", "lli", "li") else kind)] += 1
    return found


def values(localization: dict) -> list[tuple[str, str]]:
    """(estado, valor) de cada forma: el valor simple, cada variante y cada sustitución."""
    out = []
    unit = localization.get("stringUnit")
    if unit:
        out.append((unit.get("state", ""), unit.get("value", "")))
    string_set = localization.get("stringSet")  # frases de Atajos (AppShortcuts)
    if string_set:
        out.extend((string_set.get("state", ""), value) for value in string_set.get("values", []))
    for variations in localization.get("variations", {}).values():
        for form in variations.values():
            out.extend(values(form))
    for substitution in localization.get("substitutions", {}).values():
        for variations in substitution.get("variations", {}).values():
            for form in variations.values():
                out.extend(values(form))
    return out


def check(path: str) -> list[str]:
    problems = []
    catalog = json.load(open(path, encoding="utf-8"))
    for key, entry in sorted(catalog.get("strings", {}).items()):
        if entry.get("shouldTranslate") is False:
            continue
        if entry.get("extractionState") == "stale":
            problems.append(f"{path}: «{key}» ya no se usa (stale): bórrala")
            continue
        localizations = entry.get("localizations", {})
        english = localizations.get(TARGET)
        if not english:
            problems.append(f"{path}: «{key}» sin traducción inglesa")
            continue
        forms = values(english)
        if not forms or any(state != "translated" or not value.strip() for state, value in forms):
            problems.append(f"{path}: «{key}» con inglés vacío o sin revisar")
            continue
        source_forms = values(localizations.get(SOURCE, {}))
        if not source_forms or any(state != "translated" for state, _ in source_forms):
            problems.append(f"{path}: «{key}» sin español explícito (ejecuta extract o --fill-source)")
            continue
        expected = specifiers(key)
        for _, value in forms:
            if SUBSTITUTION.search(value):
                continue  # las sustituciones se comprueban por su forma
            if specifiers(value) != expected and not (len(forms) > 1 and specifiers(value) == Counter()):
                problems.append(f"{path}: «{key}» marcadores distintos en inglés: «{value}»")
    return problems


def fill_source(path: str) -> None:
    """Escribe el español de origen en cada entrada que no lo tenga."""
    catalog = json.load(open(path, encoding="utf-8"))
    for key, entry in catalog.get("strings", {}).items():
        if entry.get("shouldTranslate") is False or entry.get("extractionState") == "stale":
            continue
        localizations = entry.setdefault("localizations", {})
        source = localizations.get(SOURCE)
        if source is None:
            localizations[SOURCE] = {"stringUnit": {"state": "translated", "value": key}}
        elif "stringSet" in source:
            source["stringSet"]["state"] = "translated"
        elif "stringUnit" in source:
            source["stringUnit"]["state"] = "translated"
    text = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    open(path, "w", encoding="utf-8").write(text + "\n")


def main() -> int:
    paths = [p for p in sys.argv[1:] if p != "--fill-source"]
    if "--fill-source" in sys.argv:
        for path in paths:
            fill_source(path)
    problems = [p for path in paths for p in check(path)]
    for problem in problems:
        print(problem)
    if problems:
        print(f"{len(problems)} problemas de localización.")
        return 1
    print("Catálogos completos.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
