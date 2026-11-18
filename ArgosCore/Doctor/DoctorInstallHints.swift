//
//  DoctorInstallHints.swift
//  ArgosCore
//
//  Comandos para COPIAR (nunca se ejecutan desde Argos) que instalan un paquete con el
//  gestor que detectó el script del Doctor.
//

import Foundation

enum DoctorInstallHints {

    /// `sudo apt-get install -y tmux`, `brew install tmux`… o `nil` si no se conoce el gestor.
    static func install(package: String, packageManager: String?) -> String? {
        switch packageManager {
        case "apt-get": return "sudo apt-get install -y \(package)"
        case "dnf": return "sudo dnf install -y \(package)"
        case "yum": return "sudo yum install -y \(package)"
        case "pacman": return "sudo pacman -S --noconfirm \(package)"
        case "apk": return "sudo apk add \(package)"
        case "zypper": return "sudo zypper install -y \(package)"
        case "brew": return "brew install \(package)"
        default: return nil
        }
    }

    /// Instalador oficial de Claude Code (script de instalación nativo).
    static let claudeInstall = "curl -fsSL https://claude.ai/install.sh | bash"
}
