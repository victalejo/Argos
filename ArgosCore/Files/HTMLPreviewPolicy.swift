//
//  HTMLPreviewPolicy.swift
//  Argos
//
//  Reglas del visor HTML para páginas del servidor (contenido NO confiable). Lógica
//  pura, testeable; la aplica `HTMLPreviewController` (WebKit).
//
//  Por defecto la página se ve "aislada": sin JavaScript y sin ninguna petición de red
//  (ni imágenes, ni CSS, ni fuentes remotas), para no revelar la IP ni permitir rastreo,
//  igual que el visor de Markdown. El usuario puede permitir JavaScript y recursos
//  externos para esa página. En ningún caso la página navega por su cuenta: los enlaces
//  que pulsa el usuario se abren fuera (solo http/https/mailto, tras confirmar).
//

import Foundation

enum HTMLPreviewPolicy {
    enum Decision: Equatable {
        case allow
        case cancel
        case openExternally(URL)
    }

    static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    /// Content rule list de WebKit: bloquea toda carga salvo `about:`, `data:` y `blob:`
    /// (contenido incrustado en la propia página, sin red).
    static let blockRemoteRules = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^(about|data|blob):"}, "action": {"type": "ignore-previous-rules"}}
    ]
    """

    /// Página que se muestra si no se pudo activar el bloqueo (se falla cerrado).
    static let blockerUnavailablePage = """
    <html><body style="font: 14px -apple-system, sans-serif; color: #666; padding: 24px">
    No se pudo activar el bloqueo de contenido externo, así que la página no se muestra.
    Usa la vista «Fuente» o permite el contenido externo.
    </body></html>
    """

    /// Qué hacer con una navegación dentro del visor.
    /// - `isUserLink`: el usuario pulsó un enlace.
    /// - `isMainFrame`: navega el documento principal (no un iframe).
    static func decide(url: URL?, isUserLink: Bool, isMainFrame: Bool, allowsRemoteContent: Bool) -> Decision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        // Carga inicial (`loadHTMLString` → about:blank), anclas `#…` e iframes srcdoc.
        if scheme == "about" { return .allow }
        if isUserLink { return externalSchemes.contains(scheme) ? .openExternally(url) : .cancel }
        // Iframes (vídeos, mapas…) solo si el usuario permitió el contenido externo.
        if !isMainFrame && allowsRemoteContent && ["http", "https", "data"].contains(scheme) { return .allow }
        // Redirecciones, formularios, `location = …`, meta refresh: nunca.
        return .cancel
    }
}
