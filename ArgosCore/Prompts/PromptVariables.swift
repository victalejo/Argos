//
//  PromptVariables.swift
//  ArgosCore
//
//  Variables fijas de la biblioteca de encargos: `{rama}`, `{ultimo_commit}`,
//  `{archivos_cambiados}` y `{fecha}`. Sus valores salen de git en la carpeta del
//  proyecto, con UN comando con plazo (`command`), y se sustituyen aquí (lógica pura).
//  El servidor no es de fiar: cada valor se recorta y se limpia de caracteres de control.
//

import Foundation

enum PromptVariables {
    static let branch = "{rama}"
    static let lastCommit = "{ultimo_commit}"
    static let changedFiles = "{archivos_cambiados}"
    static let date = "{fecha}"
    static let all = [branch, lastCommit, changedFiles, date]

    /// Plazo en el servidor del comando de git.
    static let timeoutSeconds = 15
    static let maxValueLength = 200
    static let maxFiles = 30
    /// Exit code del comando si la carpeta no existe.
    static let missingFolderExitCode = 3

    /// Lo que se pone si el servidor no da un valor (no es un repo, git no está…). Viaja
    /// a Claude: no se traduce.
    static let unknownValue = "(sin datos)"
    static let noFilesValue = "(ninguno)"

    struct Values: Equatable, Sendable {
        var branch: String?
        var lastCommit: String?
        var changedFiles: [String] = []
        /// AAAA-MM-DD del servidor.
        var date: String?
    }

    static func containsVariables(_ text: String) -> Bool {
        all.contains { text.contains($0) }
    }

    /// `text` con cada variable sustituida. Sin fecha del servidor se usa `fallbackDate`.
    static func substitute(_ text: String, values: Values, fallbackDate: Date = Date()) -> String {
        guard containsVariables(text) else { return text }
        let files = values.changedFiles.isEmpty ? noFilesValue : values.changedFiles.joined(separator: ", ")
        let replacements: [(String, String)] = [
            (branch, values.branch ?? unknownValue),
            (lastCommit, values.lastCommit ?? unknownValue),
            (changedFiles, files),
            (date, values.date ?? isoDay(fallbackDate)),
        ]
        return replacements.reduce(text) { partial, pair in
            partial.replacingOccurrences(of: pair.0, with: pair.1)
        }
    }

    static func isoDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    // MARK: - Servidor

    /// POSIX sh, en la carpeta del proyecto, sin hooks ni cerrojos de git. Una línea por
    /// dato: `D fecha`, `B rama`, `C commit`, `F línea de git status --porcelain`.
    static func command(projectPath: String) -> String {
        let script = """
        cd -- \(ShellQuoting.singleQuoted(projectPath)) 2>/dev/null || exit \(missingFolderExitCode)
        printf 'D %s\\n' "$(date +%Y-%m-%d)"
        command -v git >/dev/null 2>&1 || exit 0
        export GIT_OPTIONAL_LOCKS=0
        git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
        b=$(git symbolic-ref --short -q HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
        printf 'B %s\\n' "$b"
        printf 'C %s\\n' "$(git log -1 --format='%h %s' 2>/dev/null)"
        git -c core.quotePath=true status --porcelain 2>/dev/null | head -n \(maxFiles) | while IFS= read -r l; do printf 'F %s\\n' "$l"; done
        exit 0
        """
        return RemoteTimeout.wrap(script, seconds: timeoutSeconds)
    }

    static func parse(_ output: String) -> Values {
        var values = Values()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.count >= 2, line.dropFirst().first == " " else { continue }
            let value = String(line.dropFirst(2))
            switch line.first {
            case "D": values.date = clean(value).flatMap(validDay)
            case "B": values.branch = clean(value)
            case "C": values.lastCommit = clean(value)
            case "F":
                // `XY ruta` (o `XY vieja -> nueva`): se quita el estado.
                if values.changedFiles.count < maxFiles, value.count > 3, let path = clean(String(value.dropFirst(3))) {
                    values.changedFiles.append(path)
                }
            default: continue
            }
        }
        return values
    }

    /// Recortado, sin caracteres de control y con tope; `nil` si queda vacío.
    static func clean(_ raw: String) -> String? {
        let text = String(PromptText.singleLine(raw).prefix(maxValueLength))
        return text.isEmpty ? nil : text
    }

    private static func validDay(_ text: String) -> String? {
        let pattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#
        return text.range(of: pattern, options: .regularExpression) != nil ? text : nil
    }
}
