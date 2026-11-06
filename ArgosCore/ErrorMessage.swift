//
//  ErrorMessage.swift
//  Argos
//
//  Punto único de verdad para convertir un Error en texto de UI. Antes este
//  patrón estaba duplicado en 6 sitios; centralizarlo evita que una variante
//  quede inconsistente.
//

import Foundation

extension Error {
    /// Mensaje legible para mostrar al usuario: prioriza `errorDescription` de
    /// `LocalizedError`; si no, cae a `localizedDescription`.
    var userMessage: String {
        (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }
}
