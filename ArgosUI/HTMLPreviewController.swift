//
//  HTMLPreviewController.swift
//  Argos
//
//  WKWebView del visor HTML (Mac e iPhone/iPad) con `HTMLPreviewPolicy`: almacén de
//  datos efímero, JavaScript y red desactivados salvo que el usuario los permita, y
//  ninguna navegación fuera del documento (los enlaces se delegan en `openExternally`,
//  que confirma con el usuario según la plataforma).
//

import WebKit

@MainActor
final class HTMLPreviewController: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    var openExternally: (URL) -> Void

    private var allowsRemoteContent = false
    private var shown: (html: String, allowsRemote: Bool)?
    private var generation = 0

    init(openExternally: @escaping (URL) -> Void) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.openExternally = openExternally
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Muestra `html`; solo recarga si cambió la página o el permiso de contenido externo.
    func show(html: String, allowsRemoteContent allow: Bool) {
        if let shown, shown.allowsRemote == allow, shown.html == html { return }
        shown = (html, allow)
        allowsRemoteContent = allow
        generation += 1
        let current = generation
        Task {
            let rules = allow ? nil : await HTMLContentBlocker.rules()
            guard current == generation else { return }  // llegó otra página mientras tanto
            let contentController = webView.configuration.userContentController
            contentController.removeAllContentRuleLists()
            if !allow {
                guard let rules else {
                    webView.loadHTMLString(HTMLPreviewPolicy.blockerUnavailablePage, baseURL: nil)
                    return
                }
                contentController.add(rules)
            }
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.allowsContentJavaScript = allowsRemoteContent
        let decision = HTMLPreviewPolicy.decide(
            url: navigationAction.request.url,
            isUserLink: navigationAction.navigationType == .linkActivated,
            isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
            allowsRemoteContent: allowsRemoteContent
        )
        switch decision {
        case .allow:
            return (.allow, preferences)
        case .cancel:
            if let url = navigationAction.request.url {
                Log.store.notice("Navegación del visor HTML bloqueada: \(url.scheme ?? "-", privacy: .public)")
            }
            return (.cancel, preferences)
        case .openExternally(let url):
            // Fuera del callback: la confirmación puede ser modal.
            DispatchQueue.main.async { [openExternally] in openExternally(url) }
            return (.cancel, preferences)
        }
    }

    // MARK: - WKUIDelegate

    /// `target="_blank"` y `window.open`: nunca se crean ventanas (el enlace ya pasó por
    /// `decidePolicyFor`).
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }
}

/// Lista de reglas que bloquea la red, compilada una vez y reutilizada.
@MainActor
enum HTMLContentBlocker {
    private static var cached: WKContentRuleList?

    static func rules() async -> WKContentRuleList? {
        if let cached { return cached }
        do {
            let list = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "ArgosHTMLPreviewBlockRemote",
                encodedContentRuleList: HTMLPreviewPolicy.blockRemoteRules
            )
            cached = list
            return list
        } catch {
            Log.store.error("No se pudo compilar el bloqueo de contenido del visor HTML: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
