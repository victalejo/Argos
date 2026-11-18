//
//  LocalizationCatalogTests.swift
//  ArgosTests
//
//  La app está en español (idioma de origen del catálogo) y en inglés. Estos tests
//  vigilan el catálogo sin abrir Xcode:
//  - cada clave tiene traducción inglesa no vacía y marcada como traducida;
//  - los marcadores de formato coinciden en número y tipo entre español e inglés;
//  - no queda ninguna cadena de interfaz en el código fuera del catálogo (con una lista
//    blanca corta de lo que se queda en español a propósito);
//  - los tests corren en español (lo fija el esquema; la CI corre en un runner en inglés).
//

import Foundation
import Testing
@testable import Argos

@Suite("Localización: catálogo")
struct LocalizationCatalogTests {

    // MARK: - Idioma de los tests

    @Test("los tests corren con la app en español (esquema: language es, region ES)")
    func testsRunInSpanish() {
        #expect(Bundle.main.preferredLocalizations.first == "es")
        #expect(Locale.current.language.languageCode == .spanish)
    }

    @Test("la app trae español e inglés, con inglés de reserva")
    func bundleLocalizations() {
        #expect(Set(Bundle.main.localizations).isSuperset(of: ["es", "en"]))
        #expect(Bundle.main.developmentLocalization == "en")
        // Un idioma que la app no tiene cae en inglés, no en español.
        #expect(Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: ["fr-FR"]).first == "en")
        #expect(Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: ["es-MX"]).first == "es")
    }

    // MARK: - (a) y (b) traducciones completas y marcadores iguales

