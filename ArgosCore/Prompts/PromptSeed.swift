//
//  PromptSeed.swift
//  ArgosCore
//
//  Ejemplos comunes con los que empieza la biblioteca de un servidor. Se siembran UNA vez
//  (marca `promptsSeeded` en projects.json): si el usuario los borra, no vuelven. Son datos
//  del servidor (se envían a Claude tal cual): no se traducen.
//

import Foundation

enum PromptSeed {
    static let examples: [SavedPrompt] = [
        SavedPrompt(
            id: "argos-ejemplo-seguridad",
            title: "Revisa la seguridad",
            text: "Revisa la seguridad del proyecto (rama {rama}): secretos en el código, entradas sin validar, inyecciones, permisos y dependencias con vulnerabilidades conocidas. Ordena lo que encuentres por gravedad y propón cómo arreglarlo antes de tocar nada."
        ),
        SavedPrompt(
            id: "argos-ejemplo-tests",
            title: "Tests de lo último",
            text: "Escribe o completa los tests de lo que ha cambiado hace poco ({archivos_cambiados}; último commit: {ultimo_commit}). Ejecútalos y arregla lo que falle."
        ),
        SavedPrompt(
            id: "argos-ejemplo-ultimo-commit",
            title: "Revisa el último commit",
            text: "Revisa el último commit ({ultimo_commit}) en la rama {rama}: errores, casos sin cubrir, nombres confusos y lo que mejorarías. No cambies nada sin preguntarme."
        ),
        SavedPrompt(
            id: "argos-ejemplo-dependencias",
            title: "Actualiza dependencias",
            text: "Actualiza las dependencias del proyecto a sus últimas versiones compatibles, una a una, comprobando que compila y que pasan los tests tras cada cambio. Resume al final qué actualizaste y qué dejaste como estaba y por qué.",
            model: .haiku
        ),
        SavedPrompt(
            id: "argos-ejemplo-explica",
            title: "Explica el proyecto",
            text: "Explícame este proyecto: para qué sirve, cómo está organizado, cómo se compila y se prueba, y por dónde empezarías a leer el código. Hoy es {fecha}."
        ),
    ]
}
