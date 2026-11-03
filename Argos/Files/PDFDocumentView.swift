//
//  PDFDocumentView.swift
//  Argos
//
//  Visor de PDF (PDFKit) para el explorador de archivos: desplazamiento continuo,
//  ajuste al ancho y texto seleccionable. Solo lectura.
//

import PDFKit
import SwiftUI

struct PDFDocumentView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
            view.autoScales = true
        }
    }
}
