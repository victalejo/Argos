//
//  LocalizationWhitelist.swift
//  ArgosTests
//
//  Lo que se queda en español A PROPÓSITO (lo usa `LocalizationCatalogTests`). Que sea
//  corta: cada entrada es algo que viaja al servidor, se persiste o se compara, nunca un
//  texto que vea el usuario en la app.
//

enum LocalizationWhitelist {

    /// Archivos que solo contienen scripts o textos que se instalan en el servidor.
    static let files: Set<String> = [
        // Scripts de los agentes persistentes (se ejecutan en el servidor).
        "ArgosCore/Agent/PersistentAgentScript.swift",
        "ArgosCore/Agent/PersistentAgentShell.swift",
        // Skill «argos-puertos» y archivos que se escriben en el servidor.
        "ArgosCore/PortForwarding/PortForwardServerFiles.swift",
    ]

    /// Subcadenas de literales que no se traducen.
    static let literals: [String] = [
        // Respuesta al protocolo de Claude Code (viaja al servidor).
        "El usuario denegó esta acción.",
        // Prompt de «Sugerir mensaje»: viaja a Claude, que responde en el idioma de los
        // commits del repositorio (y lo consumen los goldens de Android).
        "archivos más que no se muestran aquí",
        // Identificadores estables guardados (plegado de grupos); se muestran traducidos
        // con `SessionGrouping.displayName` / `VisibleProjectListing.displayName(ofGroup:)`.
        "Sesiones sueltas",
        // Prefijos que a veces añade Claude a su respuesta (se comparan, no se muestran).
        "Mensaje de commit:",
        // Marcadores del informe de diagnóstico (se comparan en los tests del redactor).
        "[clave-privada]",
        "[ruta-de-clave]",
        // Valor centinela de un Picker (nunca se muestra).
        "\u{0}personalizado",
        // Solo van al registro (`noteBackgroundFailure(_:during:)` no los muestra).
        "leer el estado de Claude",
        "releer las sesiones",
        "sondear el servidor",
        "leer la memoria del servidor",
        // Contexto de los errores de los puntos de restauración: solo va al registro.
        "Vista previa de la restauración",
        "Detener a Claude",
        "Activar puntos de restauración",
        "Desactivar puntos de restauración",
        "Guardar extractos",
        "Borrar puntos",
        "Quitar del servidor",
        "Crear punto",
        // Etiqueta de la instantánea manual: se guarda en el servidor (mensaje del commit).
        "Punto creado a mano",
        // Nombre de archivo del script de Terminal de la variante App Store (se guarda en disco).
        "Abrir en Terminal.scpt",
    ]
}
