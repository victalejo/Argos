//
//  ShellRcProbe.swift
//  ArgosCore
//
//  Lectura segura de ~/.zshrc y ~/.bashrc del servidor para las marcas de prompt (lógica
//  pura). El contenido viaja en base64 ENTRE MARCAS con un aleatorio: lo que imprima el
//  arranque del shell de la cuenta (.zshenv, avisos de login…) queda fuera y nunca acaba
//  dentro del archivo, y los bytes llegan intactos (si no son UTF-8 válido, Argos no lo
//  reescribe). También informa de lo que impediría reescribirlo con seguridad (enlace
//  simbólico o duro, algo que no es un archivo) y de si ese rc llega a cargarse
//  (`ZDOTDIR`, un bash de login cuyo perfil no carga .bashrc).
//

import Foundation

enum ShellRcProbe {

    /// Estado de un rc en el servidor.
    enum FileState: Equatable, Sendable {
        case absent
        /// Enlace simbólico, enlace duro u otra cosa que no es un archivo normal.
        case notRegular
        /// `mode`: permisos en octal (`644`), si se pudieron leer.
        case file(Data, mode: String?)
    }

    /// Primer perfil de login de bash que existe y si menciona .bashrc.
    struct BashProfile: Equatable, Sendable {
        let name: String
        let loadsRc: Bool
    }

    struct Report: Equatable, Sendable {
        var loginShell = ""
        var home = ""
        var zdotdir = ""
        var bashLoginProfile: BashProfile?
        var files: [ShellIntegrationBlock.Shell: FileState] = [:]
        /// La lectura llegó entera.
        var complete = false
    }

    static func marker(_ nonce: String) -> String { "ARGOS_RC_\(nonce)" }

    /// Script (sh POSIX) que describe los rc. `base64` existe en coreutils, BusyBox y macOS.
    static func command(nonce: String) -> String {
        let m = marker(nonce)
        return [
            "m=\(m)",
            "printf '%s|shell|%s\\n' \"$m\" \"${SHELL-}\"",
            "printf '%s|home|%s\\n' \"$m\" \"$HOME\"",
            "printf '%s|zdotdir|%s\\n' \"$m\" \"${ZDOTDIR-}\"",
            "for p in .bash_profile .bash_login .profile; do",
            "  if [ -e \"$HOME/$p\" ]; then",
            "    if grep -q bashrc \"$HOME/$p\" 2>/dev/null; then r=yes; else r=no; fi",
            "    printf '%s|bashlogin|%s|%s\\n' \"$m\" \"$p\" \"$r\"; break",
            "  fi",
            "done",
            "for p in .zshrc .bashrc; do",
            "  f=\"$HOME/$p\"",
            "  if [ -L \"$f\" ]; then printf '%s|other|%s\\n' \"$m\" \"$p\"",
            "  elif [ -f \"$f\" ]; then",
            "    n=$(stat -c %h \"$f\" 2>/dev/null || stat -f %l \"$f\" 2>/dev/null)",
            "    if [ \"${n:-1}\" != 1 ]; then printf '%s|other|%s\\n' \"$m\" \"$p\"; continue; fi",
            "    a=$(stat -c %a \"$f\" 2>/dev/null || stat -f %Lp \"$f\" 2>/dev/null)",
            "    printf '%s|file|%s|%s\\n' \"$m\" \"$p\" \"$a\"",
            "    base64 < \"$f\" || exit 4",
            "    printf '\\n%s|end|%s\\n' \"$m\" \"$p\"",
            "  elif [ -e \"$f\" ]; then printf '%s|other|%s\\n' \"$m\" \"$p\"",
            "  else printf '%s|absent|%s\\n' \"$m\" \"$p\"; fi",
            "done",
            "printf '%s|done\\n' \"$m\"",
        ].joined(separator: "\n")
    }

