#!/usr/bin/env python3
"""Cobertura de líneas SOLO del núcleo (ArgosCore/) a partir de un .xcresult.

`Argos.app` incluye las vistas (que los tests no ejercitan), así que su porcentaje global
dice poco: este script filtra por ruta los archivos de `ArgosCore/` y, opcionalmente,
falla si la cobertura baja de un umbral.

Uso:
  scripts/coverage_core.py TestResults.xcresult [--threshold 60] [--worst 15]
                           [--summary-file "$GITHUB_STEP_SUMMARY"]
  scripts/coverage_core.py --report coverage.json ...   # JSON de `xccov view --report --json`
  scripts/coverage_core.py --self-test

Salida: informe en Markdown (stdout, y añadido a --summary-file si se indica) con el
total global, el del núcleo y los N archivos peor cubiertos. Código de salida 1 si el
núcleo queda por debajo del umbral.
"""
import argparse
import json
import subprocess
import sys

CORE_MARKER = "/ArgosCore/"


def load_report(xcresult):
    out = subprocess.run(
        ["xcrun", "xccov", "view", "--report", "--json", xcresult],
        check=True, capture_output=True, text=True,
    ).stdout
    return json.loads(out)


def app_files(report):
    """Archivos del target de la app (el que compila el código fuente), sin duplicados."""
    targets = report.get("targets", [])
    apps = [t for t in targets if t.get("name", "").endswith(".app")] or targets
    seen = {}
    for target in apps:
        for f in target.get("files", []):
            seen.setdefault(f["path"], f)
    return list(seen.values())


def core_files(files):
    return [f for f in files if CORE_MARKER in f["path"] and f.get("executableLines", 0) > 0]


def percent(covered, executable):
    return 100.0 * covered / executable if executable else 0.0


def totals(files):
    covered = sum(f["coveredLines"] for f in files)
    executable = sum(f["executableLines"] for f in files)
    return covered, executable, percent(covered, executable)


def worst(files, count):
    return sorted(files, key=lambda f: (percent(f["coveredLines"], f["executableLines"]), -f["executableLines"]))[:count]


def render(report, worst_count, threshold):
    everything = [f for f in app_files(report) if f.get("executableLines", 0) > 0]
    core = core_files(everything)
    g_cov, g_exe, g_pct = totals(everything)
    c_cov, c_exe, c_pct = totals(core)
    lines = ["## Cobertura de tests", ""]
    lines.append(f"- Global (Argos.app, con vistas): **{g_pct:.2f} %** ({g_cov}/{g_exe} líneas)")
    lines.append(f"- Núcleo (ArgosCore/): **{c_pct:.2f} %** ({c_cov}/{c_exe} líneas, {len(core)} archivos)")
    if threshold is not None:
        lines.append(f"- Puerta del núcleo: {threshold:.0f} %")
    lines += ["", f"### Los {worst_count} archivos de ArgosCore/ peor cubiertos", "",
              "| Archivo | Cobertura | Líneas |", "|---|---:|---:|"]
    for f in worst(core, worst_count):
        name = f["path"].split(CORE_MARKER, 1)[1]
        lines.append(f"| `{name}` | {percent(f['coveredLines'], f['executableLines']):.1f} % "
                     f"| {f['coveredLines']}/{f['executableLines']} |")
    return "\n".join(lines) + "\n", c_pct


def self_test():
    def f(path, cov, exe):
        return {"path": path, "coveredLines": cov, "executableLines": exe}
    report = {"targets": [
        {"name": "Argos.app", "files": [
            f("/r/ArgosCore/A.swift", 90, 100), f("/r/ArgosCore/B.swift", 10, 100),
            f("/r/ArgosCore/Empty.swift", 0, 0), f("/r/Argos/View.swift", 0, 800),
            f("/r/ArgosCore/A.swift", 90, 100)]},
        {"name": "ArgosTests.xctest", "files": [f("/r/ArgosTests/T.swift", 50, 50)]},
    ]}
    text, core_pct = render(report, 15, 50)
    assert abs(core_pct - 50.0) < 1e-9, core_pct          # (90+10)/(100+100), sin duplicados ni vacíos
    assert "Global (Argos.app, con vistas): **10.00 %**" in text, text   # 100/1000
    assert text.index("B.swift") < text.index("A.swift")  # el peor primero
    assert "View.swift" not in text and "Empty.swift" not in text
    print("self-test OK")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("xcresult", nargs="?")
    parser.add_argument("--report", help="JSON de `xccov view --report --json` (en vez del .xcresult)")
    parser.add_argument("--threshold", type=float, help="mínimo del núcleo (%%); por debajo, sale con 1")
    parser.add_argument("--worst", type=int, default=15)
    parser.add_argument("--summary-file")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0
    if args.report:
        with open(args.report, encoding="utf-8") as handle:
            report = json.load(handle)
    elif args.xcresult:
        report = load_report(args.xcresult)
    else:
        parser.error("indica un .xcresult o --report")

    text, core_pct = render(report, args.worst, args.threshold)
    print(text)
    if args.summary_file:
        with open(args.summary_file, "a", encoding="utf-8") as handle:
            handle.write(text)
    if args.threshold is not None and core_pct < args.threshold:
        print(f"::error::Cobertura del núcleo {core_pct:.2f} % por debajo del umbral {args.threshold:.0f} %.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
