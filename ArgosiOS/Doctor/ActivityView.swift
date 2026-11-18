//
//  ActivityView.swift
//  ArgosiOS
//
//  Hoja de compartir del sistema (`UIActivityViewController`) para el informe de diagnóstico.
//

import SwiftUI
import UIKit

struct ActivityView: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