    /// Lee la salida de `command`. Lo que no lleva la marca (ruido del arranque) se ignora.
    static func parse(_ output: String, nonce: String) -> Report {
        let prefix = marker(nonce) + "|"
        var report = Report()
        var reading: (shell: ShellIntegrationBlock.Shell, mode: String?, base64: String)?
        for line in output.components(separatedBy: "\n") {
            guard line.hasPrefix(prefix) else {
                if reading != nil { reading?.base64 += line }
                continue
            }
            let fields = line.dropFirst(prefix.count).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            switch (fields.first ?? "", fields.count) {
            case ("shell", 2...): report.loginShell = fields[1...].joined(separator: "|")
            case ("home", 2...): report.home = fields[1...].joined(separator: "|")
            case ("zdotdir", 2...): report.zdotdir = fields[1...].joined(separator: "|")
            case ("bashlogin", 3): report.bashLoginProfile = BashProfile(name: fields[1], loadsRc: fields[2] == "yes")
            case ("absent", 2): shell(fields[1]).map { report.files[$0] = .absent }
            case ("other", 2): shell(fields[1]).map { report.files[$0] = .notRegular }
            case ("file", 3):
                if let shell = shell(fields[1]) { reading = (shell: shell, mode: validMode(fields[2]), base64: "") }
            case ("end", 2):
                if let current = reading, shell(fields[1]) == current.shell,
                   let data = Data(base64Encoded: current.base64, options: .ignoreUnknownCharacters) {
                    report.files[current.shell] = .file(data, mode: current.mode)
                }
                reading = nil
            case ("done", 1): report.complete = true
            default: break
            }
        }
        return report
    }

    private static func shell(_ rcFile: String) -> ShellIntegrationBlock.Shell? {
        ShellIntegrationBlock.Shell.allCases.first { $0.rcFile == rcFile }
    }

    /// Permisos en octal de 3 o 4 cifras (lo que se le pasa a `chmod`).
    static func validMode(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard (3...4).contains(trimmed.count), trimmed.allSatisfy({ ("0"..."7").contains($0) }) else { return nil }
        return trimmed
    }

    // MARK: - Decisiones

    /// Los rc que se tocan al instalar: los que existen y el del shell de inicio de sesión.
    static func targets(_ report: Report) throws -> [ShellIntegrationBlock.Shell] {
        let login = ShellIntegrationBlock.Shell(loginShell: report.loginShell)
        let shells = ShellIntegrationBlock.Shell.allCases.filter { shell in
            if shell == login { return true }
            switch report.files[shell] {
            case .file, .notRegular: return true
            case .absent, nil: return false
            }
        }
        guard !shells.isEmpty else {
            throw ShellIntegrationError.unsupportedShell((report.loginShell as NSString).lastPathComponent)
        }
        return shells
    }

    /// Texto del rc (vacío si no existe). Lanza si no se puede reescribir con seguridad.
    static func text(of state: FileState?, shell: ShellIntegrationBlock.Shell) throws -> String {
        switch state {
        case .absent: return ""
        case .notRegular, nil: throw ShellIntegrationError.notRegularFile(shell.rcFile)
        case .file(let data, _):
            guard let text = String(data: data, encoding: .utf8) else {
                throw ShellIntegrationError.notUTF8(shell.rcFile)
            }
            return text
        }
    }

    /// Estado del bloque en los rc.
    static func status(_ report: Report) -> ShellIntegrationStatus {
        var anyBlock = false
        for shell in ShellIntegrationBlock.Shell.allCases {
            guard case .file(let data, _) = report.files[shell] else { continue }
            let text = String(decoding: data, as: UTF8.self)
            if ShellIntegrationBlock.isCurrent(in: text, shell: shell) { return .installed }
            anyBlock = anyBlock || ShellIntegrationBlock.isInstalled(in: text)
        }
        return anyBlock ? .outdated : .notInstalled
    }

    /// Por qué el bloque podría no cargarse nunca (`nil` si no hay motivo conocido).
    static func warning(_ report: Report) -> String? {
        switch ShellIntegrationBlock.Shell(loginShell: report.loginShell) {
        case .zsh:
            let zdotdir = report.zdotdir.trimmingCharacters(in: .whitespaces)
            let normalized = (zdotdir as NSString).standardizingPath
            guard !zdotdir.isEmpty, normalized != (report.home as NSString).standardizingPath else { return nil }
            return String(localized: "El servidor define ZDOTDIR=\(zdotdir): zsh no lee ~/.zshrc y las marcas no se activarán.")
        case .bash:
            guard let profile = report.bashLoginProfile, !profile.loadsRc else { return nil }
            return String(localized: "~/\(profile.name) no carga ~/.bashrc: en los shells de login (los de tmux) las marcas no se activarán.")
        case nil:
            return nil
        }
    }
}
