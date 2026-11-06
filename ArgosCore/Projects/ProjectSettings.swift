//
//  ProjectSettings.swift
//  Argos
//
//  Preferencias globales de proyectos (pestaña "Proyectos" de Ajustes). Cada proyecto
//  puede sobrescribir el comando de arranque; si no, usa este predeterminado.
//

import Foundation
import Observation

@MainActor
@Observable
final class ProjectSettings {
    static let shared = ProjectSettings()

    /// `cc` es el alias habitual de Claude Code; `--continue` retoma la última
    /// conversación de la carpeta (y empieza una nueva si no hay).
    static let factoryStartupCommand = "cc --continue"

    /// Atajos ofrecidos en Ajustes y en el formulario del proyecto.
    static let presets: [(label: String, command: String)] = [
        ("Claude Code, continuar conversación", "cc --continue"),
        ("Claude Code, conversación nueva", "cc"),
        ("claude --continue (sin alias)", "claude --continue"),
        ("No lanzar nada", ""),
    ]

    private static let defaultsKey = "projects.defaultStartupCommand"

    @ObservationIgnored private let defaults: UserDefaults

    /// Comando que se teclea en la sesión al abrir un proyecto (`""` = nada). Se envía
    /// con `send-keys` al shell interactivo, así que funcionan los alias (`cc`).
    var defaultStartupCommand: String {
        didSet { defaults.set(defaultStartupCommand, forKey: Self.defaultsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.defaultStartupCommand = defaults.string(forKey: Self.defaultsKey) ?? Self.factoryStartupCommand
    }
}
