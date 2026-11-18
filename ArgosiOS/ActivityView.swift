//
//  ActivityView.swift
//  ArgosiOS
//
//  Hoja de compartir del sistema (`UIActivityViewController`): guardar en Archivos,
//  AirDrop, abrir con otra app… La usan el informe de diagnóstico (texto) y la descarga de
//  archivos del servidor (URL de un archivo temporal).
//

import SwiftUI
import UIKit

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    init(items: [Any]) {
        self.items = items
    }

    /// Comparte un texto (p. ej. el informe de diagnóstico).
    init(text: String) {
        self.items = [text]
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