    @Test("cada clave tiene inglés traducido, no vacío, y con los mismos marcadores", arguments: LocalizationSupport.catalogPaths)
    func catalogIsComplete(path: String) throws {
        let strings = try #require(LocalizationSupport.catalog(path), "no se pudo leer \(path)")
        #expect(!strings.isEmpty)
        var problems: [String] = []
        for (key, value) in strings {
            guard let entry = value as? [String: Any] else { continue }
            if entry["shouldTranslate"] as? Bool == false { continue }
            if entry["extractionState"] as? String == "stale" {
                problems.append("obsoleta (stale): «\(key)»")
                continue
            }
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            let english = Self.forms(localizations["en"])
            if english.isEmpty || english.contains(where: { $0.state != "translated" || $0.value.trimmingCharacters(in: .whitespaces).isEmpty }) {
                problems.append("sin inglés revisado: «\(key)»")
                continue
            }
            // El español tiene que estar escrito: la región de desarrollo es el inglés y una
            // clave que falte en es.lproj se mostraría en inglés a quien usa la app en español.
            let spanish = Self.forms(localizations["es"])
            if spanish.isEmpty || spanish.contains(where: { $0.state != "translated" }) {
                problems.append("sin español explícito: «\(key)»")
                continue
            }
            let reference = LocalizationSupport.specifiers(key)
            for form in english + spanish {
                let found = LocalizationSupport.specifiers(form.value)
                // Una variante de plural puede omitir el número («un agente»).
                let isPluralFormWithoutNumber = (english.count > 1 || spanish.count > 1) && found.isEmpty
                if found != reference && !isPluralFormWithoutNumber && !form.value.contains("%#@") {
                    problems.append("marcadores distintos en «\(key)»: \(reference) ≠ \(found) en «\(form.value)»")
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.count) problemas en \(path):\n\(problems.sorted().joined(separator: "\n"))")
    }

    @Test("las frases de Atajos nombran la app en los dos idiomas")
    func appShortcutPhrasesNameTheApp() throws {
        let strings = try #require(LocalizationSupport.catalog("ArgosiOS/AppShortcuts.xcstrings"))
        for (key, value) in strings {
            #expect(key.contains("${applicationName}"), "«\(key)» no nombra la app")
            let english = Self.forms((value as? [String: Any])?["localizations"].flatMap { ($0 as? [String: Any])?["en"] })
            for form in english {
                #expect(form.value.contains("${applicationName}"), "«\(form.value)» no nombra la app")
            }
        }
    }

    // MARK: - (c) ninguna cadena de interfaz fuera del catálogo

    @Test("no queda texto de interfaz en español fuera del catálogo")
    func noSpanishOutsideCatalog() throws {
        let strings = try #require(LocalizationSupport.catalog("Localization/Localizable.xcstrings"))
        let shortcuts = LocalizationSupport.catalog("ArgosiOS/AppShortcuts.xcstrings") ?? [:]
        let phrases = shortcuts.values.flatMap { Self.forms(($0 as? [String: Any])?["localizations"].flatMap { ($0 as? [String: Any])?["es"] }) }.map(\.value)
        let rawKeys = Set(strings.keys).union(shortcuts.keys).union(phrases)
        let keys = Set(strings.keys.map(LocalizationSupport.normalizedKey))
        var leftovers: [String] = []
        for file in Self.sourceFiles() {
            let relative = String(file.path.dropFirst(LocalizationSupport.repoRoot.path.count + 1))
            if LocalizationWhitelist.files.contains(relative) { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for literal in SourceStringScanner.literals(in: source) where !literal.isInLogCall {
                let text = literal.normalized
                guard Self.looksSpanish(text), !keys.contains(text), !rawKeys.contains(text),
                      !rawKeys.contains(Self.appIntentsKey(literal.text)) else { continue }
                if literal.isComment || literal.isPreviewName { continue }
                if LocalizationWhitelist.literals.contains(where: { text.contains($0) }) { continue }
                leftovers.append("\(relative):\(literal.line)  «\(literal.text)»")
            }
        }
        #expect(leftovers.isEmpty, """
            \(leftovers.count) textos en español sin clave en el catálogo. Envuélvelos en \
            String(localized:) (o usa un literal de SwiftUI), ejecuta scripts/localization.sh \
            extract y tradúcelos; si deben quedarse en español (logs, comandos remotos, \
            identificadores), añádelos a LocalizationWhitelist:
            \(leftovers.joined(separator: "\n"))
            """)
    }

    // MARK: - Utilidades

    struct Form { let state: String; let value: String }

    /// Frase de App Intents con parámetros `\(\.$x)` / `\(.applicationName)` tal como la
    /// guarda el catálogo (`${x}`).
    static func appIntentsKey(_ text: String) -> String {
        text.replacingOccurrences(of: #"\\\(\\?\.\$?([A-Za-z]+)\)"#, with: "${$1}", options: .regularExpression)
    }

    /// Valor simple y cada variante (plural, dispositivo) de una localización.
    static func forms(_ localization: Any?) -> [Form] {
        guard let localization = localization as? [String: Any] else { return [] }
        var out: [Form] = []
        if let unit = localization["stringUnit"] as? [String: Any] {
            out.append(Form(state: unit["state"] as? String ?? "", value: unit["value"] as? String ?? ""))
        }
        // Frases de Atajos (AppShortcuts): varias por clave.
        if let set = localization["stringSet"] as? [String: Any] {
            let state = set["state"] as? String ?? ""
            out += (set["values"] as? [String] ?? []).map { Form(state: state, value: $0) }
        }
        for case let variations as [String: Any] in (localization["variations"] as? [String: Any] ?? [:]).values {
            for form in variations.values { out += forms(form) }
        }
        return out
    }

    static func sourceFiles() -> [URL] {
        ["Argos", "ArgosCore", "ArgosiOS", "ArgosUI"].flatMap { folder -> [URL] in
            let root = LocalizationSupport.repoRoot.appendingPathComponent(folder)
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        }
        .sorted { $0.path < $1.path }
    }

    private static let accents = try! NSRegularExpression(pattern: "[áéíóúñÁÉÍÓÚÑ¿¡]")
    private static let spanishWords = try! NSRegularExpression(pattern:
        #"\b(el|la|los|las|de|del|que|para|con|sin|una?|en|se|al|por|tu|tus|hay|puede|está|Abrir|Cerrar|Cancelar|Guardar|Borrar|Eliminar|Crear|Copiar|Pegar|Quitar|Renombrar|Detener|Reintentar|Conectar|Reconectar|Activar|Nunca|Ninguno|Todos|Activado|Desactivado|Abierta|Abiertas|Detenido|Detenida|Detenidas|Conectando|Cargando|Reconectando|Instalando|Memoria|Carpeta|Ajustes|Servidor|Proyecto|Sesión|Ventana|Agentes?|Archivos?)\b"#)

    /// Heurística: letras acentuadas o palabras españolas frecuentes en interfaz.
    static func looksSpanish(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        if accents.firstMatch(in: text, range: range) != nil { return true }
        guard text.range(of: "[A-Za-z]{3,}", options: .regularExpression) != nil else { return false }
        return spanishWords.firstMatch(in: text, range: range) != nil
    }
}
